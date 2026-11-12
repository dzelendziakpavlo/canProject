import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from ble_native_trace import compare


class ComparisonTest(unittest.TestCase):
    def setUp(self):
        build = Path('build').resolve()
        build.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='ble_trace_test_', dir=build)
        self.root = Path(self.temporary.name).resolve()
        assert self.root.parent == build
        self.addCleanup(self.temporary.cleanup)
        self.ble = self.root / 'ble' / 'notifications.jsonl'
        self.usb = self.root / 'usb' / 'capture.jsonl'
        self.ble.parent.mkdir()
        self.usb.parent.mkdir()

    def record(self, obj, n=1, original=None):
        raw = json.dumps(obj, separators=(',', ':')).encode()
        return {'callback_n': n, 'hex': raw.hex(), 'length': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                'callback_kind': 'notification_legacy', 'sdk_int': 30, 'characteristic_uuid': 'ff12' if obj.get('t') == 's' else 'ff11',
                'original_matches_snapshot': original is None, 'original_before_dispatch_sha256': hashlib.sha256(raw if original is None else original).hexdigest(),
                'original_before_dispatch_hex_if_changed': None if original is None else original.hex(),
                'method_channel_available': True}

    def save(self, rows, usb, **changes):
        self.ble.write_text(''.join(json.dumps(r) + '\n' for r in rows), encoding='utf8')
        self.usb.write_text(''.join(json.dumps({'rawJson': json.dumps(r)}) + '\n' for r in usb), encoding='utf8')
        n = len(rows)
        summary = {'status': 'closed', 'observedCallbacks': n, 'enqueuedRecords': n, 'writtenRecords': n, 'flushedRecords': n,
                   'droppedRecords': 0, 'writeErrors': 0, 'undispatchedCallbacks': 0, 'pendingRecords': 0,
                   'originalChanges': sum(r['original_matches_snapshot'] is False for r in rows), **changes}
        self.ble.with_name('manifest.json').write_text(json.dumps(summary), encoding='utf8')

    def test_full_ff12_and_matching_frames(self):
        frame = {'t': 'f', 'id': 192, 'dlc': 2, 'data': [77, 231], 'seq': 100, 'ts': 2000}
        stats = {'t': 's', 'uptime': 2000, 'rx': 100, 'fw': 'x' * 3000}
        self.save([self.record(frame), self.record(stats, 2)], [frame, {**stats, 'bledrop': 0}])
        result = compare(self.ble, self.usb)
        self.assertTrue(result['journalCompleteAndConsistent'])
        self.assertEqual(result['identicalFrameOccurrences'], 1)
        self.assertEqual(result['identicalStatsWithinUsbCoverage'], 1)
        self.assertFalse(result['physicalFixConfirmed'])

    def test_historical_conflicting_seq_is_not_hidden(self):
        ble = {'t': 'f', 'id': 416, 'dlc': 8, 'data': [77, 189, 0, 0, 0, 0, 0, 0], 'ts': 464475, 'seq': 16671}
        usb = {**ble, 'id': 208, 'data': [63, 189, 0, 0, 0, 0, 0, 0]}
        self.save([self.record(ble)], [usb])
        result = compare(self.ble, self.usb)
        self.assertEqual(len(result['frameDifferences']), 1)
        self.assertEqual(result['originalMutationCount'], 0)

    def test_mutation_evidence_and_forwarded_snapshot_are_distinct(self):
        frame = {'t': 'f', 'seq': 100}
        self.save([self.record(frame, original=b'{"t":"f","seq":101}')], [frame])
        result = compare(self.ble, self.usb)
        self.assertEqual(result['originalMutationCount'], 1)
        self.assertEqual(result['identicalFrameOccurrences'], 1)
        self.assertFalse(result['journalIntegrityErrors'])

    def test_drops_and_write_errors_invalidate_complete_claim(self):
        frame = {'t': 'f', 'seq': 100}
        self.save([self.record(frame)], [frame], droppedRecords=1, writeErrors=1)
        self.assertFalse(compare(self.ble, self.usb)['journalCompleteAndConsistent'])

    def test_corrupt_journal_bytes_fail_hash_verification(self):
        row = self.record({'t': 'f', 'seq': 100})
        row['hex'] = b'{}'.hex()
        self.save([row], [])
        result = compare(self.ble, self.usb)
        self.assertFalse(result['journalCompleteAndConsistent'])
        self.assertTrue(result['journalIntegrityErrors'])

    def test_malformed_callback_does_not_become_valid_frame(self):
        row = self.record({'t': 'f', 'seq': 100})
        raw = b'{"t":"f","seq"":16843'
        row.update(hex=raw.hex(), length=len(raw), sha256=hashlib.sha256(raw).hexdigest())
        self.save([row], [])
        result = compare(self.ble, self.usb)
        self.assertEqual(len(result['invalidJsonCallbacks']), 1)
        self.assertEqual(result['bleSequence']['count'], 0)


if __name__ == '__main__':
    unittest.main()

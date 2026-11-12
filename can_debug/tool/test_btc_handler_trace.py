import json
import unittest

import test_receiver_ble_trace as fixtures
from receiver_ble_trace import compare, digest, fnv32


class HandlerTraceTest(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.ReceiverTraceTest('test_clean_window_and_different_length_characteristics')
        self.f.setUp(); self.addCleanup(self.f.doCleanups)
        self.f.enable_btc()
        self.data = [s[6] for s in self.f.stages]
        self.overrides, self.parents, self.footer = {}, {}, {}
        self.missing = set()
        self.handlers_first = False
        self.omit_faults = False

    def write(self):
        self.f.write()
        items = [json.loads(s) for s in self.f.trace.read_text().splitlines() if s.strip()]
        header, footer = items[0], items.pop()
        header.update(schema=3, hook='api-btc-copy-and-handler-entry')
        messages = [r for r in items if r.get('kind') == 'message']
        rows, faults = [], []
        for p, payload, expected in zip(messages, self.data, (s[6] for s in self.f.stages)):
            mid = p['id']
            p['copyMessageAddress'] = 0x3ffb8000 + mid*256
            p.update(self.parents.get(mid, {}))
            if mid in self.missing:
                continue
            flags = int(payload != expected) | (2 if len(payload) != len(expected) else 0)
            h = dict(kind='handler', id=mid, token=p['copyToken'], messageAddress=p['copyMessageAddress'],
                     valueAddress=p['copyDestinationAddress'], length=len(payload), copied=len(payload),
                     connection=p['copyDestConn'], handle=p['copyDestHandle'], confirm=p['copyDestConfirm'],
                     flags=flags, hash=digest(payload))
            h.update(self.overrides.get(mid, {}))
            rows.append(h)
            if h['flags'] and not self.omit_faults and len(faults) < 4:
                faults.append(dict(kind='handler_fault', id=mid, token=h['token'],
                                   expectedLength=len(expected), expectedHex=expected.hex(), actualHex=payload[:h['copied']].hex()))
        if self.handlers_first:
            items[1:1] = reversed(rows)
        else:
            items += rows
        items += faults
        footer.update(handlerSlots=4, handlerRecordBytes=40, handlerStorageAllocated=True,
                      handlerRegistered=len(messages), handlerRegisterDropped=0, handlerRegisterInvalid=0,
                      handlerCalls=len(rows)+3, handlerUntrackedCalls=3, handlerMatched=len(rows), handlerRecorded=len(rows),
                      handlerCancelledPosts=0, handlerCancelContended=0, handlerInvalid=sum(bool(r['flags']&4) for r in rows),
                      handlerBytesChanged=sum(bool(r['flags']&1) for r in rows),
                      handlerMetaChanged=sum(bool(r['flags']&2) for r in rows), handlerFaults=len(faults),
                      handlerFaultOverflow=max(0, sum(bool(r['flags']) for r in rows)-4), handlerHashErrors=0,
                      handlerDuplicateRecords=0, handlerPending=0, handlerSealTimedOut=0, handlerAtomicFailure=0)
        footer.update(self.footer)
        wire = ''.join(json.dumps(x)+'\n' for x in items).encode()
        footer['dataFnv32'] = fnv32(wire)
        self.f.trace.write_bytes(wire + json.dumps(footer).encode() + b'\n')

    def report(self):
        self.write()
        return compare(self.f.trace, self.f.usb, self.f.ble)

    def test_clean_handler_and_untracked_background_calls(self):
        r = self.report()
        self.assertTrue(r['handlerObservationComplete'], r['handlerIntegrityErrors'])
        self.assertEqual(r['handlerDifferences'], [])
        self.assertFalse(r['handlerPayloadChanged'])
        self.assertIn('BTA_GATTS_HandleValueIndication', r['nextUnobservedBoundary'])
        self.assertFalse(r['physicalFixConfirmed'])

    def test_bytes_change_in_queue_retains_both_full_snapshots(self):
        self.data[2] = self.data[2][:-2] + b'01'
        r = self.report()
        self.assertTrue(r['handlerObservationComplete'], r['handlerIntegrityErrors'])
        self.assertTrue(r['handlerPayloadChanged'])
        f = r['handlerFaultSnapshots'][0]
        self.assertEqual(f['expectedHex'], self.f.stages[2][6].hex())
        self.assertEqual(f['actualHex'], self.data[2].hex())
        self.assertIsNone(r['nextUnobservedBoundary'])

    def test_shorter_length_has_complete_actual_bytes(self):
        self.data[2] = self.data[2][:-1]
        r = self.report()
        self.assertTrue(r['handlerObservationComplete'], r['handlerIntegrityErrors'])
        self.assertEqual(r['handlerDifferences'][0]['afterLength'], len(self.data[2]))

    def test_good_handler_bad_android_keeps_boundary_unresolved_after_handler(self):
        self.f.native_payloads[2] = self.f.native_payloads[2][:-2] + b'01'
        r = self.report()
        self.assertFalse(r['handlerPayloadChanged'])
        self.assertEqual(r['handlerVsNativeDifferences'][0]['apiMessageIds'], [3])
        self.assertIn('not instrumented', r['nextUnobservedBoundary'])

    def test_tokens_are_checked_instead_of_guessed(self):
        self.overrides[3] = dict(token=1004)
        r = self.report()
        self.assertFalse(r['handlerObservationComplete'])
        self.assertTrue(any('token mismatch' in e for e in r['handlerIntegrityErrors']))

    def test_handler_before_api_record_and_reordered_rows(self):
        self.handlers_first = True
        r = self.report()
        self.assertTrue(r['handlerObservationComplete'], r['handlerIntegrityErrors'])
        self.assertEqual(r['matchingHandlerNativeOccurrences'], 5)

    def test_unknown_pointer_is_not_treated_as_observed_payload(self):
        self.data[2] = b''
        self.overrides[3] = dict(valueAddress=1234, length=len(self.f.stages[2][6]), copied=0, flags=6)
        r = self.report()
        self.assertFalse(r['handlerObservationComplete'])
        self.assertIsNone(r['handlerPayloadChanged'])
        self.assertFalse(r['handlerDifferences'][0]['snapshotValid'])

    def test_length_above_allocation_bound_is_incomplete(self):
        self.data[2] = b''
        self.overrides[3] = dict(length=640, copied=0, flags=6)
        r = self.report()
        self.assertFalse(r['handlerObservationComplete'])
        self.assertEqual(r['handlerFaultSnapshots'][0]['actualHex'], '')

    def test_registry_overflow_is_explicit(self):
        self.missing.add(3)
        self.footer.update(handlerRegisterDropped=1, handlerRegistered=4)
        r = self.report()
        self.assertFalse(r['handlerObservationComplete'])
        self.assertEqual(r['missingHandlerMessages'], [3])

    def test_late_pending_handler_is_not_a_clean_window(self):
        self.missing.add(3)
        self.footer.update(handlerPending=1, handlerSealTimedOut=1)
        r = self.report()
        self.assertFalse(r['handlerObservationComplete'])
        self.assertIn('handlerPending nonzero/missing', r['handlerIntegrityErrors'])

    def test_argument_handle_change_is_separate_from_byte_change(self):
        self.overrides[3] = dict(handle=12, flags=2)
        r = self.report()
        self.assertTrue(r['handlerObservationComplete'], r['handlerIntegrityErrors'])
        self.assertFalse(r['handlerPayloadChanged'])
        self.assertTrue(r['handlerDifferences'][0]['metadataChanged'])

    def test_fault_limit_never_hides_missing_full_bytes(self):
        for i in (0, 1, 2, 3):
            self.data[i] = self.data[i][:-2] + b'01'
        self.missing.add(5)
        self.footer.update(handlerRegisterDropped=1, handlerRegistered=4)
        r = self.report()
        self.assertFalse(r['handlerObservationComplete'])
        self.assertEqual(len(r['handlerFaultSnapshots']), 4)

    def test_every_registered_anomaly_retains_full_bytes_below_slot_limit(self):
        for i in (1, 2, 3):
            self.data[i] = self.data[i][:-2] + b'01'
        r = self.report()
        self.assertTrue(r['handlerObservationComplete'], r['handlerIntegrityErrors'])
        self.assertEqual(len(r['handlerFaultSnapshots']), 3)

    def test_same_message_address_with_different_generations_uses_tokens(self):
        self.parents[1] = self.parents[3] = dict(copyMessageAddress=0x3ffb8000)
        r = self.report()
        self.assertTrue(r['handlerObservationComplete'], r['handlerIntegrityErrors'])
        self.assertEqual(r['matchingHandlerNativeOccurrences'], 5)

    def test_confirmed_anomaly_requires_full_bytes(self):
        self.data[2] = self.data[2][:-2] + b'01'
        self.omit_faults = True
        r = self.report()
        self.assertFalse(r['handlerObservationComplete'])
        self.assertIn('Confirmed handler anomalies lack full byte snapshots', r['handlerIntegrityErrors'])

    def test_bounded_atomic_counter_failure_invalidates_observation(self):
        self.footer['handlerAtomicFailure'] = 1
        self.assertFalse(self.report()['handlerObservationComplete'])

    def test_failed_post_is_not_confused_with_a_handler_snapshot(self):
        self.missing.add(3)
        self.f.record_overrides[3] = dict(result=-1)
        self.f.footer_overrides['apiErrors'] = 1
        self.footer['handlerCancelledPosts'] = 1
        r = self.report()
        self.assertFalse(r['handlerObservationComplete'])
        self.assertEqual(r['missingHandlerMessages'], [3])

    def test_changed_bytes_with_false_device_flag_is_rejected(self):
        self.data[2] = self.data[2][:-2] + b'01'
        self.overrides[3] = dict(flags=0)
        r = self.report()
        self.assertFalse(r['handlerObservationComplete'])
        self.assertTrue(any('byte-comparison flag' in e for e in r['handlerIntegrityErrors']))


if __name__ == '__main__':
    unittest.main()

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from receiver_ble_trace import compare, digest, fnv32


class ReceiverTraceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.trace, self.usb, self.ble = (self.root / n for n in ('trace.jsonl', 'usb/capture.jsonl', 'ble/notifications.jsonl'))
        self.usb.parent.mkdir(); self.ble.parent.mkdir()
        self.objects = [dict(t='f', id=192, dlc=8, data=[i, i * 3, 0, 0, 0, 0, 0, 0], ts=100+i, seq=i) for i in range(1, 5)]
        self.objects.insert(1, dict(t='s', v=2, node='receiver', fw='can-monitor-telemetry-v2', uptime=100, rx=1, state='RUNNING'))
        self.payloads = [json.dumps(x, separators=(',', ':')).encode() for x in self.objects]
        peers = {11: b'', 12: b''}
        self.stages = []
        for obj, b in zip(self.objects, self.payloads):
            kind = 11 if obj['t'] == 'f' else 12
            peer = peers[12 if kind == 11 else 11]
            self.stages.append([b, b, b, peer, peer])
            peers[kind] = b
        self.flags = [0] * len(self.payloads)
        self.api_calls = [1] * len(self.payloads)
        self.native_payloads = self.payloads.copy()
        self.footer_overrides = {}
        self.btc = False
        self.copy_calls = [1] * len(self.payloads)
        self.record_overrides = {}
        self.reverse_export = False

    def enable_btc(self):
        self.btc = True
        for s in self.stages:
            s.extend([s[2], s[2]])

    def write(self):
        usb = []
        for obj, b in zip(self.objects, self.payloads):
            raw = b.decode()
            if obj['t'] == 's':
                raw = raw[:-1] + ',"serialdrop":0,"bledrop":0}'
            usb.append({'rawJson': raw})
        self.usb.write_text(''.join(json.dumps(x) + '\n' for x in usb))
        manifest = dict(status='closed', serialParseErrors=0, serialErrors=0, readErrors=0,
                        unrecordedRecords=0, sequenceGaps=0, failure=None, acceptedRecords=len(usb), writtenRecords=len(usb))
        self.usb.with_name('manifest.json').write_text(json.dumps(manifest))
        native = []
        for n, (obj, b) in enumerate(zip(self.objects, self.native_payloads), 1):
            native.append(dict(callback_n=n, characteristic_uuid='ff11' if obj['t'] == 'f' else 'ff12',
                               hex=b.hex(), length=len(b), sha256=hashlib.sha256(b).hexdigest(),
                               original_matches_snapshot=True, method_channel_available=True, gatt_status=0))
        self.ble.write_text(''.join(json.dumps(x) + '\n' for x in native))
        manifest = dict(status='closed', observedCallbacks=len(native), dispatchedCallbacks=len(native),
                        enqueuedRecords=len(native), writtenRecords=len(native), flushedRecords=len(native),
                        droppedRecords=0, writeErrors=0, pendingRecords=0, undispatchedCallbacks=0)
        self.ble.with_name('manifest.json').write_text(json.dumps(manifest))
        items = [dict(kind='header', schema=2 if self.btc else 1,
                      hook='api-and-btc-deep-copy-return' if self.btc else 'api-entry-wrap-before-btc-copy', capacity=512)]
        faults = []
        for n, (obj, snapshots, flags, calls) in enumerate(zip(self.objects, self.stages, self.flags, self.api_calls), 1):
            kind = 11 if obj['t'] == 'f' else 12
            hashes = [digest(b) for b in snapshots]
            lengths = [len(b) for b in snapshots]
            if not calls:
                hashes[2] = '0' * 32; lengths[2] = 0
            items.append(dict(kind='message', id=n, us=n*10000, sourceKind=kind,
                              sourceKey=obj.get('seq', obj.get('uptime')), handle=kind, peerHandle=23-kind,
                              apiHandle=kind, conn=0, gattsIf=3, confirm=0, flags=flags, apiCalls=calls,
                              result=0 if calls else -2147483648, hashes=hashes, lengths=lengths))
            if self.btc:
                copied = self.copy_calls[n - 1]
                items[-1].update(apiToken=1000+n if calls else 0, copyToken=1000+n if copied else 0,
                                 copyCalls=copied, apiSourceAddress=0x3ffb0000+n*1024,
                                 copySourceAddress=0x3ffb0000+n*1024, copyDestinationAddress=0x3ffc0000+n*1024,
                                 copySourceConn=3, copySourceHandle=kind, copySourceConfirm=0,
                                 copyDestConn=3, copyDestHandle=kind, copyDestConfirm=0)
                if not copied:
                    hashes[5:] = ['0'*32]*2; lengths[5:] = [0, 0]
                items[-1].update(self.record_overrides.get(n, {}))
            if flags:
                faults.append(dict(kind='fault', id=n, snapshots=[dict(length=len(b), copied=len(b), hex=b.hex()) for b in snapshots]))
        if self.reverse_export:
            items[1:] = reversed(items[1:])
        items += faults
        footer = dict(kind='footer', status='closed', reason='window', messages=len(self.objects),
                      queued=len(self.objects), stored=len(self.objects), dropped=0, writeErrors=0,
                      invalidSnapshots=0, outsideApi=0, faultOverflow=0, faults=len(faults),
                      setChanged=sum(bool(x & 1) for x in self.flags), apiChanged=sum(bool(x & 2) for x in self.flags),
                      peerChanged=sum(bool(x & 4) for x in self.flags), apiMissing=self.api_calls.count(0), apiErrors=0)
        if self.btc:
            footer.update(copyCallbacks=sum(self.copy_calls),
                          copyMissing=sum(a > 0 and c == 0 for a, c in zip(self.api_calls, self.copy_calls)), copyUnmatched=0,
                          copySourceChanged=sum(bool(x & 128) for x in self.flags),
                          copyDestChanged=sum(bool(x & 256) for x in self.flags),
                          copyMetadataChanged=sum(bool(x & 512) for x in self.flags),
                          copyAlias=sum(bool(x & 1024) for x in self.flags))
        wire = ''.join(json.dumps(x) + '\r\n' for x in items).encode()
        footer['dataFnv32'] = fnv32(wire)
        footer.update(self.footer_overrides)
        self.trace.write_bytes(b'\r\n' + wire + json.dumps(footer).encode() + b'\n')

    def report(self):
        self.write()
        return compare(self.trace, self.usb, self.ble)

    def test_clean_window_and_different_length_characteristics(self):
        r = self.report()
        self.assertTrue(r['traceCompleteAndConsistent'], r['traceIntegrityErrors'])
        self.assertTrue(r['usbCompleteAndConsistent'])
        self.assertTrue(r['nativeCompleteAndConsistent'])
        self.assertEqual(r['stageDifferences'], [])
        self.assertEqual(r['dequeueWithoutExactUsbMatch'], [])
        self.assertEqual(r['matchingApiNativeOccurrences'], 5)
        self.assertEqual(r['longFf12ThenShortFf11'], dict(checked=1, differences=[]))
        self.assertFalse(r['physicalFixConfirmed'])
        self.assertNotIn('usbWireReadIssues', r)

    def test_rejected_null_wire_is_reported_without_losing_storage_counts(self):
        self.write()
        rejected = dict(type='rejected', rawJson=None, error='Unexpected extension byte')
        self.usb.write_text(json.dumps(rejected) + '\n' + self.usb.read_text())
        path = self.usb.with_name('manifest.json')
        manifest = json.loads(path.read_text())
        manifest.update(acceptedRecords=6, writtenRecords=6, serialParseErrors=1)
        path.write_text(json.dumps(manifest))
        r = compare(self.trace, self.usb, self.ble)
        self.assertFalse(r['usbCompleteAndConsistent'])
        self.assertEqual(r['usbStorageRecordCount'], 6)
        self.assertEqual(r['usbWireRecordCount'], 5)
        self.assertEqual(r['usbWireReadIssues'], [dict(line=1, type='rejected',
                         error='Unexpected extension byte', reason='rejected_record')])
        self.assertEqual(r['dequeueWithoutExactUsbMatch'], [])

    def test_invalid_wire_records_are_explicit_even_with_clean_manifest(self):
        cases = [({}, 'raw_json_not_string'), ({'rawJson': None}, 'raw_json_not_string'),
                 ({'rawJson': 123}, 'raw_json_not_string'), ({'rawJson': '{'}, 'invalid_wire_json'),
                 ({'rawJson': 'null'}, 'unsupported_wire_object'),
                 ({'rawJson': '{"t":"f"}'}, 'missing_or_invalid_wire_identity'),
                 ({'rawJson': '{"t":"s","uptime":100}'}, 'missing_stats_transport_boundary')]
        for bad, reason in cases:
            with self.subTest(reason=reason, bad=bad):
                self.write()
                lines = self.usb.read_text().splitlines()
                lines[2] = json.dumps(dict(bad, seq=2, id=192, data=[2, 6]))
                self.usb.write_text('\n'.join(lines) + '\n')
                r = compare(self.trace, self.usb, self.ble)
                self.assertFalse(r['usbCompleteAndConsistent'])
                self.assertEqual(r['usbWireReadIssues'][0]['reason'], reason)
                self.assertEqual(r['usbWireReadIssues'][0]['line'], 3)
                self.assertEqual(r['usbWireRecordCount'], 4)
                self.assertEqual(r['dequeueWithoutExactUsbMatch'][0]['id'], 3)

    def test_rejected_valid_json_is_never_used_as_wire_reference(self):
        self.write()
        lines = self.usb.read_text().splitlines()
        row = json.loads(lines[2])
        row['type'] = 'rejected'
        lines[2] = json.dumps(row)
        self.usb.write_text('\n'.join(lines) + '\n')
        r = compare(self.trace, self.usb, self.ble)
        self.assertFalse(r['usbCompleteAndConsistent'])
        self.assertEqual(r['usbWireReadIssues'][0]['reason'], 'rejected_record')
        self.assertEqual(r['dequeueWithoutExactUsbMatch'][0]['id'], 3)

    def test_first_difference_after_set_and_raw_fault_bytes(self):
        self.stages[2][1] = self.stages[2][2] = b'{"t":"f","wrong":true}'
        self.flags[2] = 3
        r = self.report()
        self.assertTrue(r['traceCompleteAndConsistent'], r['traceIntegrityErrors'])
        self.assertEqual(r['stageDifferences'][0]['firstObservedBoundary'], 'dequeue -> setValue/readback')
        self.assertEqual(r['faultSnapshots'][0]['snapshots'][1]['hex'], self.stages[2][1].hex())

    def test_first_difference_in_real_api_arguments(self):
        self.stages[2][2] = b'changed-at-api'
        self.flags[2] = 2
        r = self.report()
        self.assertEqual(r['stageDifferences'][0]['firstObservedBoundary'], 'readback -> actual API arguments')

    def test_peer_overwrite_is_independently_visible(self):
        self.stages[2][4] = self.payloads[2] + self.stages[2][3][len(self.payloads[2]):]
        self.flags[2] = 4
        r = self.report()
        self.assertIn('peer characteristic', r['stageDifferences'][0]['firstObservedBoundary'])
        self.assertEqual(r['longFf12ThenShortFf11']['differences'], [3])

    def test_peer_change_between_messages_is_visible_without_assuming_setvalue_caused_it(self):
        self.stages[2][3] = self.stages[2][4] = b'already-changed-before-set'
        r = self.report()
        self.assertEqual(r['stageDifferences'], [])
        self.assertEqual(r['characteristicContinuityDifferences'][0]['id'], 3)

    def test_queue_drop_and_fault_overflow_invalidate_completeness(self):
        self.footer_overrides = dict(dropped=1, faultOverflow=1)
        r = self.report()
        self.assertFalse(r['traceCompleteAndConsistent'])

    def test_export_checksum_detects_valid_json_corruption(self):
        self.write()
        self.trace.write_bytes(self.trace.read_bytes().replace(b'"us": 10000', b'"us": 10001'))
        r = compare(self.trace, self.usb, self.ble)
        self.assertIn('Maintenance export checksum mismatch', r['traceIntegrityErrors'])

    def test_device_byte_comparison_must_agree_with_fingerprints(self):
        self.flags[2] = 1  # Counter/checksum agree, but byte snapshots are equal.
        r = self.report()
        self.assertFalse(r['traceCompleteAndConsistent'])
        self.assertTrue(any('byte-comparison flags' in x for x in r['traceIntegrityErrors']))

    def test_missing_footer_is_never_accepted(self):
        self.write()
        self.trace.write_bytes(b'\n'.join(self.trace.read_bytes().splitlines()[:-1]))
        with self.assertRaisesRegex(ValueError, 'footer'):
            compare(self.trace, self.usb, self.ble)

    def test_partial_productive_usb_line_before_header_is_preserved_but_ignored(self):
        self.write()
        self.trace.write_bytes(b'0,0],"seq":123}\n' + self.trace.read_bytes())
        self.assertTrue(compare(self.trace, self.usb, self.ble)['traceCompleteAndConsistent'])

    def test_corrupt_diagnostic_line_is_never_silently_skipped(self):
        self.write()
        self.trace.write_bytes(self.trace.read_bytes().replace(b'"us": 10000', b'"us": x0000'))
        with self.assertRaises(ValueError):
            compare(self.trace, self.usb, self.ble)

    def test_missing_api_is_not_equated_to_empty_payload(self):
        self.api_calls[2] = 0
        r = self.report()
        self.assertEqual(r['missingApiMessages'], [3])
        self.assertEqual(r['stageDifferences'], [])

    def test_bad_payload_already_at_dequeue_vs_usb_identity(self):
        self.stages[2][:3] = [b'{"t":"f","corrupted":true}'] * 3
        r = self.report()
        self.assertEqual(r['stageDifferences'], [])
        self.assertEqual(r['dequeueWithoutExactUsbMatch'][0]['id'], 3)
        self.assertTrue(r['dequeueWithoutExactUsbMatch'][0]['usbCandidates'])

    def test_ff12_carrying_exact_usb_ff11_is_still_bad_at_dequeue(self):
        self.stages[1][:3] = [self.payloads[2]] * 3
        r = self.report()
        self.assertEqual(r['dequeueWithoutExactUsbMatch'][0]['sourceKind'], 12)
        self.assertEqual(r['dequeueWithoutExactUsbMatch'][0]['id'], 2)

    def test_repeated_complete_frame_is_visible_in_usb_order_comparison(self):
        self.stages[2][:3] = [self.payloads[0]] * 3
        r = self.report()
        self.assertEqual(r['dequeueWithoutExactUsbMatch'], [])
        self.assertTrue(r['usbVsDequeueOrderDifferences'])

    def test_mixed_ff12_native_callback_is_detected_between_anchors(self):
        frame = self.payloads[2]
        self.native_payloads[1] = frame + self.payloads[1][len(frame):]
        r = self.report()
        self.assertTrue(r['nativeCompleteAndConsistent'])
        self.assertEqual(r['stageDifferences'], [])
        self.assertEqual(r['apiVsNativeDifferences'][0]['apiMessageIds'], [2])
        self.assertEqual(r['apiVsNativeDifferences'][0]['nativeCallbacks'][0]['characteristic'], 12)

    def test_btc_clean_post_copy_matches_all_inputs(self):
        self.enable_btc()
        r = self.report()
        self.assertTrue(r['traceCompleteAndConsistent'], r['traceIntegrityErrors'])
        self.assertTrue(r['btcCopyObservationComplete'])
        self.assertEqual(r['btcCopyDifferences'], [])
        self.assertEqual(r['matchingBtcNativeOccurrences'], 5)

    def test_btc_source_changed_after_api_but_before_copy(self):
        self.enable_btc()
        self.stages[2][5] = self.stages[2][6] = self.stages[2][2][:-2] + b'9}'
        self.flags[2] = 128
        r = self.report()
        self.assertTrue(r['traceCompleteAndConsistent'], r['traceIntegrityErrors'])
        self.assertEqual(r['btcCopyDifferences'][0]['boundary'], 'API entry -> BTC source before deep-copy')
        self.assertEqual(len(r['btcCopyDifferences']), 1)

    def test_btc_destination_changed_after_original_copy(self):
        self.enable_btc()
        self.stages[2][6] = self.stages[2][5][:-2] + b'01'
        self.flags[2] = 256
        r = self.report()
        self.assertTrue(r['traceCompleteAndConsistent'], r['traceIntegrityErrors'])
        self.assertEqual(r['btcCopyDifferences'][0]['boundary'], 'BTC source before -> destination after original deep-copy')
        self.assertEqual(r['faultSnapshots'][0]['snapshots'][6]['hex'], self.stages[2][6].hex())

    def test_btc_good_copy_bad_android_has_no_copy_mismatch(self):
        self.enable_btc()
        self.native_payloads[2] = self.payloads[2][:-2] + b'01'
        r = self.report()
        self.assertEqual(r['btcCopyDifferences'], [])
        self.assertEqual(r['btcVsNativeDifferences'][0]['apiMessageIds'], [3])

    def test_btc_copy_token_is_not_guessed_from_content(self):
        self.enable_btc()
        self.record_overrides[3] = dict(copyToken=1004)
        r = self.report()
        self.assertFalse(r['btcCopyObservationComplete'])
        self.assertTrue(any('token mismatch' in x for x in r['traceIntegrityErrors']))

    def test_btc_missing_callback_is_explicit_incomplete_observation(self):
        self.enable_btc()
        self.copy_calls[2] = 0
        r = self.report()
        self.assertTrue(r['traceCompleteAndConsistent'], r['traceIntegrityErrors'])
        self.assertFalse(r['btcCopyObservationComplete'])
        self.assertEqual(r['missingCopyMessages'], [3])

    def test_btc_multiple_callbacks_are_not_silently_collapsed(self):
        self.enable_btc()
        self.copy_calls[2] = 2
        self.flags[2] = 2048
        r = self.report()
        self.assertTrue(r['traceCompleteAndConsistent'], r['traceIntegrityErrors'])
        self.assertFalse(r['btcCopyObservationComplete'])
        self.assertEqual(r['multipleCopyMessages'], [3])

    def test_btc_unmatched_callback_does_not_get_attached_to_latest_message(self):
        self.enable_btc()
        self.footer_overrides['copyUnmatched'] = 1
        r = self.report()
        self.assertFalse(r['btcCopyObservationComplete'])
        self.assertIn('Unmatched deep-copy callbacks present or counter missing', r['traceIntegrityErrors'])

    def test_btc_reordered_export_uses_ids_and_tokens(self):
        self.enable_btc()
        self.reverse_export = True
        r = self.report()
        self.assertTrue(r['btcCopyObservationComplete'], r['traceIntegrityErrors'])
        self.assertEqual(r['matchingBtcNativeOccurrences'], 5)

    def test_btc_alias_is_visible_even_with_identical_content(self):
        self.enable_btc()
        self.flags[2] = 1024
        self.record_overrides[3] = dict(copyDestinationAddress=0x3ffb0000+3*1024)
        r = self.report()
        self.assertTrue(r['traceCompleteAndConsistent'], r['traceIntegrityErrors'])
        self.assertEqual(r['aliasedCopyMessages'], [3])

    def test_btc_metadata_change_is_separate_from_payload_change(self):
        self.enable_btc()
        self.flags[2] = 512
        self.record_overrides[3] = dict(copyDestHandle=12)
        r = self.report()
        self.assertTrue(r['traceCompleteAndConsistent'], r['traceIntegrityErrors'])
        self.assertEqual(r['btcCopyDifferences'][0]['boundary'], 'BTC argument metadata changed')


if __name__ == '__main__':
    unittest.main()

"""ESP32 RAM trace maintenance export and offline comparison. App protocols are unchanged."""
import argparse
import collections
import difflib
import hashlib
import json
from pathlib import Path
import time


def digest(data):
    return hashlib.sha256(data).hexdigest()[:32]


def fnv32(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text(encoding='utf-8-sig').splitlines() if line.strip()]


def read_usb_wire(path):
    """Keep storage/error records, but match only original valid wire payloads."""
    rows, wire, issues = [], [], []
    for number, line in enumerate(Path(path).read_text(encoding='utf-8-sig').splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        rows.append(row)
        issue = {'line': number}
        if not isinstance(row, dict):
            issue['reason'] = 'storage_record_not_object'
        else:
            issue.update(type=row.get('type'), error=row.get('error'))
            raw = row.get('rawJson')
            if row.get('type') == 'rejected':
                issue['reason'] = 'rejected_record'
            elif not isinstance(raw, str):
                issue.update(reason='raw_json_not_string', rawJsonType=type(raw).__name__)
            else:
                try:
                    obj = json.loads(raw)
                except json.JSONDecodeError as exc:
                    issue.update(reason='invalid_wire_json', detail=str(exc))
                else:
                    if not isinstance(obj, dict) or obj.get('t') not in ('f', 's'):
                        issue['reason'] = 'unsupported_wire_object'
                    else:
                        identity = obj.get('seq' if obj['t'] == 'f' else 'uptime')
                        if type(identity) is not int:
                            issue['reason'] = 'missing_or_invalid_wire_identity'
                        elif obj['t'] == 's' and ',"serialdrop":' not in raw:
                            issue['reason'] = 'missing_stats_transport_boundary'
                        else:
                            wire.append((raw, obj))
                            continue
        issues.append(issue)
    return rows, wire, issues


def inspect_handlers(items, footer, parents):
    """Join asynchronous handler records by explicit message ID + token."""
    errors, differences, missing = [], [], []
    rows = [x for x in items if x.get('kind') == 'handler']
    faults = [x for x in items if x.get('kind') == 'handler_fault']
    parent_by_id = {x['id']: x for x in parents}
    by_id = {}
    for h in rows:
        mid = h['id']
        if mid in by_id:
            errors.append('Repeated handler message ID: ' + str(mid))
        by_id[mid] = h
        p = parent_by_id.get(mid)
        if not p:
            errors.append('Handler has no parent message: ' + str(mid)); continue
        if not h['token'] or h['token'] != p['copyToken'] or h['token'] != p['apiToken']:
            errors.append('Handler token mismatch: ' + str(mid))
        if not p.get('copyMessageAddress') or h['messageAddress'] != p['copyMessageAddress']:
            errors.append('Handler BTC message address mismatch: ' + str(mid))
        if len(h['hash']) != 32 or any(c not in '0123456789abcdef' for c in h['hash']):
            errors.append('Invalid handler fingerprint: ' + str(mid))
        metadata_changed = (h['valueAddress'] != p['copyDestinationAddress'] or h['connection'] != p['copyDestConn'] or
                            h['handle'] != p['copyDestHandle'] or h['confirm'] != p['copyDestConfirm'] or
                            h['length'] != p['lengths'][6])
        if bool(h['flags'] & 2) != metadata_changed:
            errors.append('Handler metadata flag disagrees: ' + str(mid))
        if h['flags'] & 4:
            if h['copied'] > min(h['length'], p['lengths'][6], 640):
                errors.append('Unsafe handler copied length: ' + str(mid))
        else:
            if h['copied'] != h['length'] or h['copied'] > min(p['lengths'][6], 640):
                errors.append('Incomplete handler bytes without invalid flag: ' + str(mid))
            changed = (h['length'], h['hash']) != (p['lengths'][6], p['hashes'][6])
            if bool(h['flags'] & 1) != changed:
                errors.append('Handler byte-comparison flag disagrees: ' + str(mid))
        if h['flags']:
            differences.append({'id': mid, 'token': h['token'], 'boundary': 'post-deep-copy -> btc_gatts_call_handler entry',
                                'beforeLength': p['lengths'][6], 'afterLength': h['length'],
                                'bytesChanged': bool(h['flags'] & 1), 'metadataChanged': bool(h['flags'] & 2),
                                'snapshotValid': not bool(h['flags'] & 4)})
    expected = [p for p in parents if p.get('copyCalls') == 1 and p.get('apiToken') == p.get('copyToken')]
    missing = [p['id'] for p in expected if p['id'] not in by_id]
    fault_ids = set()
    for f in faults:
        h, p = by_id.get(f['id']), parent_by_id.get(f['id'])
        if not h or not p or f['id'] in fault_ids or f['token'] != h['token'] or not h['flags']:
            errors.append('Invalid/duplicate handler fault identity'); continue
        fault_ids.add(f['id'])
        before, after = bytes.fromhex(f['expectedHex']), bytes.fromhex(f['actualHex'])
        if (len(before) != f['expectedLength'] or len(before) != p['lengths'][6] or digest(before) != p['hashes'][6] or
                len(after) != h['copied'] or digest(after) != h['hash']):
            errors.append('Full handler fault bytes disagree with fingerprints: ' + str(f['id']))
    if footer.get('handlerStorageAllocated') is not True:
        errors.append('Handler RAM storage not allocated')
    for key in ('handlerRegisterDropped', 'handlerRegisterInvalid', 'handlerCancelledPosts', 'handlerCancelContended',
                'handlerInvalid', 'handlerFaultOverflow', 'handlerHashErrors', 'handlerDuplicateRecords',
                'handlerPending', 'handlerSealTimedOut', 'handlerAtomicFailure'):
        if footer.get(key) != 0:
            errors.append(key + ' nonzero/missing')
    counters = {'handlerRegistered': len(expected), 'handlerMatched': len(rows), 'handlerRecorded': len(rows),
                'handlerBytesChanged': sum(bool(h['flags'] & 1) for h in rows),
                'handlerMetaChanged': sum(bool(h['flags'] & 2) for h in rows),
                'handlerFaults': len(faults)}
    for key, count in counters.items():
        if footer.get(key) != count:
            errors.append(key + ' disagrees with records')
    if not footer.get('handlerFaultOverflow') and len(faults) != sum(bool(h['flags']) for h in rows):
        errors.append('Confirmed handler anomalies lack full byte snapshots')
    if missing:
        errors.append('Registered post-copy messages missing handler snapshots')
    if footer.get('handlerCalls') != footer.get('handlerMatched', 0) + footer.get('handlerUntrackedCalls', 0):
        errors.append('Handler call counters disagree')
    # Untracked calls can precede/follow the bounded RAM cohort; never guess
    # their token from sequence/content or automatically call them lost events.
    return {'records': sorted(rows, key=lambda h: h['id']), 'faults': faults,
            'differences': differences, 'missing': missing, 'errors': errors}


def dump_trace(args):
    try:
        import serial  # Optional only for maintenance export; offline comparison is stdlib-only.
    except ImportError:
        raise SystemExit('Install export dependency: python -m pip install pyserial==3.5')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        raise SystemExit('Output exists; use a new filename to preserve the previous trace')
    port = serial.Serial(port=None, baudrate=args.baud, timeout=0.25, write_timeout=3)
    # Set control lines BEFORE opening. Do not reset a RAM-only capture.
    port.dtr = False
    port.rts = False
    port.port = args.port
    header = None
    deadline = time.monotonic() + args.timeout
    with port, args.output.open('wb') as output:
        port.reset_input_buffer()
        port.write(b'BLE_DIAG_DUMP\n')
        while time.monotonic() < deadline:
            line = port.readline()
            if not line:
                continue
            # Save raw export, including a possible preceding USB JSON line; do
            # not quietly discard corrupted diagnostic lines or repair JSON.
            output.write(line)
            try:
                item = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if item.get('kind') == 'header':
                header = item
            if header and item.get('kind') == 'footer':
                output.flush()
                print(json.dumps(item, indent=2))
                print(args.output)
                return
    raise RuntimeError('No complete footer. Keep the file as incomplete evidence; do not reset the board')


def compare(trace_path, usb_path, ble_path):
    paths = [Path(trace_path), Path(usb_path), Path(ble_path)]
    # The maintenance command pauses only after the current productive USB line.
    # Permit productive JSON before the header, but require every diagnostic line.
    wire_lines = Path(trace_path).read_bytes().splitlines(keepends=True)
    headers = []
    for i, line in enumerate(wire_lines):
        try:
            if json.loads(line).get('kind') == 'header':
                headers.append(i)
        except (ValueError, UnicodeError):
            pass  # A partial productive line BEFORE header is permitted.
    if len(headers) != 1:
        raise ValueError('Expected exactly one diagnostic header')
    h = headers[0]
    items = [json.loads(line) for line in wire_lines[h:] if line.strip()]
    header = items[0]
    handler_mode = header.get('schema') == 3
    btc = header.get('schema') in (2, 3)
    stages = 7 if btc else 5
    if items[-1].get('kind') != 'footer':
        raise ValueError('Missing final footer: trace is incomplete')
    footer = items[-1]
    records = [r for r in items if r.get('kind') == 'message']
    faults = [r for r in items if r.get('kind') == 'fault']
    errors = []
    f = next(i for i, line in enumerate(wire_lines[h:], h) if line.strip() and json.loads(line).get('kind') == 'footer')
    if fnv32(b''.join(wire_lines[h:f])) != footer.get('dataFnv32'):
        errors.append('Maintenance export checksum mismatch')
    if ((header.get('schema'), header.get('hook')) not in
            ((1, 'api-entry-wrap-before-btc-copy'), (2, 'api-and-btc-deep-copy-return'),
             (3, 'api-btc-copy-and-handler-entry'))):
        errors.append('Unexpected trace schema/hook')
    allowed_kinds = ('header', 'message', 'fault', 'footer', 'handler', 'handler_fault') if handler_mode else ('header', 'message', 'fault', 'footer')
    if any(x.get('kind') not in allowed_kinds for x in items):
        errors.append('Unexpected record after diagnostic header')
    ids = [r['id'] for r in records]
    if sorted(ids) != list(range(1, footer['messages'] + 1)):
        errors.append('Message IDs missing/repeated')
    # Correlation is by explicit IDs/tokens, never by RAM export row position.
    records.sort(key=lambda r: r['id'])
    if footer['status'] != 'closed' or footer['messages'] == 0:
        errors.append('No closed nonempty measurement window')
    if not (len(records) == footer['stored'] == footer['queued'] == footer['messages']):
        errors.append('Message/queue/storage counts differ')
    for key in ('dropped', 'writeErrors', 'invalidSnapshots', 'outsideApi', 'faultOverflow'):
        if footer.get(key) != 0:
            errors.append(key + ' is nonzero or missing')
    if len(faults) != footer['faults']:
        errors.append('Fault count differs')
    for r in records:
        if len(r['lengths']) != stages or len(r['hashes']) != stages:
            raise ValueError('Invalid snapshot columns at id ' + str(r['id']))
        if any(len(h) != 32 or any(c not in '0123456789abcdef' for c in h) for h in r['hashes']):
            errors.append('Invalid fingerprint at id ' + str(r['id']))
    for key, count in {
            'setChanged': sum(bool(r['flags'] & 1) for r in records),
            'apiChanged': sum(bool(r['flags'] & 2) for r in records),
            'peerChanged': sum(bool(r['flags'] & 4) for r in records),
            'apiMissing': sum(r['apiCalls'] == 0 for r in records),
            'apiErrors': sum(r['apiCalls'] > 0 and r['result'] != 0 for r in records)}.items():
        if footer.get(key) != count:
            errors.append(key + ' counter disagrees with records')
    by_id = {r['id']: r for r in records}
    for fault in faults:
        r = by_id.get(fault['id'])
        if not r or len(fault['snapshots']) != stages:
            errors.append('Fault has no corresponding full record')
            continue
        for i, s in enumerate(fault['snapshots']):
            b = bytes.fromhex(s['hex'])
            # Missing API is encoded as an all-zero snapshot, not SHA(empty).
            if i == 2 and r['apiCalls'] == 0:
                continue
            if btc and i in (5, 6) and r['copyCalls'] == 0:
                continue
            if len(b) != s['copied'] or s['length'] != r['lengths'][i] or digest(b) != r['hashes'][i]:
                errors.append('Fault bytes/fingerprint disagree at id ' + str(r['id']))

    usb_rows, usb_wire, usb_issues = read_usb_wire(usb_path)
    usb_index = collections.defaultdict(list)
    usb_by_identity = collections.defaultdict(list)
    usb_entries = []
    for raw, obj in usb_wire:
        if obj.get('t') == 's':
            # Exact firmware BLE base, before USB-only transport counters.
            marker = raw.find(',"serialdrop":')
            raw = raw[:marker] + '}'
        b = raw.encode('utf-8')
        key = (11, obj.get('seq')) if obj.get('t') == 'f' else (12, obj.get('uptime'))
        entry = {'kind': key[0], 'key': key[1], 'length': len(b), 'hash': digest(b)}
        usb_entries.append(entry)
        usb_index[(entry['kind'], entry['length'], entry['hash'])].append(entry)
        usb_by_identity[key].append(entry)
    usb_manifest = json.loads(Path(usb_path).with_name('manifest.json').read_text(encoding='utf-8-sig'))
    usb_seq = [obj['seq'] for _, obj in usb_wire if obj['t'] == 'f']
    usb_ok = (not usb_issues and usb_manifest.get('status') == 'closed' and
              all(usb_manifest.get(k) == 0 for k in ('serialParseErrors', 'serialErrors', 'readErrors', 'unrecordedRecords', 'sequenceGaps')) and
              usb_manifest.get('failure') is None and
              usb_manifest.get('acceptedRecords') == usb_manifest.get('writtenRecords') == len(usb_rows) and
              bool(usb_seq) and all(b == a + 1 for a, b in zip(usb_seq, usb_seq[1:])))

    changes = []
    unmapped = []
    target_channels = {}
    transition_count = 0
    transition_faults = []
    continuity = []
    last_values = {}
    btc_changes = []
    btc_missing, btc_multiple, btc_alias = [], [], []
    tokens = set()
    for n, r in enumerate(records):
        a, b, c, p, q = list(zip(r['lengths'], r['hashes']))[:5]
        if not r['flags'] & (8 | 16):
            for mask, mismatch in ((1, a != b), (2, r['apiCalls'] > 0 and a != c), (4, p != q),
                                   (32, r['apiCalls'] > 0 and (r['apiHandle'] != r['handle'] or bool(r['confirm']))),
                                   (64, r['apiCalls'] > 1)):
                if bool(r['flags'] & mask) != bool(mismatch):
                    errors.append('On-device byte-comparison flags disagree with exported evidence at id ' + str(r['id']))
                    break
        target_channels.setdefault(r['handle'], set()).add(r['sourceKind'])
        if a != b:
            changes.append({'id': r['id'], 'firstObservedBoundary': 'dequeue -> setValue/readback'})
        elif r['apiCalls'] and (b != c or r['apiHandle'] != r['handle'] or r['confirm']):
            changes.append({'id': r['id'], 'firstObservedBoundary': 'readback -> actual API arguments'})
        if p != q:
            changes.append({'id': r['id'], 'firstObservedBoundary': 'peer characteristic changed during setValue/readback'})
        if btc:
            if r['apiCalls']:
                if not r['apiToken'] or r['apiToken'] in tokens:
                    errors.append('Missing/repeated API token at id ' + str(r['id']))
                tokens.add(r['apiToken'])
            if not r['copyCalls']:
                if r['apiCalls']:
                    btc_missing.append(r['id'])
                if r['copyToken'] or any(r['lengths'][5:]) or any(h != '0' * 32 for h in r['hashes'][5:]):
                    errors.append('Missing copy has nonempty evidence at id ' + str(r['id']))
            else:
                if r['copyToken'] != r['apiToken'] or not r['copyToken']:
                    errors.append('Deep-copy/API token mismatch at id ' + str(r['id']))
                if r['copyCalls'] != 1:
                    btc_multiple.append(r['id'])
                source, dest = list(zip(r['lengths'], r['hashes']))[5:]
                expected_conn = ((r['conn'] & 255) << 8) | (r['gattsIf'] & 255)
                metadata_bad = (r['copySourceConn'] != expected_conn or r['copySourceHandle'] != r['apiHandle'] or
                                r['copySourceConfirm'] != r['confirm'] or r['copySourceAddress'] != r['apiSourceAddress'] or
                                source[0] != c[0] or r['copyDestConn'] != r['copySourceConn'] or
                                r['copyDestHandle'] != r['copySourceHandle'] or r['copyDestConfirm'] != r['copySourceConfirm'])
                alias = source[0] > 0 and r['copySourceAddress'] != 0 and r['copySourceAddress'] == r['copyDestinationAddress']
                for mask, mismatch in ((128, c != source), (256, source != dest), (512, metadata_bad),
                                       (1024, alias), (2048, r['copyCalls'] > 1 or r['apiCalls'] > 1)):
                    if not r['flags'] & (8 | 16) and bool(r['flags'] & mask) != bool(mismatch):
                        errors.append('Deep-copy byte/metadata flags disagree at id ' + str(r['id']))
                if alias:
                    btc_alias.append(r['id'])
                if c != source:
                    btc_changes.append({'id': r['id'], 'apiToken': r['apiToken'],
                                        'boundary': 'API entry -> BTC source before deep-copy'})
                if source != dest:
                    btc_changes.append({'id': r['id'], 'apiToken': r['apiToken'],
                                        'boundary': 'BTC source before -> destination after original deep-copy'})
                if metadata_bad:
                    btc_changes.append({'id': r['id'], 'apiToken': r['apiToken'], 'boundary': 'BTC argument metadata changed'})
        previous = last_values.get(r['peerHandle'])
        if previous and previous['snapshot'] != p:
            continuity.append({'id': r['id'], 'peerHandle': r['peerHandle'],
                               'previousMessageId': previous['id'],
                               'boundary': 'previous characteristic snapshot -> peer before next setValue'})
        last_values[r['handle']] = {'id': r['id'], 'snapshot': b}
        last_values[r['peerHandle']] = {'id': r['id'], 'snapshot': q}
        if (r['sourceKind'], a[0], a[1]) not in usb_index:
            candidates = usb_by_identity.get((r['sourceKind'], r['sourceKey']), [])
            unmapped.append({'id': r['id'], 'sourceKind': r['sourceKind'], 'sourceKey': r['sourceKey'],
                            'usbCandidates': candidates,
                            'meaning': 'dequeue fingerprint differs from same USB identity' if candidates else 'USB coverage/identity not established'})
        if n and records[n - 1]['sourceKind'] == 12 and r['sourceKind'] == 11 and records[n - 1]['lengths'][0] > r['lengths'][0]:
            transition_count += 1
            if a != b or (r['apiCalls'] and b != c) or p != q:
                transition_faults.append(r['id'])
    if any(len(channels) != 1 for channels in target_channels.values()) or (len(target_channels) == 2 and len(set(next(iter(v)) for v in target_channels.values())) != 2):
        errors.append('FF11/FF12 target handles are not independent')
    for r in records:
        if r['handle'] == r['peerHandle']:
            errors.append('Target and peer handles equal')
            break
    if btc:
        counters = {'copyCallbacks': sum(r['copyCalls'] for r in records), 'copyMissing': len(btc_missing),
                    'copySourceChanged': sum(bool(r['flags'] & 128) for r in records),
                    'copyDestChanged': sum(bool(r['flags'] & 256) for r in records),
                    'copyMetadataChanged': sum(bool(r['flags'] & 512) for r in records),
                    'copyAlias': len(btc_alias)}
        for key, value in counters.items():
            if footer.get(key) != value:
                errors.append(key + ' counter disagrees with records')
        if footer.get('copyUnmatched') != 0:
            errors.append('Unmatched deep-copy callbacks present or counter missing')
    handler_result = inspect_handlers(items, footer, records) if handler_mode else None
    if handler_result:
        errors.extend(handler_result['errors'])

    # Separate lane alignment: stats and frames may legitimately interleave
    # differently in the two workers, while each frame queue remains FIFO.
    usb_order = []
    for kind in (11, 12):
        lane = [r for r in records if r['sourceKind'] == kind]
        reference = [r for r in usb_entries if r['kind'] == kind]
        matcher = difflib.SequenceMatcher(a=[(r['lengths'][0], r['hashes'][0]) for r in lane],
                                         b=[(r['length'], r['hash']) for r in reference], autojunk=False)
        anchors = [b for b in matcher.get_matching_blocks() if b.size]
        if not anchors:
            continue
        first, last = anchors[0], anchors[-1]
        for tag, i, j, x, y in matcher.get_opcodes():
            if tag == 'equal' or i < first.a or j > last.a + last.size or x < first.b or y > last.b + last.size:
                continue
            usb_order.append({'kind': kind, 'operation': tag, 'dequeueMessageIds': [r['id'] for r in lane[i:j]],
                              'usbKeys': [r['key'] for r in reference[x:y]],
                              'note': 'Order/content difference within matching anchors; queue drops and coverage require interpretation.'})

    native = read_jsonl(ble_path)
    native_manifest = json.loads(Path(ble_path).with_name('manifest.json').read_text(encoding='utf-8-sig'))
    native_errors = []
    nums = [r['callback_n'] for r in native]
    if sorted(nums) != list(range(1, native_manifest.get('observedCallbacks', 0) + 1)):
        native_errors.append('Native callback numbers incomplete/repeated')
    if native_manifest.get('status') != 'closed':
        native_errors.append('Native log not closed')
    for key in ('droppedRecords', 'writeErrors', 'pendingRecords', 'undispatchedCallbacks'):
        if native_manifest.get(key) != 0:
            native_errors.append(key + ' nonzero/missing')
    for key in ('observedCallbacks', 'dispatchedCallbacks', 'enqueuedRecords', 'writtenRecords', 'flushedRecords'):
        if native_manifest.get(key) != len(native):
            native_errors.append(key + ' disagrees with native record count')
    for r in native:
        b = bytes.fromhex(r['hex'])
        if len(b) != r['length'] or hashlib.sha256(b).hexdigest() != r['sha256']:
            native_errors.append('Native bytes/hash/length mismatch')
    # Sequence alignment uses channel + complete payload fingerprint. It never
    # repairs seq or guesses an individual pairing across an insertion/deletion.
    api = [r for r in records if r['apiCalls'] == 1 and r['result'] == 0]
    def api_channel(r):
        lanes = target_channels.get(r['apiHandle'], set())
        return next(iter(lanes)) if len(lanes) == 1 else r['sourceKind']
    native = [r for r in native if 'ff11' in r['characteristic_uuid'].lower() or 'ff12' in r['characteristic_uuid'].lower()]
    observed = [(11 if 'ff11' in r['characteristic_uuid'].lower() else 12, digest(bytes.fromhex(r['hex']))) for r in native]
    def alignment(stream, stage):
        def channel(r):
            if stage == 7:
                lanes = target_channels.get(r['handlerHandle'], set())
                return next(iter(lanes)) if len(lanes) == 1 else r['sourceKind']
            if stage == 6:
                lanes = target_channels.get(r['copyDestHandle'], set())
                return next(iter(lanes)) if len(lanes) == 1 else r['sourceKind']
            return api_channel(r)
        expected = [(channel(r), r['hashes'][stage]) for r in stream]
        matcher = difflib.SequenceMatcher(a=expected, b=observed, autojunk=False)
        blocks = [b for b in matcher.get_matching_blocks() if b.size]
        comparisons, window = [], None
        if blocks:
            first, last = blocks[0], blocks[-1]
            window = {'firstMessageId': stream[first.a]['id'], 'lastMessageId': stream[last.a + last.size - 1]['id'],
                      'firstCallback': native[first.b]['callback_n'], 'lastCallback': native[last.b + last.size - 1]['callback_n']}
            for tag, i, j, x, y in matcher.get_opcodes():
                if tag == 'equal' or i < first.a or j > last.a + last.size or x < first.b or y > last.b + last.size:
                    continue
                comparisons.append({'operation': tag, 'apiMessageIds': [r['id'] for r in stream[i:j]],
                                    'nativeCallbacks': [{'callback_n': r['callback_n'], 'characteristic': observed[k][0],
                                                         'text': bytes.fromhex(r['hex']).decode('utf-8', errors='replace')}
                                                        for k, r in enumerate(native[x:y], x)]})
        return comparisons, window, sum(b.size for b in blocks)
    comparisons, window, matched = alignment(api, 2)
    report = {'inputs': {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
            'header': header, 'footer': footer, 'traceIntegrityErrors': errors,
            'traceCompleteAndConsistent': not errors, 'usbCompleteAndConsistent': usb_ok,
            'nativeIntegrityErrors': native_errors, 'nativeCompleteAndConsistent': not native_errors,
            'nativeOriginalMutationCount': sum(r.get('original_matches_snapshot') is False for r in native),
            'nativeMethodChannelUnavailable': sum(r.get('method_channel_available') is False for r in native),
            'stageDifferences': changes, 'dequeueWithoutExactUsbMatch': unmapped,
            'characteristicContinuityDifferences': continuity,
            'usbVsDequeueOrderDifferences': usb_order,
            'longFf12ThenShortFf11': {'checked': transition_count, 'differences': transition_faults},
            'handles': {str(k): sorted(v) for k, v in target_channels.items()},
            'missingApiMessages': [r['id'] for r in records if r['apiCalls'] == 0],
            'multipleApiMessages': [r['id'] for r in records if r['apiCalls'] > 1],
            'apiErrors': [r['id'] for r in records if r['apiCalls'] and r['result'] != 0],
            'alignedWindow': window, 'apiVsNativeDifferences': comparisons,
            'matchingApiNativeOccurrences': matched,
            'bothCharacteristicsMeasured': set(r['sourceKind'] for r in records) == {11, 12},
            'faultSnapshots': faults, 'physicalFixConfirmed': False,
            'limits': ['Only the captured RAM window is examined; a clean window does not establish a fix.',
                       'Normal records retain lengths and 128-bit SHA-256 fingerprints, not full payload bytes.',
                       'Byte equality is checked on device; at most two fault records retain full snapshots.',
                       'API entry is before BTC deep copy; this does not observe the copied BT queue or over-the-air bytes.',
                       'Readback includes getValue() allocation; a difference alone does not isolate setValue() internals.',
                       'API/native differences are aligned between matching anchors; no unique pairing is asserted in gaps.']}
    if usb_issues:
        report.update(usbWireReadIssues=usb_issues, usbStorageRecordCount=len(usb_rows),
                      usbWireRecordCount=len(usb_wire))
    if btc:
        copied = [r for r in api if r['copyCalls'] == 1 and r['copyToken'] == r['apiToken']]
        differences, btc_window, btc_matches = alignment(copied, 6)
        report.update(btcCopyDifferences=btc_changes, missingCopyMessages=btc_missing,
                      multipleCopyMessages=btc_multiple, aliasedCopyMessages=btc_alias,
                      btcVsNativeDifferences=differences, btcAlignedWindow=btc_window,
                      matchingBtcNativeOccurrences=btc_matches,
                      btcCopyObservationComplete=(not errors and not btc_missing and not btc_multiple and
                                                  not report['missingApiMessages'] and not report['multipleApiMessages'] and
                                                  not report['apiErrors'] and bool(copied)))
        report['limits'] = [x for x in report['limits'] if not x.startswith('API entry is before BTC')]
        report['limits'] += ['BTC destination is snapped after the real deep-copy callback returns and before btc_task_post.',
                             'A pre/post-copy difference localizes that interval; concurrent source mutation and allocation failure still require interpretation.',
                             'No observation of later BTC dequeue, controller/radio, or Android/GATT before native entry.']
    if handler_result:
        stream = []
        for h in handler_result['records']:
            p = by_id.get(h['id'])
            if not p or h['flags'] & 4 or h['token'] != p['copyToken']:
                continue
            if len(target_channels.get(h['handle'], set())) != 1:
                continue  # Unknown target cannot be labelled FF11/FF12 by guessing.
            entry = dict(p, handlerHandle=h['handle'], hashes=p['hashes'] + [h['hash']])
            stream.append(entry)
        diffs, aligned, count = alignment(stream, 7)
        complete = report['btcCopyObservationComplete'] and not handler_result['errors'] and not handler_result['missing'] and bool(stream)
        report.update(handlerIntegrityErrors=handler_result['errors'], handlerObservationComplete=complete,
                      handlerDifferences=handler_result['differences'], missingHandlerMessages=handler_result['missing'],
                      handlerSnapshots=handler_result['records'], handlerFaultSnapshots=handler_result['faults'],
                      handlerVsNativeDifferences=diffs, handlerAlignedWindow=aligned, matchingHandlerNativeOccurrences=count,
                      handlerPayloadChanged=(any(h['flags'] & 1 for h in handler_result['records']) if complete else None),
                      nextUnobservedBoundary=('btc_gatts_call_handler entry -> BTA_GATTS_HandleValueIndication input (not instrumented)'
                                              if complete and not handler_result['differences'] else None))
        report['limits'] = [x for x in report['limits'] if not x.startswith('No observation of later BTC dequeue')]
        report['limits'] += ['Handler input is snapped before calling the unmodified original handler; fingerprints are computed by the worker.',
                             'Unknown pointers or lengths above the registered allocation bound are not dereferenced; these observations are incomplete.',
                             'Untracked handler calls may be outside the bounded cohort; expected messages are joined only by registered message address and token.',
                             'No observation of BTA send API input, subsequent BTU/controller/radio, or Android/GATT before native entry.']
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('dump')
    p.add_argument('--port', required=True)
    p.add_argument('--baud', type=int, default=460800)
    p.add_argument('--timeout', type=float, default=45)
    p.add_argument('--output', type=Path, required=True)
    p = sub.add_parser('compare')
    p.add_argument('--trace', type=Path, required=True)
    p.add_argument('--usb', type=Path, required=True)
    p.add_argument('--ble', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'dump':
        dump_trace(args)
    else:
        report = compare(args.trace, args.usb, args.ble)
        if args.out.exists():
            raise SystemExit('Report exists; choose a new filename')
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
        print(json.dumps({k: report[k] for k in ('traceCompleteAndConsistent', 'usbCompleteAndConsistent',
                         'nativeCompleteAndConsistent', 'longFf12ThenShortFf11')}, ensure_ascii=False))
        if report.get('usbWireReadIssues'):
            print('usbWireReadIssues:', json.dumps(report['usbWireReadIssues'], ensure_ascii=False))
        print('stageDifferences:', len(report['stageDifferences']), 'apiVsNativeDifferences:', len(report['apiVsNativeDifferences']))
        if 'btcCopyDifferences' in report:
            print('btcCopyObservationComplete:', report['btcCopyObservationComplete'],
                  'btcCopyDifferences:', len(report['btcCopyDifferences']),
                  'btcVsNativeDifferences:', len(report['btcVsNativeDifferences']))
        if 'handlerDifferences' in report:
            print('handlerObservationComplete:', report['handlerObservationComplete'],
                  'handlerDifferences:', len(report['handlerDifferences']),
                  'handlerVsNativeDifferences:', len(report['handlerVsNativeDifferences']))
        print(args.out)


if __name__ == '__main__':
    main()

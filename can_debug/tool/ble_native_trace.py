"""ADB control and offline comparison of snapshot-v1 native BLE journals. No third-party Python dependencies."""
import argparse
import collections
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile
import time


def adb(args, *command, check=True):
    prefix = [args.adb] + (['-s', args.device] if args.device else [])
    return subprocess.run(prefix + list(command), check=check, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def latest(args):
    name = adb(args, 'exec-out', 'run-as', args.app, 'cat', 'files/ble_native_trace/latest.txt').decode().strip()
    if not re.fullmatch(r'run_\d+_\d+', name):
        raise ValueError('Invalid native journal run name')
    return name


def start(args):
    # Finish/export the previous monitoring session before invoking this command.
    try:
        previous = latest(args)
    except (subprocess.CalledProcessError, ValueError):
        previous = None
    adb(args, 'shell', 'am', 'force-stop', args.app)
    adb(args, 'shell', 'run-as', args.app, 'mkdir', '-p', 'files')
    adb(args, 'shell', 'run-as', args.app, 'rm', '-f', 'files/ble_trace_stop')
    adb(args, 'shell', 'run-as', args.app, 'touch', 'files/ble_trace_enabled')
    adb(args, 'shell', 'am', 'start', '-n', args.app + '/.MainActivity')
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            name = latest(args)
            if name != previous:
                value = json.loads(adb(args, 'exec-out', 'run-as', args.app, 'cat', f'files/ble_native_trace/{name}/manifest.json'))
                if value['status'] != 'active':
                    raise RuntimeError('New native journal is not active: ' + json.dumps(value))
                print('Native trace active:', name)
                print('Start Windows USB recording, then BLE monitoring. Previous trace files are retained.')
                return
        except (subprocess.CalledProcessError, ValueError):
            pass  # Worker/engine startup has not finished yet.
        time.sleep(0.25)
    raise RuntimeError('No new active trace appeared. Verify the patched debug APK is installed; do not use an old run.')


def stop(args):
    # Stop monitoring in the UI first; this command seals only the diagnostic log.
    adb(args, 'shell', 'run-as', args.app, 'touch', 'files/ble_trace_stop')
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        name = latest(args)
        raw = adb(args, 'exec-out', 'run-as', args.app, 'cat', f'files/ble_native_trace/{name}/manifest.json')
        manifest = json.loads(raw)
        if manifest['status'] != 'active':
            print(json.dumps({'run': name, **manifest}, indent=2))
            if manifest['status'] != 'closed':
                raise RuntimeError('Trace did not close cleanly; pull it for diagnosis')
            return
        time.sleep(0.25)
    raise RuntimeError('Trace close timed out; do not assume the log is complete')


def pull(args):
    name = latest(args)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / (name + '.tar')
    prefix = [args.adb] + (['-s', args.device] if args.device else [])
    # Binary stdout is written by Python; PowerShell redirection can corrupt tar.
    with archive.open('wb') as stream:
        subprocess.run(prefix + ['exec-out', 'run-as', args.app, 'tar', '-cf', '-', '-C', 'files/ble_native_trace', name],
                       stdout=stream, check=True)
    with tarfile.open(archive) as source:
        for entry in source.getmembers():
            target = (output / entry.name).resolve()
            if not target.is_relative_to((output / name).resolve()) or entry.issym() or entry.islnk():
                raise ValueError('Unexpected tar member')
        source.extractall(output, filter='data')
    print(output / name)


def disable(args):
    adb(args, 'shell', 'run-as', args.app, 'rm', '-f', 'files/ble_trace_enabled')
    adb(args, 'shell', 'run-as', args.app, 'touch', 'files/ble_trace_stop')
    print('New trace runs disabled. Snapshot forwarding remains active. Existing traces are retained.')


def sequence_summary(frames):
    values = [f['seq'] for f in frames if type(f.get('seq')) is int]
    unique = sorted(set(values))
    intervals = [[a + 1, b - 1] for a, b in zip(unique, unique[1:]) if b > a + 1]
    return {'count': len(values), 'unique': len(unique), 'min': min(unique) if unique else None,
            'max': max(unique) if unique else None, 'duplicateOccurrences': len(values) - len(unique),
            'missingCountInNumericRange': sum(b - a + 1 for a, b in intervals), 'missingIntervals': intervals,
            'note': 'Numeric-range counts are not transport loss; reboot/wrap epochs require separate interpretation.'}


def compare(ble_path, usb_path, android_session=None):
    ble_path, usb_path = Path(ble_path), Path(usb_path)
    manifest = json.loads(ble_path.with_name('manifest.json').read_text(encoding='utf-8-sig'))
    rows = [json.loads(line) for line in ble_path.read_text(encoding='utf-8-sig').splitlines() if line.strip()]
    usb = [json.loads(line) for line in usb_path.read_text(encoding='utf-8-sig').splitlines() if line.strip()]
    usb = [json.loads(row['rawJson']) if 'rawJson' in row else row for row in usb]
    usb_frames = [x for x in usb if x.get('t') == 'f']
    usb_manifest_path = usb_path.with_name('manifest.json')
    usb_manifest = json.loads(usb_manifest_path.read_text(encoding='utf-8-sig')) if usb_manifest_path.exists() else None
    usb_stats = {x['uptime']: x for x in usb if x.get('t') == 's' and 'uptime' in x}
    by_seq = collections.defaultdict(list)
    for f in usb_frames:
        by_seq[f['seq']].append(f)
    integrity, invalid_json, mutations, frames, stats, frame_rows = [], [], [], [], [], []
    seen_n = set()
    for index, row in enumerate(rows, 1):
        n = row['callback_n']
        if type(n) is not int or n < 1 or n > manifest.get('observedCallbacks', 0):
            integrity.append({'line': index, 'reason': 'callback_n outside manifest range'})
        if n in seen_n:
            integrity.append({'line': index, 'reason': 'duplicate callback_n'})
        seen_n.add(n)
        raw = None if row['hex'] is None else bytes.fromhex(row['hex'])
        actual_hash = None if raw is None else hashlib.sha256(raw).hexdigest()
        if actual_hash != row['sha256'] or row['length'] != (-1 if raw is None else len(raw)):
            integrity.append({'line': index, 'reason': 'snapshot length/hash mismatch'})
            continue
        if row.get('original_matches_snapshot') is False:
            mutations.append(row)
            changed = row.get('original_before_dispatch_hex_if_changed')
            digest = None if changed is None else hashlib.sha256(bytes.fromhex(changed)).hexdigest()
            if digest != row.get('original_before_dispatch_sha256') or digest == row['sha256']:
                integrity.append({'line': index, 'reason': 'inconsistent mutation evidence'})
        if row.get('gatt_status', 0) != 0:
            continue  # Failed reads are not malformed notifications.
        try:
            obj = json.loads(raw.decode('utf8'))
            if not isinstance(obj, dict):
                raise ValueError('Not a JSON object')
        except (ValueError, UnicodeError, AttributeError) as error:
            invalid_json.append({'callback_n': n, 'characteristic': row['characteristic_uuid'], 'reason': str(error), 'hex': row['hex']})
            continue
        if obj.get('t') == 'f':
            frames.append(obj)
            frame_rows.append((row, obj))
        elif obj.get('t') == 's':
            stats.append(obj)
    identical, differences, outside = 0, [], []
    for row, frame in frame_rows:
        candidates = by_seq.get(frame.get('seq'), [])
        if not candidates:
            outside.append({'callback_n': row['callback_n'], 'seq': frame.get('seq')})
        elif frame in candidates:
            identical += 1
        else:
            differences.append({'callback_n': row['callback_n'], 'ble': frame, 'usbCandidates': candidates})
    stats_diffs = []
    stats_matched = 0
    for value in stats:
        candidate = usb_stats.get(value.get('uptime'))
        if candidate is not None:
            diff = {k: [v, candidate.get(k)] for k, v in value.items() if v != candidate.get(k)}
            if diff:
                stats_diffs.append({'uptime': value.get('uptime'), 'fields': diff})
            else:
                stats_matched += 1
    if manifest.get('originalChanges') != len(mutations):
        integrity.append({'reason': 'manifest mutation count mismatch'})
    healthy = (manifest.get('status') == 'closed' and manifest.get('droppedRecords') == 0 and
               manifest.get('writeErrors') == 0 and manifest.get('undispatchedCallbacks') == 0 and
               manifest.get('pendingRecords') == 0 and manifest.get('writtenRecords') == len(rows) and
               manifest.get('flushedRecords') == len(rows) and manifest.get('observedCallbacks') == len(rows) and
               manifest.get('enqueuedRecords') == len(rows) and not integrity)
    result = {
        'inputs': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [ble_path, usb_path]},
        'manifest': manifest, 'journalCompleteAndConsistent': healthy, 'journalIntegrityErrors': integrity,
        'usbManifest': usb_manifest,
        'usbJournalCompleteAndConsistent': bool(usb_manifest and usb_manifest.get('status') == 'closed' and
            usb_manifest.get('acceptedRecords') == usb_manifest.get('writtenRecords') == len(usb) and
            usb_manifest.get('unrecordedRecords') == 0 and usb_manifest.get('failure') is None and
            usb_manifest.get('serialParseErrors') == usb_manifest.get('serialErrors') == 0),
        'callbackKinds': dict(collections.Counter(r['callback_kind'] for r in rows)),
        'androidSdkLevels': dict(collections.Counter(r['sdk_int'] for r in rows)),
        'originalMutationCount': len(mutations), 'originalMutationEvidence': mutations,
        'uncomparedOriginals': sum(r.get('original_matches_snapshot') is None for r in rows),
        'methodChannelUnavailable': sum(not r.get('method_channel_available', True) for r in rows),
        'failedGattCallbacks': sum(r.get('gatt_status', 0) != 0 for r in rows),
        'invalidJsonCallbacks': invalid_json, 'bleSequence': sequence_summary(frames), 'usbSequence': sequence_summary(usb_frames),
        'identicalFrameOccurrences': identical, 'frameDifferences': differences, 'framesWithoutUsbSequence': outside,
        'bleStatsCount': len(stats), 'identicalStatsWithinUsbCoverage': stats_matched, 'statsDifferences': stats_diffs,
        'physicalFixConfirmed': False,
        'interpretation': 'A clean run is evidence for this capture only. Changed originals prove mutation between native snapshot and UI probe; unchanged but conflicting snapshots leave an upstream cause unresolved. No ESP32/HCI work is started automatically.',
    }
    if android_session:
        original = json.loads(Path(android_session).read_text(encoding='utf-8-sig'))
        session = original.get('session', original)
        normalized = [f.get('rawWire') for f in session['frames']]
        # Counts differ if session/log boundaries differ. Preserve order; never sort by seq.
        result['androidSession'] = {'frames': len(normalized), 'rawFramesExactlyEqualNativeFramesInOrder': normalized == frames,
                                    'captureMetadata': session.get('captureMetadata')}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--device', help='ADB device serial if several devices are connected')
    parser.add_argument('--app', default='com.example.can_debug')
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ['start', 'stop', 'disable']:
        sub.add_parser(name)
    capture = sub.add_parser('pull')
    capture.add_argument('--output', default='build/ble_native_capture')
    comparison = sub.add_parser('compare')
    comparison.add_argument('--ble', required=True, help='Extracted notifications.jsonl')
    comparison.add_argument('--usb', required=True, help='Windows capture.jsonl')
    comparison.add_argument('--android-session', help='Optional JSON export of this Android session')
    comparison.add_argument('--out', default='build/ble_native_comparison.json')
    args = parser.parse_args()
    if args.command == 'compare':
        result = compare(args.ble, args.usb, args.android_session)
        output = Path(args.out)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2, ensure_ascii=True), encoding='utf8')
        print(json.dumps({k: result[k] for k in ['journalCompleteAndConsistent', 'usbJournalCompleteAndConsistent', 'callbackKinds', 'androidSdkLevels',
              'originalMutationCount', 'uncomparedOriginals', 'methodChannelUnavailable', 'identicalFrameOccurrences', 'bleStatsCount']}))
        print('frameDifferences:', len(result['frameDifferences']), 'invalidJsonCallbacks:', len(result['invalidJsonCallbacks']))
        print(output)
    else:
        {'start': start, 'stop': stop, 'pull': pull, 'disable': disable}[args.command](args)


if __name__ == '__main__':
    main()

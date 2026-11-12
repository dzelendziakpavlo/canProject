import 'dart:convert';

import '../models/can_session.dart';

class SessionExport {
  static Map<String, int> counts(CanSession session) => {
    'frames': session.frames.length,
    'statsSnapshots': session.statsSnapshots.length,
    'events': session.events.length,
  };

  static void verify(CanSession session) {
    final capture = session.captureMetadata;
    if (capture['storage'] == 'sqlite') {
      for (final entry in {
        'committedFrames': session.frames.length,
        'committedStats': session.statsSnapshots.length,
        'committedEvents': session.events.length,
      }.entries) {
        if (capture[entry.key] != entry.value) {
          throw StateError(
            'Export count mismatch: ${entry.key}: '
            '${capture[entry.key]} stored / ${entry.value} loaded',
          );
        }
      }
    }
  }

  static String json(CanSession session) {
    verify(session);
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'can-debug-session-export',
      'version': 2,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'counts': counts(session),
      'scope':
          'All persisted session records; independent of Analytics filters',
      'session': session.toJson(),
    });
  }

  /// One CSV includes frames, telemetry, events and session metadata. JSON payload
  /// preserves optional/future diagnostic fields without assigning them to CAN IDs.
  static String csv(CanSession session) {
    verify(session);
    final output = StringBuffer();
    void row(List<Object?> fields) => output.writeln(
      fields
          .map(
            (value) => '"${(value?.toString() ?? '').replaceAll('"', '""')}"',
          )
          .join(','),
    );
    row([
      'record_type',
      'session_id',
      'timestamp',
      'id',
      'dlc',
      'data_hex',
      'rtr',
      'extended',
      'seq',
      'receiver_ms',
      'tec',
      'rec',
      'buserr',
      'state',
      'evidence',
      'payload_json',
    ]);
    row([
      'metadata',
      session.id,
      session.startTime.toIso8601String(),
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      jsonEncode({
        'id': session.id,
        'name': session.name,
        'sourceName': session.sourceName,
        'schemaVersion': session.schemaVersion,
        'captureMetadata': session.captureMetadata,
        'startTime': session.startTime.toIso8601String(),
        'endTime': session.endTime?.toIso8601String(),
        'totalFrames': session.totalFrames,
        'errorFrames': session.errorFrames,
        'errorRate': session.errorRate,
        'errorStats': session.errorStats.map(
          (key, value) => MapEntry(key.toString(), value),
        ),
        'isActive': session.isActive,
        'frames': [],
        'statsSnapshots': [],
        'events': [],
        'exportCounts': counts(session),
      }),
    ]);
    for (final f in session.frames) {
      row([
        'frame',
        session.id,
        f.timestamp.toIso8601String(),
        f.id,
        f.dlc,
        f.dataHex,
        f.isRtr,
        f.isExtended,
        f.sequence,
        f.receiverTimestampMs,
        '',
        '',
        '',
        '',
        f.errors.isEmpty ? '' : 'stored frame evidence',
        jsonEncode(f.toJson()),
      ]);
    }
    for (final s in session.statsSnapshots) {
      row([
        'stats',
        session.id,
        s.timestamp.toIso8601String(),
        '',
        '',
        '',
        '',
        '',
        '',
        s.uptimeMs,
        s.txErrorCounter,
        s.rxErrorCounter,
        s.busErrorCount,
        s.busState,
        'telemetry',
        jsonEncode(s.toJson()),
      ]);
    }
    for (final e in session.events) {
      row([
        'event',
        session.id,
        e.timestamp.toIso8601String(),
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        e.evidence.name,
        jsonEncode(e.toJson()),
      ]);
    }
    return output.toString();
  }
}

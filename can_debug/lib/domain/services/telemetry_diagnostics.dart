import '../models/can_session_event.dart';
import '../models/can_stats.dart';

/// TWAI aggregate counters cannot identify a wire CRC/ACK/Stuffing/Form error.
class TelemetryDiagnostics {
  CanStats? _previous;

  void reset() => _previous = null;

  List<CanSessionEvent> accept(CanStats current, {String? sourceName}) {
    final previous = _previous;
    if (previous != null &&
        current.uptimeMs != null &&
        current.uptimeMs == previous.uptimeMs &&
        current
            .toJson()
            .entries
            .where((e) => e.key != 'timestamp')
            .every((e) => previous.toJson()[e.key] == e.value)) {
      return const [];
    }
    _previous = current;
    if (previous == null) return const [];
    final reset =
        current.rxTotal < previous.rxTotal ||
        current.busErrorCount < previous.busErrorCount ||
        (current.uptimeMs != null &&
            previous.uptimeMs != null &&
            current.uptimeMs! < previous.uptimeMs!);
    if (reset) {
      return [
        CanSessionEvent.create(
          type: CanSessionEventType.note,
          message: 'Receiver counters reset; new telemetry baseline',
          timestamp: current.timestamp,
          sourceName: sourceName,
          evidence: DiagnosticEvidence.telemetry,
        ),
      ];
    }
    final deltas = <String, int>{
      'busErrorDelta': current.busErrorCount - previous.busErrorCount,
      'txFailedDelta': current.txFailedCount - previous.txFailedCount,
      'rxOverrunDelta': current.rxOverrunCount - previous.rxOverrunCount,
      'rxMissedDelta': current.rxMissed - previous.rxMissed,
      'arbitrationLostDelta': current.arbLostCount - previous.arbLostCount,
    };
    if (deltas.values.every((v) => v <= 0) &&
        current.busState == previous.busState &&
        current.isErrorPassive == previous.isErrorPassive &&
        current.isErrorWarning == previous.isErrorWarning) {
      return const [];
    }
    return [
      CanSessionEvent.create(
        type: CanSessionEventType.diagnostic,
        message:
            'TWAI counter/state change (protocol error subtype unavailable)',
        timestamp: current.timestamp,
        sourceName: sourceName,
        evidence: DiagnosticEvidence.telemetry,
        diagnosticSeverity: current.isBusOff
            ? DiagnosticSeverity.critical
            : DiagnosticSeverity.warning,
        diagnosticCause: current.isBusOff
            ? DiagnosticCause.busOff
            : DiagnosticCause.unknown,
        explanation:
            'Receiver telemetry confirms counters and state only. '
            'No frame ID or CRC/ACK/Stuffing/Form subtype is reported.',
        data: {
          ...deltas.map((k, v) => MapEntry(k, v < 0 ? 0 : v)),
          'intervalStart': previous.timestamp.toIso8601String(),
          'intervalEnd': current.timestamp.toIso8601String(),
          'tec': current.txErrorCounter,
          'rec': current.rxErrorCounter,
          'state': current.busState,
        },
      ),
    ];
  }
}

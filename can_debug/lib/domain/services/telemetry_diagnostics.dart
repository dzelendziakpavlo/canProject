import 'dart:convert';

import '../models/can_session_event.dart';
import '../models/can_stats.dart';
import '../source/can_frame_source.dart';

enum CanTrafficState { active, silent, unknown }

enum CanTransportState {
  active,
  connected,
  connecting,
  stale,
  disconnected,
  stopped,
}

/// Current evidence for UI, not a second health scoring mechanism.
class CanBusDiagnosticsSnapshot {
  const CanBusDiagnosticsSnapshot({
    required this.traffic,
    required this.transport,
    required this.stats,
    required this.lastTelemetryAt,
    required this.busErrorDelta,
    required this.rxOverflowActive,
  });

  final CanTrafficState traffic;
  final CanTransportState transport;
  final CanStats? stats;
  final DateTime? lastTelemetryAt;
  final int? busErrorDelta;
  final bool rxOverflowActive;

  String get node => switch (stats?.nodeName.toLowerCase()) {
    'sender' => 'SENDER',
    'receiver' => 'RECEIVER',
    _ => 'Unknown',
  };

  int? counter(String key) {
    final value = stats;
    if (value == null || !value.hasWireCounter(key)) return null;
    return switch (key) {
      'rx' => value.rxTotal,
      'txe' => value.txErrorCounter,
      'rxe' => value.rxErrorCounter,
      'buserr' => value.busErrorCount,
      'missed' => value.rxMissed,
      'ovr' => value.rxOverrunCount,
      _ => null,
    };
  }

  /// Current schemas carry no verified per-type counters, including zeroes.
  Map<String, int?> get typedErrors => const {
    'CRC': null,
    'Stuff': null,
    'Form': null,
    'ACK': null,
    'Bit': null,
  };
}

/// TWAI evidence and traffic/transport transitions shared by UI and session log.
/// Aggregate counters never identify a CRC/ACK/Stuff/Form subtype or CAN ID.
class TelemetryDiagnostics {
  TelemetryDiagnostics({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const silentTimeout = Duration(seconds: 3);
  static const telemetryTimeout = Duration(seconds: 4);
  final DateTime Function() _clock;
  CanStats? _previous;
  DateTime? _epochStartedAt, _lastFrameAt, _lastMessageAt, _lastTelemetryAt;
  SourceState _sourceState = SourceState.idle;
  CanTrafficState _traffic = CanTrafficState.unknown;
  CanTransportState _transport = CanTransportState.stopped;
  bool _rxOverflowActive = false;
  int? _busErrorDelta;
  final List<CanSessionEvent> _recent = [];

  DateTime get _now => _clock().toUtc();
  List<CanSessionEvent> get recentEvents => List.unmodifiable(_recent);
  bool get _connected =>
      _sourceState == SourceState.connected ||
      _sourceState == SourceState.streaming;
  bool _fresh(DateTime? at, Duration limit) =>
      at != null && _now.difference(at) <= limit;

  CanBusDiagnosticsSnapshot get snapshot {
    final freshStats = _connected && _fresh(_lastTelemetryAt, telemetryTimeout);
    return CanBusDiagnosticsSnapshot(
      traffic: _traffic,
      transport: _transport,
      stats: freshStats ? _previous : null,
      lastTelemetryAt: freshStats ? _lastTelemetryAt : null,
      busErrorDelta: freshStats ? _busErrorDelta : null,
      rxOverflowActive: freshStats && _rxOverflowActive,
    );
  }

  void reset() {
    _clearEpoch();
    _sourceState = SourceState.idle;
    _traffic = CanTrafficState.unknown;
    _transport = CanTransportState.stopped;
    _recent.clear();
  }

  void _clearEpoch() {
    _previous = null;
    _epochStartedAt = _now;
    _lastFrameAt = _lastMessageAt = _lastTelemetryAt = null;
    _busErrorDelta = null;
    _rxOverflowActive = false;
  }

  List<CanSessionEvent> _remember(List<CanSessionEvent> events) {
    _recent.addAll(events);
    if (_recent.length > 50) _recent.removeRange(0, _recent.length - 50);
    return events;
  }

  List<CanSessionEvent> updateSourceState(
    SourceState state, {
    String? sourceName,
  }) {
    final wasConnected = _connected;
    if (state == _sourceState) return const [];
    _sourceState = state;
    if (!_connected || !wasConnected) _clearEpoch();
    return poll(sourceName: sourceName);
  }

  List<CanSessionEvent> frameReceived({String? sourceName}) {
    _lastFrameAt = _lastMessageAt = _now;
    return poll(sourceName: sourceName);
  }

  /// Called by the monitor timer even when no new frames arrive.
  List<CanSessionEvent> poll({String? sourceName}) {
    final now = _now;
    final nextTransport = switch (_sourceState) {
      SourceState.idle => CanTransportState.stopped,
      SourceState.scanning ||
      SourceState.connecting ||
      SourceState.reconnecting => CanTransportState.connecting,
      SourceState.disconnected ||
      SourceState.lost ||
      SourceState.error => CanTransportState.disconnected,
      SourceState.connected || SourceState.streaming =>
        _lastMessageAt == null
            ? CanTransportState.connected
            : _fresh(_lastMessageAt, telemetryTimeout)
            ? CanTransportState.active
            : CanTransportState.stale,
    };
    final nextTraffic = !_connected
        ? CanTrafficState.unknown
        : _fresh(_lastFrameAt, silentTimeout)
        ? CanTrafficState.active
        : _fresh(_lastTelemetryAt, telemetryTimeout) &&
              _epochStartedAt != null &&
              now.difference(_epochStartedAt!) >= silentTimeout
        ? CanTrafficState.silent
        : CanTrafficState.unknown;
    final events = <CanSessionEvent>[];
    if (nextTraffic != _traffic) {
      if (nextTraffic == CanTrafficState.silent ||
          _traffic == CanTrafficState.silent) {
        final resumed = nextTraffic == CanTrafficState.active;
        final started = nextTraffic == CanTrafficState.silent;
        events.add(
          CanSessionEvent.create(
            type: CanSessionEventType.diagnostic,
            timestamp: now,
            sourceName: sourceName,
            message: started
                ? 'CAN traffic lost — no frames received'
                : resumed
                ? 'CAN traffic restored'
                : 'CAN traffic observation interrupted',
            evidence: DiagnosticEvidence.inferred,
            diagnosticCause: started || resumed
                ? DiagnosticCause.silentBus
                : DiagnosticCause.transportLoss,
            diagnosticSeverity: started
                ? DiagnosticSeverity.warning
                : DiagnosticSeverity.info,
            explanation: started
                ? 'Diagnostic telemetry is arriving, but no CAN frames were received within 3 s. Physical cause and error subtype are unknown.'
                : resumed
                ? 'New CAN frames were received; the silent interval ended.'
                : 'Transport/data availability changed; CAN recovery is not confirmed.',
            data: {
              'component': 'can_bus_diagnostics',
              'eventCode': 'can_traffic',
              'phase': started
                  ? 'started'
                  : resumed
                  ? 'recovered'
                  : 'interrupted',
              'timestampSource': 'host_observed_utc',
              'node': snapshot.node,
              'direction': null,
              'trafficState': nextTraffic.name,
              'transportState': nextTransport.name,
              'lastFrameReceivedAt': _lastFrameAt?.toIso8601String(),
            },
          ),
        );
      }
      _traffic = nextTraffic;
    }
    if (nextTransport != _transport) {
      if (nextTransport == CanTransportState.disconnected ||
          nextTransport == CanTransportState.stale ||
          _transport == CanTransportState.disconnected ||
          _transport == CanTransportState.stale) {
        events.add(
          CanSessionEvent.create(
            type: CanSessionEventType.diagnostic,
            timestamp: now,
            sourceName: sourceName,
            message: 'Transport ${nextTransport.name}; CAN fault not inferred',
            evidence: DiagnosticEvidence.inferred,
            diagnosticCause: DiagnosticCause.transportLoss,
            diagnosticSeverity: nextTransport == CanTransportState.active
                ? DiagnosticSeverity.info
                : DiagnosticSeverity.warning,
            data: {
              'component': 'can_bus_diagnostics',
              'eventCode': 'transport',
              'timestampSource': 'host_observed_utc',
              'node': 'Unknown',
              'direction': null,
              'previousState': _transport.name,
              'transportState': nextTransport.name,
            },
          ),
        );
      }
      _transport = nextTransport;
    }
    return _remember(events);
  }

  List<CanSessionEvent> accept(CanStats current, {String? sourceName}) {
    final previous = _previous;
    _lastMessageAt = _now;
    // Repeated packets prove transport activity, not fresh controller telemetry.
    if (previous != null &&
        current.uptimeMs != null &&
        current.uptimeMs == previous.uptimeMs &&
        jsonEncode(
              {...current.toJson()}
                ..remove('timestamp')
                ..remove('rawWire'),
            ) ==
            jsonEncode(
              {...previous.toJson()}
                ..remove('timestamp')
                ..remove('rawWire'),
            )) {
      return const [];
    }
    _lastTelemetryAt = _now;
    _previous = current;
    if (previous == null) {
      if (current.isRunning &&
          !current.isErrorPassive &&
          !current.isErrorWarning) {
        return const [];
      }
      return _remember([
        CanSessionEvent.create(
          type: CanSessionEventType.diagnostic,
          message: 'TWAI controller fault observed at telemetry baseline',
          timestamp: current.timestamp,
          sourceName: sourceName,
          evidence: DiagnosticEvidence.telemetry,
          diagnosticSeverity: current.isBusOff
              ? DiagnosticSeverity.critical
              : DiagnosticSeverity.warning,
          diagnosticCause: current.isBusOff
              ? DiagnosticCause.busOff
              : DiagnosticCause.unknown,
          data: {
            'component': 'can_bus_diagnostics',
            'eventCode': 'controller_baseline',
            'timestampSource': 'host_received_utc',
            'node': current.nodeName,
            'direction': null,
            'tec': current.txErrorCounter,
            'rec': current.rxErrorCounter,
            'state': current.busState,
          },
        ),
      ]);
    }
    final reset =
        current.rxTotal < previous.rxTotal ||
        current.busErrorCount < previous.busErrorCount ||
        current.rxMissed < previous.rxMissed ||
        (current.hasWireCounter('ovr') &&
            previous.hasWireCounter('ovr') &&
            current.rxOverrunCount < previous.rxOverrunCount) ||
        current.nodeName != previous.nodeName ||
        (current.uptimeMs != null &&
            previous.uptimeMs != null &&
            current.uptimeMs! < previous.uptimeMs!);
    if (reset) {
      _epochStartedAt = _now;
      _lastFrameAt = null;
      _busErrorDelta = null;
      _rxOverflowActive = false;
      return _remember([
        CanSessionEvent.create(
          type: CanSessionEventType.note,
          message: 'Receiver counters reset; new telemetry baseline',
          timestamp: current.timestamp,
          sourceName: sourceName,
          evidence: DiagnosticEvidence.telemetry,
          data: {
            'component': 'can_bus_diagnostics',
            'eventCode': 'counter_reset',
            'timestampSource': 'host_received_utc',
            'node': current.nodeName,
            'direction': null,
          },
        ),
      ]);
    }
    int? delta(String key, int after, int before) =>
        current.hasWireCounter(key) && previous.hasWireCounter(key)
        ? (after - before).clamp(0, 0xffffffff)
        : null;
    final deltas = <String, int?>{
      'busErrorDelta': delta(
        'buserr',
        current.busErrorCount,
        previous.busErrorCount,
      ),
      'txFailedDelta': delta(
        'txfail',
        current.txFailedCount,
        previous.txFailedCount,
      ),
      'rxOverrunDelta': delta(
        'ovr',
        current.rxOverrunCount,
        previous.rxOverrunCount,
      ),
      'rxMissedDelta': delta('missed', current.rxMissed, previous.rxMissed),
      'arbitrationLostDelta': delta(
        'arb',
        current.arbLostCount,
        previous.arbLostCount,
      ),
    };
    _busErrorDelta = deltas['busErrorDelta'];
    final wasOverflow = _rxOverflowActive;
    _rxOverflowActive =
        (deltas['rxOverrunDelta'] ?? 0) > 0 ||
        (deltas['rxMissedDelta'] ?? 0) > 0;
    if (deltas.values.whereType<int>().every((v) => v == 0) &&
        current.busState == previous.busState &&
        current.txErrorCounter == previous.txErrorCounter &&
        current.rxErrorCounter == previous.rxErrorCounter &&
        wasOverflow == _rxOverflowActive) {
      return const [];
    }
    final cleared =
        deltas.values.whereType<int>().every((v) => v == 0) &&
        current.isRunning &&
        !current.isErrorPassive &&
        !current.isErrorWarning &&
        !_rxOverflowActive &&
        (!previous.isRunning ||
            previous.isErrorPassive ||
            previous.isErrorWarning ||
            wasOverflow);
    return _remember([
      CanSessionEvent.create(
        type: CanSessionEventType.diagnostic,
        message: cleared
            ? 'TWAI fault state cleared; historical counters retained'
            : 'TWAI counter/state change (protocol error subtype unavailable)',
        timestamp: current.timestamp,
        sourceName: sourceName,
        evidence: DiagnosticEvidence.telemetry,
        diagnosticSeverity: current.isBusOff
            ? DiagnosticSeverity.critical
            : cleared
            ? DiagnosticSeverity.info
            : DiagnosticSeverity.warning,
        diagnosticCause: current.isBusOff
            ? DiagnosticCause.busOff
            : _rxOverflowActive
            ? DiagnosticCause.rxOverflow
            : DiagnosticCause.unknown,
        explanation:
            'Telemetry confirms counters and controller state only. No CAN ID or CRC/ACK/Stuff/Form/Bit subtype is reported.',
        data: {
          ...deltas,
          'component': 'can_bus_diagnostics',
          'eventCode': 'twai_counters',
          'phase': cleared ? 'recovered' : 'changed',
          'timestampSource': 'host_received_utc',
          'node': current.nodeName,
          'direction': null,
          'intervalStart': previous.timestamp.toIso8601String(),
          'intervalEnd': current.timestamp.toIso8601String(),
          'controllerUptimeMs': current.uptimeMs,
          'tec': current.txErrorCounter,
          'rec': current.rxErrorCounter,
          'state': current.busState,
        },
      ),
    ]);
  }
}

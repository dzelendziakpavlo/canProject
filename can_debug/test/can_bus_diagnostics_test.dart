import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/domain/detection/can_health_analyzer.dart';
import 'package:can_debug/domain/models/can_session_event.dart';
import 'package:can_debug/domain/models/can_stats.dart';
import 'package:can_debug/domain/services/telemetry_diagnostics.dart';
import 'package:can_debug/domain/source/can_frame_source.dart';

void main() {
  late DateTime now;
  late TelemetryDiagnostics diagnostics;
  final base = DateTime.utc(2026, 11, 25);
  CanStats stats({
    int rx = 36,
    int buserr = 0,
    int tec = 0,
    int rec = 0,
    int missed = 0,
    String state = 'RUNNING',
    bool optional = true,
    int overrun = 0,
    int? uptime,
    String? node = 'receiver',
  }) => CanStats.fromJson({
    't': 's',
    'rx': rx,
    'buserr': buserr,
    'txe': tec,
    'rxe': rec,
    'missed': missed,
    'state': state,
    if (optional) ...{'ovr': overrun, 'txfail': 0, 'arb': 0},
    if (node != null) 'node': node,
    'uptime': uptime ?? now.difference(base).inMilliseconds + 1000,
    'noack': 1,
    'sdemo': 1,
  });
  void advance(int milliseconds) =>
      now = now.add(Duration(milliseconds: milliseconds));
  void receive(CanStats value) {
    diagnostics.accept(value);
    diagnostics.poll();
  }

  int phases(String phase) => diagnostics.recentEvents
      .where(
        (e) => e.data['eventCode'] == 'can_traffic' && e.data['phase'] == phase,
      )
      .length;

  setUp(() {
    now = base;
    diagnostics = TelemetryDiagnostics(clock: () => now);
    diagnostics.updateSourceState(SourceState.streaming);
  });

  test(
    'normal traffic exposes reported zeroes, unsupported categories stay N/A',
    () {
      receive(stats());
      diagnostics.frameReceived();
      final value = diagnostics.snapshot;
      expect(value.traffic, CanTrafficState.active);
      expect(value.transport, CanTransportState.active);
      expect(value.counter('buserr'), 0);
      expect(value.counter('ovr'), 0);
      expect(value.typedErrors.values.every((v) => v == null), isTrue);
      expect(value.node, 'RECEIVER');
    },
  );

  test(
    'logical GPIO5 scenario: no new frame, live telemetry, one silent start and recovery',
    () {
      receive(stats());
      diagnostics.frameReceived();
      for (var i = 0; i < 5; i++) {
        advance(1000);
        receive(stats());
      }
      expect(diagnostics.snapshot.traffic, CanTrafficState.silent);
      expect(diagnostics.snapshot.transport, CanTransportState.active);
      expect(phases('started'), 1);
      for (var i = 0; i < 20; i++) {
        diagnostics.poll();
      }
      expect(phases('started'), 1);
      final health = CanHealthAnalyzer();
      expect(
        health
            .analyze(
              latestStats: diagnostics.snapshot.stats,
              errorRate: 0,
              errorDetectedEvents: 0,
              reconnectCount: 0,
              busIsSilent: true,
            )
            .score,
        75,
      );
      diagnostics.frameReceived();
      expect(diagnostics.snapshot.traffic, CanTrafficState.active);
      expect(phases('recovered'), 1);
      expect(
        health
            .analyze(
              latestStats: diagnostics.snapshot.stats,
              errorRate: 0,
              errorDetectedEvents: 0,
              reconnectCount: 0,
              busIsSilent: false,
            )
            .score,
        100,
      );
      final event = diagnostics.recentEvents.firstWhere(
        (e) => e.data['phase'] == 'started',
      );
      expect(event.evidence, DiagnosticEvidence.inferred);
      expect(event.data['timestampSource'], 'host_observed_utc');
      expect(event.data['direction'], isNull);
    },
  );

  test('traffic never received is silent after grace while stats continue', () {
    receive(stats(rx: 0));
    advance(3100);
    receive(stats(rx: 0));
    expect(diagnostics.snapshot.traffic, CanTrafficState.silent);
  });

  test(
    'missing all transport data means Unknown, not a physical CAN diagnosis',
    () {
      receive(stats());
      diagnostics.frameReceived();
      advance(5000);
      diagnostics.poll();
      expect(diagnostics.snapshot.traffic, CanTrafficState.unknown);
      expect(diagnostics.snapshot.transport, CanTransportState.stale);
      expect(diagnostics.snapshot.stats, isNull);
      expect(diagnostics.snapshot.counter('txe'), isNull);
      expect(phases('started'), 0);
    },
  );

  for (final state in [
    SourceState.disconnected,
    SourceState.reconnecting,
    SourceState.error,
  ]) {
    test(
      '$state invalidates telemetry; reconnect never reuses old frame or counter baseline',
      () {
        receive(stats(buserr: 10, rec: 140));
        diagnostics.frameReceived();
        diagnostics.updateSourceState(state);
        expect(diagnostics.snapshot.traffic, CanTrafficState.unknown);
        expect(diagnostics.snapshot.stats, isNull);
        expect(diagnostics.snapshot.counter('buserr'), isNull);
        diagnostics.updateSourceState(SourceState.connected);
        diagnostics.updateSourceState(SourceState.streaming);
        expect(diagnostics.snapshot.stats, isNull);
        receive(stats(rx: 100, buserr: 50));
        expect(diagnostics.snapshot.busErrorDelta, isNull);
        expect(diagnostics.snapshot.traffic, CanTrafficState.unknown);
        diagnostics.frameReceived();
        expect(diagnostics.snapshot.traffic, CanTrafficState.active);
      },
    );
  }

  test('disconnect interrupts silence and never claims CAN recovered', () {
    receive(stats());
    advance(3100);
    receive(stats());
    diagnostics.updateSourceState(SourceState.disconnected);
    expect(phases('started'), 1);
    expect(phases('interrupted'), 1);
    expect(phases('recovered'), 0);
    diagnostics.updateSourceState(SourceState.streaming);
    expect(phases('recovered'), 0);
  });

  test(
    'new counters generate hardware-telemetry events without inferred subtypes',
    () {
      receive(stats());
      advance(1000);
      final events = diagnostics.accept(stats(buserr: 4, tec: 5, rec: 10));
      expect(events, hasLength(1));
      expect(events.single.data['busErrorDelta'], 4);
      expect(events.single.data['tec'], 5);
      expect(events.single.data['rec'], 10);
      expect(events.single.evidence, DiagnosticEvidence.telemetry);
      expect(events.single.data.containsKey('frameId'), isFalse);
      expect(events.single.data.containsKey('errorTypes'), isFalse);
      expect(
        diagnostics.snapshot.typedErrors.values.every((v) => v == null),
        isTrue,
      );
      advance(1000);
      expect(diagnostics.accept(stats(buserr: 4, tec: 5, rec: 10)), isEmpty);
    },
  );

  test(
    'TEC and REC changes alone are retained, with no invented direction',
    () {
      receive(stats());
      advance(1000);
      final event = diagnostics.accept(stats(rec: 4)).single;
      expect(event.data['rec'], 4);
      expect(event.data['direction'], isNull);
    },
  );

  test('controller fault entry and clearing are recorded once', () {
    receive(stats());
    advance(1000);
    receive(stats(rec: 140));
    advance(1000);
    expect(diagnostics.accept(stats(rec: 140)), isEmpty);
    advance(1000);
    final clear = diagnostics.accept(stats()).single;
    expect(clear.data['phase'], 'recovered');
    expect(clear.diagnosticSeverity, DiagnosticSeverity.info);
  });

  test('first fault sample is marked as baseline, not an invented delta', () {
    final event = diagnostics.accept(stats(state: 'BUS_OFF', tec: 256)).single;
    expect(event.data['eventCode'], 'controller_baseline');
    expect(event.data.containsKey('busErrorDelta'), isFalse);
    expect(event.diagnosticCause, DiagnosticCause.busOff);
  });

  test(
    'new RX losses affect live health only during the measured interval',
    () {
      receive(stats(missed: 4));
      advance(1000);
      receive(stats(missed: 6));
      final health = CanHealthAnalyzer();
      int score() => health
          .analyze(
            latestStats: diagnostics.snapshot.stats,
            errorRate: 0,
            errorDetectedEvents: 0,
            reconnectCount: 0,
            busIsSilent: false,
            rxOverflowActive: diagnostics.snapshot.rxOverflowActive,
          )
          .score;
      expect(score(), 85);
      advance(1000);
      receive(stats(missed: 6));
      expect(score(), 100);
      expect(diagnostics.snapshot.counter('missed'), 6);
    },
  );

  test(
    'missing optional counters and unknown node are not rendered as measured zero',
    () {
      receive(stats(optional: false, node: null));
      expect(diagnostics.snapshot.counter('ovr'), isNull);
      expect(diagnostics.snapshot.counter('missed'), 0);
      expect(diagnostics.snapshot.node, 'Unknown');
      final stored = CanStats.fromStoredJson(stats(optional: false).toJson());
      expect(stored.hasWireCounter('ovr'), isFalse);
      advance(1000);
      final event = diagnostics
          .accept(stats(optional: false, node: null, rec: 1))
          .single;
      expect(event.data['rxOverrunDelta'], isNull);
      expect(event.data['txFailedDelta'], isNull);
    },
  );

  test(
    'receiver reboot starts a new epoch without cross-reset subtraction',
    () {
      receive(stats(rx: 100, buserr: 20));
      diagnostics.frameReceived();
      advance(2000);
      final events = diagnostics.accept(stats(rx: 1, buserr: 0, uptime: 1));
      expect(events.single.type, CanSessionEventType.note);
      diagnostics.poll();
      expect(diagnostics.snapshot.busErrorDelta, isNull);
      expect(diagnostics.snapshot.traffic, CanTrafficState.unknown);
    },
  );

  test('duplicate uptime packets do not make old controller stats fresh', () {
    final value = stats();
    receive(value);
    advance(5000);
    diagnostics.accept(value);
    diagnostics.poll();
    expect(diagnostics.snapshot.transport, CanTransportState.active);
    expect(diagnostics.snapshot.stats, isNull);
    expect(diagnostics.snapshot.traffic, CanTrafficState.unknown);
  });

  test('fresh frames do not make stale controller counters current', () {
    receive(stats(rec: 140));
    advance(5000);
    diagnostics.frameReceived();
    expect(diagnostics.snapshot.traffic, CanTrafficState.active);
    expect(diagnostics.snapshot.transport, CanTransportState.active);
    expect(diagnostics.snapshot.stats, isNull);
    expect(diagnostics.snapshot.counter('rxe'), isNull);
  });

  test('event evidence and timestamps survive session JSON serialization', () {
    receive(stats());
    advance(3100);
    receive(stats());
    final event = diagnostics.recentEvents.single;
    final restored = CanSessionEvent.fromJson(event.toJson());
    expect(restored.data, event.data);
    expect(restored.timestamp, event.timestamp);
    expect(restored.evidence, DiagnosticEvidence.inferred);
  });
}

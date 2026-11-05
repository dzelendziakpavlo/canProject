import 'package:flutter_test/flutter_test.dart';

import 'package:can_debug/domain/detection/can_error_checker.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/models/can_session.dart';
import 'package:can_debug/domain/models/can_session_event.dart';
import 'package:can_debug/domain/models/can_stats.dart';
import 'package:can_debug/domain/services/session_summary_builder.dart';

void main() {
  final startTime = DateTime(2026, 8, 22, 12, 0, 0);

  CanStats createStats({
    String state = 'RUNNING',
    int txErrorCounter = 0,
  }) {
    return CanStats(
      rxTotal: 10,
      txErrorCounter: txErrorCounter,
      rxErrorCounter: 0,
      busState: state,
      rxMissed: 0,
      busErrorCount: 0,
      arbLostCount: 0,
      txFailedCount: 0,
      rxOverrunCount: 0,
      isNoAckMode: false,
      isSpeedMismatchDemo: false,
      timestamp: startTime.add(const Duration(seconds: 1)),
    );
  }

  CanSession createSession() {
    final frames = [
      CanFrame.create(
        id: 0x100,
        dlc: 2,
        data: [1, 2],
        timestamp: startTime,
      ),
      CanFrame.create(
        id: 0x101,
        dlc: 2,
        data: [3, 4],
        timestamp: startTime.add(const Duration(seconds: 2)),
        isCorrupted: true,
      ),
    ];
    final events = [
      CanSessionEvent(
        id: 'event-start',
        type: CanSessionEventType.sourceStarted,
        timestamp: startTime,
        message: 'Source started',
        sourceName: 'Simulator',
      ),
      CanSessionEvent(
        id: 'event-state',
        type: CanSessionEventType.sourceStateChanged,
        timestamp: startTime.add(const Duration(seconds: 1)),
        message: 'Source disconnected',
        sourceName: 'Simulator',
        data: {'newState': 'disconnected'},
      ),
      CanSessionEvent(
        id: 'event-batch',
        type: CanSessionEventType.frameBatch,
        timestamp: startTime.add(const Duration(seconds: 2)),
        message: 'Frame batch received',
        sourceName: 'Simulator',
        data: {'count': 2},
      ),
      CanSessionEvent(
        id: 'event-diagnostic',
        type: CanSessionEventType.diagnostic,
        timestamp: startTime.add(const Duration(seconds: 3)),
        message: 'Silent CAN bus',
        sourceName: 'Simulator',
        diagnosticSeverity: DiagnosticSeverity.error,
        diagnosticCause: DiagnosticCause.silentBus,
        explanation: 'No frames received.',
        recommendation: 'Check CAN wiring.',
      ),
      CanSessionEvent(
        id: 'event-reconnect',
        type: CanSessionEventType.sourceStateChanged,
        timestamp: startTime.add(const Duration(seconds: 4)),
        message: 'Reconnecting',
        sourceName: 'Simulator',
        data: {'newState': 'reconnecting'},
      ),
    ];

    return CanSession.create('Session test').updateWith(
      sourceName: 'Simulator',
      frames: frames,
      statsSnapshots: [createStats()],
      events: events,
      errorStats: {for (final type in CanErrorType.values) type: 0},
      totalFrames: frames.length,
      errorFrames: 1,
      errorRate: 50.0,
    );
  }

  test('session JSON round-trips schema, frames, stats, and events', () {
    final session = createSession();
    final restored = CanSession.fromJson(session.toJson());

    expect(restored.schemaVersion, CanSession.currentSchemaVersion);
    expect(restored.id, session.id);
    expect(restored.sourceName, 'Simulator');
    expect(restored.frames.length, 2);
    expect(restored.frames[1].isCorrupted, isTrue);
    expect(restored.statsSnapshots.single.busState, 'RUNNING');
    expect(restored.events.first.type, CanSessionEventType.sourceStarted);
    expect(restored.events[1].data['newState'], 'disconnected');
    expect(restored.events[3].type, CanSessionEventType.diagnostic);
    expect(restored.events[3].diagnosticSeverity, DiagnosticSeverity.error);
    expect(restored.events[3].diagnosticCause, DiagnosticCause.silentBus);
    expect(restored.events[3].recommendation, 'Check CAN wiring.');
  });

  test('event JSON preserves unknown event types as notes', () {
    final event = CanSessionEvent.fromJson({
      'id': 'legacy-event',
      'type': 'futureEvent',
      'timestamp': startTime.toIso8601String(),
      'message': 'Legacy event',
      'data': {'value': 1},
    });

    expect(event.type, CanSessionEventType.note);
    expect(event.message, 'Legacy event');
    expect(event.data['value'], 1);
  });

  test('errors preserve hardware, inferred, and simulated origins', () {
    final simulated = CanErrorChecker().analyzeFrame(
      CanFrame.create(
        id: 0x100,
        dlc: 1,
        data: [1],
        timestamp: startTime,
        isCorrupted: true,
      ),
    );
    final hardware = CanErrorInfo(
      type: CanErrorType.overloadError,
      description: 'TWAI RX overrun',
      severity: 3,
      origin: CanErrorOrigin.hardware,
    );
    final inferred = CanErrorInfo(
      type: CanErrorType.ackError,
      description: 'TEC delta suggests ACK error',
      severity: 4,
      origin: CanErrorOrigin.inferred,
    );

    expect(simulated.first.origin, CanErrorOrigin.simulated);
    expect(hardware.origin, CanErrorOrigin.hardware);
    expect(inferred.origin, CanErrorOrigin.inferred);
  });

  test('frames round-trip typed error metadata through JSON', () {
    final error = CanErrorInfo(
      type: CanErrorType.overloadError,
      description: 'TWAI RX overrun',
      severity: 3,
      origin: CanErrorOrigin.hardware,
      timestamp: startTime,
      details: {'delta': 2},
    );
    final frame = CanFrame.create(
      id: 0x000,
      dlc: 0,
      data: const [],
      timestamp: startTime,
      errors: [error],
    );

    final restored = CanFrame.fromJson(frame.toJson());
    final restoredError = restored.errors.whereType<CanErrorInfo>().single;

    expect(restoredError.type, CanErrorType.overloadError);
    expect(restoredError.origin, CanErrorOrigin.hardware);
    expect(restoredError.details['delta'], 2);
  });

  test('summary aggregates frames, events, source state, and severity', () {
    final summary = SessionSummaryBuilder().build(createSession());

    expect(summary.monitorMode, 'simulator');
    expect(summary.totalFrames, 2);
    expect(summary.errorFrames, 1);
    expect(summary.errorRate, 50.0);
    expect(summary.totalEvents, 5);
    expect(summary.sourceStartedEvents, 1);
    expect(summary.sourceStateEvents, 2);
    expect(summary.frameBatchEvents, 1);
    expect(summary.diagnosticEvents, 1);
    expect(summary.reconnectCount, 1);
    expect(summary.topCanIds.map((entry) => entry.id), containsAll([0x100, 0x101]));
    expect(summary.topCanIds.first.count, 1);
    expect(summary.sourceStateCounts['disconnected'], 1);
    expect(summary.statsSnapshotsCount, 1);
    expect(summary.latestBusState, 'RUNNING');
    expect(summary.lastFrameTimestamp, startTime.add(const Duration(seconds: 2)));
    expect(summary.severity, SessionSeverity.critical);
    expect(summary.healthScore, lessThan(100));
  });

  test('summary marks bus-off and error-passive hardware stats as critical', () {
    final session = createSession().updateWith(
      sourceName: 'BLE - ESP32 CAN Stand',
      statsSnapshots: [createStats(state: 'BUS_OFF', txErrorCounter: 128)],
    );

    final summary = SessionSummaryBuilder().build(session);

    expect(summary.monitorMode, 'hardware');
    expect(summary.latestIsBusOff, isTrue);
    expect(summary.latestIsErrorPassive, isTrue);
    expect(summary.severity, SessionSeverity.critical);
    expect(summary.healthScore, lessThanOrEqualTo(50));
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:can_debug/domain/detection/can_anomaly_analyzer.dart';
import 'package:can_debug/domain/detection/can_error_checker.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/models/can_session_event.dart';
import 'package:can_debug/domain/models/can_stats.dart';
import 'package:can_debug/domain/models/can_session.dart';

void main() {
  final start = DateTime(2026, 9, 29, 12, 0, 0);

  CanStats stats({
    int rx = 10,
    int missed = 0,
    int overrun = 0,
    int arb = 0,
    int tec = 0,
    int rec = 0,
    String state = 'RUNNING',
  }) {
    return CanStats(
      rxTotal: rx,
      txErrorCounter: tec,
      rxErrorCounter: rec,
      busState: state,
      rxMissed: missed,
      busErrorCount: 0,
      arbLostCount: arb,
      txFailedCount: 0,
      rxOverrunCount: overrun,
      isNoAckMode: false,
      isSpeedMismatchDemo: false,
      timestamp: start,
    );
  }

  CanFrame frame(int id, DateTime timestamp, {List<CanErrorInfo> errors = const []}) {
    return CanFrame.create(id: id, dlc: 1, data: [1], timestamp: timestamp, errors: errors);
  }

  CanSessionEvent reconnectEvent(int index) {
    return CanSessionEvent(
      id: 'reconnect-$index',
      type: CanSessionEventType.sourceStateChanged,
      timestamp: start.add(Duration(seconds: index)),
      message: 'Reconnecting',
      data: {'newState': 'reconnecting'},
    );
  }

  test('detects hardware packet loss and arbitration loss', () {
    final anomalies = const CanAnomalyAnalyzer().analyze(
      frames: [],
      statsSnapshots: [
        stats(),
        stats(missed: 2, overrun: 1, arb: 3),
      ],
      events: [],
    );

    expect(anomalies.map((item) => item.type), containsAll([
      CanAnomalyType.packetLoss,
      CanAnomalyType.arbitrationLost,
    ]));
    expect(anomalies.first.confidence, 1.0);
  });

  test('detects repeated errors, burst traffic, and silent periods', () {
    final error = CanErrorInfo(
      type: CanErrorType.ackError,
      description: 'ACK error',
      severity: 4,
      origin: CanErrorOrigin.hardware,
    );
    final frames = [
      frame(1, start, errors: [error]),
      frame(1, start.add(const Duration(milliseconds: 1)), errors: [error]),
      frame(1, start.add(const Duration(milliseconds: 2)), errors: [error]),
      frame(1, start.add(const Duration(seconds: 5))),
    ];

    final anomalies = const CanAnomalyAnalyzer(burstFrameRate: 0.5).analyze(
      frames: frames,
      statsSnapshots: [],
      events: [],
    );

    expect(anomalies.map((item) => item.type), containsAll([
      CanAnomalyType.repeatedError,
      CanAnomalyType.burstTraffic,
      CanAnomalyType.silentPeriod,
    ]));
  });

  test('detects unstable recovery, reconnect storm, and counter spike', () {
    final anomalies = const CanAnomalyAnalyzer().analyze(
      frames: [],
      statsSnapshots: [
        stats(tec: 0, rec: 0, state: 'RUNNING'),
        stats(tec: 30, rec: 20, state: 'RECOVERING'),
        stats(tec: 30, rec: 20, state: 'RUNNING'),
        stats(tec: 40, rec: 40, state: 'RECOVERING'),
        stats(tec: 70, rec: 70, state: 'RUNNING'),
      ],
      events: [reconnectEvent(1), reconnectEvent(2), reconnectEvent(3)],
    );

    expect(anomalies.map((item) => item.type), containsAll([
      CanAnomalyType.unstableRecovery,
      CanAnomalyType.reconnectStorm,
      CanAnomalyType.counterSpike,
    ]));
  });
}

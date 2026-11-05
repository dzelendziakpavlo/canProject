import 'package:flutter_test/flutter_test.dart';

import 'package:can_debug/domain/detection/can_health_analyzer.dart';
import 'package:can_debug/domain/models/can_session.dart';
import 'package:can_debug/domain/models/can_stats.dart';

void main() {
  final analyzer = CanHealthAnalyzer();
  final timestamp = DateTime(2026, 8, 22);

  CanStats stats({
    String state = 'RUNNING',
    int tec = 0,
    int rec = 0,
    int missed = 0,
    int overrun = 0,
  }) {
    return CanStats(
      rxTotal: 100,
      txErrorCounter: tec,
      rxErrorCounter: rec,
      busState: state,
      rxMissed: missed,
      busErrorCount: 0,
      arbLostCount: 0,
      txFailedCount: 0,
      rxOverrunCount: overrun,
      isNoAckMode: false,
      isSpeedMismatchDemo: false,
      timestamp: timestamp,
    );
  }

  test('healthy running bus has full score and no findings', () {
    final report = analyzer.analyze(
      latestStats: stats(),
      errorRate: 0,
      errorDetectedEvents: 0,
      reconnectCount: 0,
      busIsSilent: false,
    );

    expect(report.score, 100);
    expect(report.severity, SessionSeverity.normal);
    expect(report.findings, isEmpty);
  });

  test('bus-off is critical and gives a physical-layer recommendation', () {
    final report = analyzer.analyze(
      latestStats: stats(state: 'BUS_OFF', tec: 255),
      errorRate: 0,
      errorDetectedEvents: 0,
      reconnectCount: 0,
      busIsSilent: false,
    );

    expect(report.severity, SessionSeverity.critical);
    expect(report.score, lessThanOrEqualTo(60));
    expect(report.findings.map((finding) => finding.title), contains('Bus-off'));
    expect(report.findings.first.recommendation, contains('bitrate'));
  });

  test('silent bus and repeated reconnects are reported together', () {
    final report = analyzer.analyze(
      latestStats: stats(),
      errorRate: 0,
      errorDetectedEvents: 0,
      reconnectCount: 3,
      busIsSilent: true,
    );

    expect(report.severity, SessionSeverity.high);
    expect(report.score, 60);
    expect(report.findings.map((finding) => finding.title), contains('Silent CAN bus'));
    expect(report.findings.map((finding) => finding.title), contains('Reconnect storm'));
  });

  test('error warning and RX overflow lower health', () {
    final report = analyzer.analyze(
      latestStats: stats(tec: 100, missed: 1, overrun: 1),
      errorRate: 12,
      errorDetectedEvents: 1,
      reconnectCount: 0,
      busIsSilent: false,
    );

    expect(report.severity, SessionSeverity.high);
    expect(report.score, lessThan(100));
    expect(report.findings.map((finding) => finding.title), contains('Error warning'));
    expect(report.findings.map((finding) => finding.title), contains('RX overflow'));
    expect(report.findings.map((finding) => finding.title), contains('High frame error rate'));
  });
}

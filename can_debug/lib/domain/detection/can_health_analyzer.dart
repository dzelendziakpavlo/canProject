import '../models/can_stats.dart';
import '../models/can_session.dart';

class CanHealthFinding {
  const CanHealthFinding({
    required this.severity,
    required this.title,
    required this.explanation,
    required this.recommendation,
  });

  final SessionSeverity severity;
  final String title;
  final String explanation;
  final String recommendation;
}

class CanHealthReport {
  const CanHealthReport({
    required this.score,
    required this.severity,
    required this.findings,
  });

  final int score;
  final SessionSeverity severity;
  final List<CanHealthFinding> findings;

  bool get isHealthy => severity == SessionSeverity.normal;
}

/// Applies the same health rules to live hardware telemetry and saved sessions.
class CanHealthAnalyzer {
  CanHealthReport analyze({
    required CanStats? latestStats,
    required double errorRate,
    required int errorDetectedEvents,
    required int reconnectCount,
    required bool busIsSilent,
    String transport = 'ble',
  }) {
    var score = 100;
    final findings = <CanHealthFinding>[];

    if (busIsSilent) {
      score -= 25;
      findings.add(const CanHealthFinding(
        severity: SessionSeverity.high,
        title: 'Silent CAN bus',
        explanation: 'No CAN frames have arrived within the expected interval.',
        recommendation: 'Check SENDER power, CANH/CANL wiring, termination, and bitrate.',
      ));
    }

    if (latestStats != null) {
      if (latestStats.isBusOff) {
        score -= 40;
        findings.add(const CanHealthFinding(
          severity: SessionSeverity.critical,
          title: 'Bus-off',
          explanation: 'The CAN controller reached the transmit error limit.',
          recommendation: 'Check wiring, bitrate, termination, and allow controller recovery.',
        ));
      } else if (latestStats.isRecovering) {
        score -= 25;
        findings.add(const CanHealthFinding(
          severity: SessionSeverity.high,
          title: 'Bus recovery in progress',
          explanation: 'The controller is recovering after a bus-off condition.',
          recommendation: 'Wait for recovery and investigate the errors that caused bus-off.',
        ));
      }

      if (latestStats.isErrorPassive) {
        score -= 20;
        findings.add(CanHealthFinding(
          severity: SessionSeverity.high,
          title: 'Error passive',
          explanation: 'TEC ${latestStats.txErrorCounter} or REC ${latestStats.rxErrorCounter} is above 127.',
          recommendation: 'Inspect physical wiring and bitrate before the node reaches bus-off.',
        ));
      } else if (latestStats.isErrorWarning) {
        score -= 10;
        findings.add(CanHealthFinding(
          severity: SessionSeverity.medium,
          title: 'Error warning',
          explanation: 'TEC ${latestStats.txErrorCounter} or REC ${latestStats.rxErrorCounter} is above 96.',
          recommendation: 'Check the bus before the error counters continue to rise.',
        ));
      }

      if (latestStats.rxMissed > 0 || latestStats.rxOverrunCount > 0) {
        score -= 15;
        findings.add(const CanHealthFinding(
          severity: SessionSeverity.high,
          title: 'RX overflow',
          explanation: 'The receiver dropped frames because its queue or hardware buffer filled.',
          recommendation: 'Reduce bus load or improve frame processing capacity.',
        ));
      }
    }

    if (errorRate > 10) {
      score -= 20;
      findings.add(CanHealthFinding(
        severity: errorRate > 20 ? SessionSeverity.critical : SessionSeverity.medium,
        title: 'High frame error rate',
        explanation: '${errorRate.toStringAsFixed(1)}% of analyzed frames contain errors.',
        recommendation: 'Check bitrate, CANH/CANL integrity, termination, and transceiver power.',
      ));
    }

    if (errorDetectedEvents > 0 && errorRate <= 10) {
      score -= 5;
      findings.add(const CanHealthFinding(
        severity: SessionSeverity.low,
        title: 'CAN errors detected',
        explanation: 'The monitor has recorded protocol or hardware error events.',
        recommendation: 'Review the error types and their timestamps in the session details.',
      ));
    }

    if (reconnectCount >= 3) {
      score -= 15;
      findings.add(CanHealthFinding(
        severity: reconnectCount >= 5 ? SessionSeverity.critical : SessionSeverity.high,
        title: 'Reconnect storm',
        explanation: 'The ${transport == 'usbSerial' ? 'USB Serial' : 'BLE'} source has reconnected $reconnectCount times during this run.',
        recommendation: transport == 'usbSerial'
            ? 'Check receiver power, USB cable, COM port, and competing serial programs.'
            : 'Check receiver power, BLE signal strength, and Android permissions.',
      ));
    }

    final severity = findings.any((finding) => finding.severity == SessionSeverity.critical)
        ? SessionSeverity.critical
        : findings.any((finding) => finding.severity == SessionSeverity.high)
            ? SessionSeverity.high
            : findings.any((finding) => finding.severity == SessionSeverity.medium)
                ? SessionSeverity.medium
                : findings.any((finding) => finding.severity == SessionSeverity.low)
                    ? SessionSeverity.low
                    : SessionSeverity.normal;

    return CanHealthReport(
      score: score.clamp(0, 100).toInt(),
      severity: severity,
      findings: findings,
    );
  }
}

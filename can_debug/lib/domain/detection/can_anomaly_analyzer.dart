import '../models/can_frame.dart';
import '../models/can_session.dart';
import '../models/can_session_event.dart';
import '../models/can_stats.dart';
import 'can_error_checker.dart';

enum CanAnomalyType {
  packetLoss,
  arbitrationLost,
  repeatedError,
  burstTraffic,
  silentPeriod,
  unstableRecovery,
  reconnectStorm,
  counterSpike,
}

class CanAnomaly {
  const CanAnomaly({
    required this.type,
    required this.severity,
    required this.confidence,
    required this.title,
    required this.explanation,
    required this.recommendation,
  });

  final CanAnomalyType type;
  final SessionSeverity severity;
  final double confidence;
  final String title;
  final String explanation;
  final String recommendation;
}

/// Detects patterns that are more informative than a single CAN error counter.
/// It uses persisted frames, TWAI snapshots, and normalized source events only.
class CanAnomalyAnalyzer {
  const CanAnomalyAnalyzer({
    this.silentGap = const Duration(seconds: 3),
    this.burstFrameRate = 500,
    this.repeatedErrorThreshold = 3,
  });

  final Duration silentGap;
  final double burstFrameRate;
  final int repeatedErrorThreshold;

  List<CanAnomaly> analyze({
    required List<CanFrame> frames,
    required List<CanStats> statsSnapshots,
    required List<CanSessionEvent> events,
    String transport = 'ble',
  }) {
    final anomalies = <CanAnomaly>[];
    final orderedFrames = List<CanFrame>.from(frames)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final orderedStats = List<CanStats>.from(statsSnapshots)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    _addPacketLoss(anomalies, orderedStats);
    _addArbitrationLoss(anomalies, orderedStats);
    _addRepeatedErrors(anomalies, orderedFrames);
    _addBurstTraffic(anomalies, orderedFrames);
    _addSilentPeriods(anomalies, orderedFrames);
    _addUnstableRecovery(anomalies, orderedStats);
    _addReconnectStorm(anomalies, events, transport);
    _addCounterSpike(anomalies, orderedStats);

    return anomalies;
  }

  void _addPacketLoss(List<CanAnomaly> anomalies, List<CanStats> snapshots) {
    final missedDelta = _counterDelta(snapshots, (stats) => stats.rxMissed);
    final overrunDelta = _counterDelta(snapshots, (stats) => stats.rxOverrunCount);
    if (missedDelta == 0 && overrunDelta == 0) return;

    anomalies.add(CanAnomaly(
      type: CanAnomalyType.packetLoss,
      severity: SessionSeverity.high,
      confidence: 1.0,
      title: 'Packet loss detected',
      explanation: 'TWAI reports $missedDelta software queue drops and $overrunDelta hardware RX overruns.',
      recommendation: 'Reduce bus load or improve receiver processing capacity.',
    ));
  }

  void _addArbitrationLoss(List<CanAnomaly> anomalies, List<CanStats> snapshots) {
    final delta = _counterDelta(snapshots, (stats) => stats.arbLostCount);
    if (delta == 0) return;

    anomalies.add(CanAnomaly(
      type: CanAnomalyType.arbitrationLost,
      severity: SessionSeverity.low,
      confidence: 1.0,
      title: 'Arbitration losses detected',
      explanation: 'The CAN controller lost arbitration $delta time(s).',
      recommendation: 'Review bus priority, identifier allocation, and competing transmitters.',
    ));
  }

  void _addRepeatedErrors(List<CanAnomaly> anomalies, List<CanFrame> frames) {
    final counts = <CanErrorType, int>{};
    for (final frame in frames) {
      for (final error in frame.errors.whereType<CanErrorInfo>()) {
        counts[error.type] = (counts[error.type] ?? 0) + 1;
      }
    }
    final entry = counts.entries
        .where((item) => item.value >= repeatedErrorThreshold)
        .fold<MapEntry<CanErrorType, int>?>(null, (current, item) {
      if (current == null || item.value > current.value) return item;
      return current;
    });
    if (entry == null) return;

    anomalies.add(CanAnomaly(
      type: CanAnomalyType.repeatedError,
      severity: entry.value >= repeatedErrorThreshold * 2 ? SessionSeverity.high : SessionSeverity.medium,
      confidence: 0.95,
      title: 'Repeated ${entry.key.name}',
      explanation: '${entry.value} occurrences of the same error type were recorded.',
      recommendation: 'Inspect the error timeline and check the related physical or protocol condition.',
    ));
  }

  void _addBurstTraffic(List<CanAnomaly> anomalies, List<CanFrame> frames) {
    if (frames.length < 2) return;
    final durationMs = frames.last.timestamp.difference(frames.first.timestamp).inMilliseconds;
    if (durationMs <= 0) return;
    final rate = frames.length * 1000 / durationMs;
    if (rate < burstFrameRate) return;

    anomalies.add(CanAnomaly(
      type: CanAnomalyType.burstTraffic,
      severity: SessionSeverity.medium,
      confidence: 0.9,
      title: 'Burst traffic detected',
      explanation: 'The observed frame rate reached ${rate.toStringAsFixed(1)} frames per second.',
      recommendation: 'Check receiver queue capacity and compare the result with overload telemetry.',
    ));
  }

  void _addSilentPeriods(List<CanAnomaly> anomalies, List<CanFrame> frames) {
    if (frames.length < 2) return;
    for (var index = 1; index < frames.length; index++) {
      final gap = frames[index].timestamp.difference(frames[index - 1].timestamp);
      if (gap >= silentGap) {
        anomalies.add(CanAnomaly(
          type: CanAnomalyType.silentPeriod,
          severity: SessionSeverity.high,
          confidence: 0.9,
          title: 'Silent traffic period',
          explanation: 'No frame arrived for ${gap.inMilliseconds} ms.',
          recommendation: 'Check sender activity, CAN wiring, termination, and bitrate.',
        ));
        return;
      }
    }
  }

  void _addUnstableRecovery(List<CanAnomaly> anomalies, List<CanStats> snapshots) {
    var recoveryTransitions = 0;
    for (var index = 1; index < snapshots.length; index++) {
      if (snapshots[index - 1].isRecovering && snapshots[index].isRunning) {
        recoveryTransitions++;
      }
    }
    if (recoveryTransitions < 2) return;

    anomalies.add(CanAnomaly(
      type: CanAnomalyType.unstableRecovery,
      severity: SessionSeverity.critical,
      confidence: 1.0,
      title: 'Unstable bus recovery',
      explanation: 'The controller completed recovery $recoveryTransitions times in one session.',
      recommendation: 'Investigate the recurring physical or bitrate condition causing Bus-Off.',
    ));
  }

  void _addReconnectStorm(List<CanAnomaly> anomalies, List<CanSessionEvent> events, String transport) {
    final reconnects = events.where((event) =>
        event.type == CanSessionEventType.sourceStateChanged &&
        (event.data['newState']?.toString() == 'reconnecting' ||
            event.data['state']?.toString() == 'reconnecting')).length;
    if (reconnects < 3) return;

    anomalies.add(CanAnomaly(
      type: CanAnomalyType.reconnectStorm,
      severity: reconnects >= 5 ? SessionSeverity.critical : SessionSeverity.high,
      confidence: 1.0,
      title: '${transport == 'usbSerial' ? 'USB Serial' : 'BLE'} reconnect storm',
      explanation: 'The source entered reconnecting state $reconnects times.',
      recommendation: transport == 'usbSerial'
          ? 'Check receiver power, USB cable, COM port, and competing serial programs.'
          : 'Check receiver power, BLE signal strength, and Android permissions.',
    ));
  }

  void _addCounterSpike(List<CanAnomaly> anomalies, List<CanStats> snapshots) {
    if (snapshots.length < 2) return;
    final previous = snapshots[snapshots.length - 2];
    final latest = snapshots.last;
    final tecDelta = latest.txErrorCounter - previous.txErrorCounter;
    final recDelta = latest.rxErrorCounter - previous.rxErrorCounter;
    if (tecDelta < 16 && recDelta < 16) return;

    anomalies.add(CanAnomaly(
      type: CanAnomalyType.counterSpike,
      severity: SessionSeverity.high,
      confidence: 0.95,
      title: 'Error counter spike',
      explanation: 'TEC increased by $tecDelta and REC increased by $recDelta in one telemetry interval.',
      recommendation: 'Check bitrate, CANH/CANL integrity, termination, and transceiver power.',
    ));
  }

  int _counterDelta(List<CanStats> snapshots, int Function(CanStats) selector) {
    if (snapshots.length < 2) return 0;
    final first = selector(snapshots.first);
    final last = selector(snapshots.last);
    return (last - first).clamp(0, 1 << 31).toInt();
  }
}

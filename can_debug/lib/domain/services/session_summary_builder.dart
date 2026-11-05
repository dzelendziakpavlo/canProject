import '../detection/can_error_checker.dart';
import '../models/can_frame.dart';
import '../models/can_session.dart';
import '../models/can_session_event.dart';
import '../models/can_stats.dart';
import '../models/can_session_summary.dart';

/// Builds a derived session summary from the persisted session payload.
class SessionSummaryBuilder {
  final CanErrorChecker _checker;

  SessionSummaryBuilder({CanErrorChecker? checker}) : _checker = checker ?? CanErrorChecker();

  CanSessionSummary build(CanSession session) {
    final frames = List<CanFrame>.from(session.frames);
    final events = List<CanSessionEvent>.from(session.events);
    final errorStats = _checker.getErrorStatistics(frames);
    final errorFrames = frames.where((frame) => _checker.hasError(frame)).length;
    final errorRate = frames.isEmpty ? 0.0 : (errorFrames / frames.length) * 100.0;

    final sourceStateCounts = <String, int>{};
    final canIdCounts = <int, int>{};
    int sourceStartedEvents = 0;
    int sourceStoppedEvents = 0;
    int sourceStateEvents = 0;
    int statsSnapshotEvents = 0;
    int frameBatchEvents = 0;
    int errorDetectedEvents = 0;
    int diagnosticEvents = 0;
    int noteEvents = 0;

    DateTime? lastFrameTimestamp;
    DateTime? lastStatsTimestamp;
    DateTime? lastEventTimestamp;

    for (final event in events) {
      lastEventTimestamp = _laterOf(lastEventTimestamp, event.timestamp);

      switch (event.type) {
        case CanSessionEventType.sourceStarted:
          sourceStartedEvents++;
          break;
        case CanSessionEventType.sourceStopped:
          sourceStoppedEvents++;
          break;
        case CanSessionEventType.sourceStateChanged:
          sourceStateEvents++;
          final state = event.data['newState']?.toString() ?? event.data['state']?.toString() ?? 'unknown';
          sourceStateCounts[state] = (sourceStateCounts[state] ?? 0) + 1;
          break;
        case CanSessionEventType.statsSnapshot:
          statsSnapshotEvents++;
          lastStatsTimestamp = _laterOf(lastStatsTimestamp, _extractTimestamp(event));
          break;
        case CanSessionEventType.frameBatch:
          frameBatchEvents++;
          break;
        case CanSessionEventType.errorDetected:
          errorDetectedEvents++;
          break;
        case CanSessionEventType.diagnostic:
          diagnosticEvents++;
          break;
        case CanSessionEventType.note:
          noteEvents++;
          break;
      }
    }

    for (final frame in frames) {
      lastFrameTimestamp = _laterOf(lastFrameTimestamp, frame.timestamp);
      canIdCounts[frame.id] = (canIdCounts[frame.id] ?? 0) + 1;
    }

    final topCanIds = canIdCounts.entries
        .map((entry) => CanIdCount(id: entry.key, count: entry.value))
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    final reconnectCount = sourceStateCounts['reconnecting'] ?? 0;

    final latestStats = session.statsSnapshots.isNotEmpty ? session.statsSnapshots.last : null;
    final latestStatsTimestamp = latestStats?.timestamp;
    final healthScore = _calculateHealthScore(
      errorRate: errorRate,
      errorDetectedEvents: errorDetectedEvents,
      statsSnapshotsCount: session.statsSnapshots.length,
      latestStats: latestStats,
      sourceStateCounts: sourceStateCounts,
    );

    return CanSessionSummary(
      sessionId: session.id,
      sessionName: session.name,
      sourceName: session.sourceName,
      monitorMode: session.sourceName == null ? 'unknown' : (session.sourceName!.toLowerCase().contains('ble') || session.sourceName!.toLowerCase().contains('can') ? 'hardware' : 'simulator'),
      startTime: session.startTime,
      endTime: session.endTime,
      duration: session.duration,
      totalFrames: frames.length,
      errorFrames: errorFrames,
      errorRate: errorRate,
      statsSnapshotsCount: session.statsSnapshots.length,
      totalEvents: events.length,
      sourceStartedEvents: sourceStartedEvents,
      sourceStoppedEvents: sourceStoppedEvents,
      sourceStateEvents: sourceStateEvents,
      statsSnapshotEvents: statsSnapshotEvents,
      frameBatchEvents: frameBatchEvents,
      errorDetectedEvents: errorDetectedEvents,
      diagnosticEvents: diagnosticEvents,
      noteEvents: noteEvents,
      reconnectCount: reconnectCount,
      topCanIds: topCanIds.take(10).toList(),
      lastFrameTimestamp: lastFrameTimestamp,
      lastStatsTimestamp: lastStatsTimestamp,
      lastEventTimestamp: lastEventTimestamp,
      errorStats: errorStats,
      sourceStateCounts: sourceStateCounts,
      latestStats: latestStats,
      latestStatsTimestamp: latestStatsTimestamp,
      latestBusState: latestStats?.busState,
      latestRxTotal: latestStats?.rxTotal,
      latestTxErrorCounter: latestStats?.txErrorCounter,
      latestRxErrorCounter: latestStats?.rxErrorCounter,
      latestRxMissed: latestStats?.rxMissed,
      latestBusErrorCount: latestStats?.busErrorCount,
      latestArbLostCount: latestStats?.arbLostCount,
      latestTxFailedCount: latestStats?.txFailedCount,
      latestRxOverrunCount: latestStats?.rxOverrunCount,
      latestIsNoAckMode: latestStats?.isNoAckMode ?? false,
      latestIsSpeedMismatchDemo: latestStats?.isSpeedMismatchDemo ?? false,
      latestIsBusOff: latestStats?.isBusOff ?? false,
      latestIsRecovering: latestStats?.isRecovering ?? false,
      latestIsErrorPassive: latestStats?.isErrorPassive ?? false,
      latestIsErrorWarning: latestStats?.isErrorWarning ?? false,
      healthScore: healthScore,
      severity: _severityFor(errorRate, latestStats, errorDetectedEvents),
    );
  }

  DateTime? _extractTimestamp(CanSessionEvent event) {
    return event.timestamp;
  }

  DateTime? _laterOf(DateTime? current, DateTime? candidate) {
    if (current == null) return candidate;
    if (candidate == null) return current;
    return candidate.isAfter(current) ? candidate : current;
  }

  int _calculateHealthScore({
    required double errorRate,
    required int errorDetectedEvents,
    required int statsSnapshotsCount,
    required CanStats? latestStats,
    required Map<String, int> sourceStateCounts,
  }) {
    var score = 100;

    score -= (errorRate * 1.2).round();
    score -= (errorDetectedEvents * 2).clamp(0, 20).toInt();
    score -= statsSnapshotsCount == 0 ? 10 : 0;

    if (latestStats != null) {
      if (latestStats.isBusOff) score -= 40;
      if (latestStats.isErrorPassive) score -= 20;
      if (latestStats.isErrorWarning) score -= 10;
      score -= (latestStats.rxMissed ~/ 10).clamp(0, 10).toInt();
      score -= (latestStats.rxOverrunCount ~/ 5).clamp(0, 10).toInt();
    }

    final disconnects = sourceStateCounts['disconnected'] ?? 0;
    final reconnects = sourceStateCounts['reconnecting'] ?? 0;
    score -= (disconnects * 5).clamp(0, 20).toInt();
    score -= (reconnects * 3).clamp(0, 10).toInt();

    return score.clamp(0, 100);
  }

  SessionSeverity _severityFor(double errorRate, CanStats? latestStats, int errorDetectedEvents) {
    if (latestStats?.isBusOff == true || errorRate > 20 || errorDetectedEvents > 50) {
      return SessionSeverity.critical;
    }
    if (latestStats?.isErrorPassive == true || errorRate > 15) {
      return SessionSeverity.high;
    }
    if (latestStats?.isErrorWarning == true || errorRate > 10) {
      return SessionSeverity.medium;
    }
    if (errorRate > 5 || errorDetectedEvents > 0) {
      return SessionSeverity.low;
    }
    return SessionSeverity.normal;
  }
}
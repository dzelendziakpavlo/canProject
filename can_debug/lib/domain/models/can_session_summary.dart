import 'can_stats.dart';
import 'can_session.dart';
import '../detection/can_error_checker.dart';

class CanIdCount {
  const CanIdCount({required this.id, required this.count});

  final int id;
  final int count;

  String get formattedId => '0x${id.toRadixString(16).toUpperCase()}';

  Map<String, dynamic> toJson() => {'id': id, 'count': count};
}

/// Derived, read-only summary for a CAN monitoring session.
///
/// This is computed from the stored session data and is intentionally not
/// persisted as source-of-truth JSON. It can be rebuilt anytime from the
/// session payload.
class CanSessionSummary {
  final String sessionId;
  final String sessionName;
  final String? sourceName;
  final String monitorMode;
  final DateTime startTime;
  final DateTime? endTime;
  final Duration duration;

  final int totalFrames;
  final int errorFrames;
  final double errorRate;
  final int statsSnapshotsCount;
  final int totalEvents;

  final int sourceStartedEvents;
  final int sourceStoppedEvents;
  final int sourceStateEvents;
  final int statsSnapshotEvents;
  final int frameBatchEvents;
  final int errorDetectedEvents;
  final int diagnosticEvents;
  final int noteEvents;
  final int reconnectCount;
  final List<CanIdCount> topCanIds;

  final DateTime? lastFrameTimestamp;
  final DateTime? lastStatsTimestamp;
  final DateTime? lastEventTimestamp;

  final Map<CanErrorType, int> errorStats;
  final Map<String, int> sourceStateCounts;
  final CanStats? latestStats;
  final DateTime? latestStatsTimestamp;
  final String? latestBusState;
  final int? latestRxTotal;
  final int? latestTxErrorCounter;
  final int? latestRxErrorCounter;
  final int? latestRxMissed;
  final int? latestBusErrorCount;
  final int? latestArbLostCount;
  final int? latestTxFailedCount;
  final int? latestRxOverrunCount;
  final bool latestIsNoAckMode;
  final bool latestIsSpeedMismatchDemo;
  final bool latestIsBusOff;
  final bool latestIsRecovering;
  final bool latestIsErrorPassive;
  final bool latestIsErrorWarning;
  final int healthScore;
  final SessionSeverity severity;

  const CanSessionSummary({
    required this.sessionId,
    required this.sessionName,
    required this.sourceName,
    required this.monitorMode,
    required this.startTime,
    required this.endTime,
    required this.duration,
    required this.totalFrames,
    required this.errorFrames,
    required this.errorRate,
    required this.statsSnapshotsCount,
    required this.totalEvents,
    required this.sourceStartedEvents,
    required this.sourceStoppedEvents,
    required this.sourceStateEvents,
    required this.statsSnapshotEvents,
    required this.frameBatchEvents,
    required this.errorDetectedEvents,
    required this.diagnosticEvents,
    required this.noteEvents,
    required this.reconnectCount,
    required this.topCanIds,
    required this.lastFrameTimestamp,
    required this.lastStatsTimestamp,
    required this.lastEventTimestamp,
    required this.errorStats,
    required this.sourceStateCounts,
    required this.latestStats,
    required this.latestStatsTimestamp,
    required this.latestBusState,
    required this.latestRxTotal,
    required this.latestTxErrorCounter,
    required this.latestRxErrorCounter,
    required this.latestRxMissed,
    required this.latestBusErrorCount,
    required this.latestArbLostCount,
    required this.latestTxFailedCount,
    required this.latestRxOverrunCount,
    required this.latestIsNoAckMode,
    required this.latestIsSpeedMismatchDemo,
    required this.latestIsBusOff,
    required this.latestIsRecovering,
    required this.latestIsErrorPassive,
    required this.latestIsErrorWarning,
    required this.healthScore,
    required this.severity,
  });

  bool get hasHardwareStats => statsSnapshotsCount > 0;
  bool get hasEvents => totalEvents > 0;
  bool get hasReplayableData => totalFrames > 0 || statsSnapshotsCount > 0 || totalEvents > 0;

  String get timeWindowLabel {
    final end = endTime?.toIso8601String() ?? 'ongoing';
    return '${startTime.toIso8601String()} → $end';
  }

  List<MapEntry<CanErrorType, int>> get topErrorTypes {
    final entries = errorStats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  List<MapEntry<String, int>> get topSourceStates {
    final entries = sourceStateCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'sessionName': sessionName,
      'sourceName': sourceName,
      'monitorMode': monitorMode,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime?.toIso8601String(),
      'durationMs': duration.inMilliseconds,
      'totalFrames': totalFrames,
      'errorFrames': errorFrames,
      'errorRate': errorRate,
      'statsSnapshotsCount': statsSnapshotsCount,
      'totalEvents': totalEvents,
      'sourceStartedEvents': sourceStartedEvents,
      'sourceStoppedEvents': sourceStoppedEvents,
      'sourceStateEvents': sourceStateEvents,
      'statsSnapshotEvents': statsSnapshotEvents,
      'frameBatchEvents': frameBatchEvents,
      'errorDetectedEvents': errorDetectedEvents,
      'diagnosticEvents': diagnosticEvents,
      'noteEvents': noteEvents,
      'reconnectCount': reconnectCount,
      'topCanIds': topCanIds.map((entry) => entry.toJson()).toList(),
      'lastFrameTimestamp': lastFrameTimestamp?.toIso8601String(),
      'lastStatsTimestamp': lastStatsTimestamp?.toIso8601String(),
      'lastEventTimestamp': lastEventTimestamp?.toIso8601String(),
      'errorStats': errorStats.map((key, value) => MapEntry(key.name, value)),
      'sourceStateCounts': sourceStateCounts,
      'latestStatsTimestamp': latestStatsTimestamp?.toIso8601String(),
      'latestBusState': latestBusState,
      'latestRxTotal': latestRxTotal,
      'latestTxErrorCounter': latestTxErrorCounter,
      'latestRxErrorCounter': latestRxErrorCounter,
      'latestRxMissed': latestRxMissed,
      'latestBusErrorCount': latestBusErrorCount,
      'latestArbLostCount': latestArbLostCount,
      'latestTxFailedCount': latestTxFailedCount,
      'latestRxOverrunCount': latestRxOverrunCount,
      'latestIsNoAckMode': latestIsNoAckMode,
      'latestIsSpeedMismatchDemo': latestIsSpeedMismatchDemo,
      'latestIsBusOff': latestIsBusOff,
      'latestIsRecovering': latestIsRecovering,
      'latestIsErrorPassive': latestIsErrorPassive,
      'latestIsErrorWarning': latestIsErrorWarning,
      'healthScore': healthScore,
      'severity': severity.name,
    };
  }
}
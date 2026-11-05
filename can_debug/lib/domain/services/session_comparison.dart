import '../models/can_session.dart';
import '../models/can_session_summary.dart';
import 'session_summary_builder.dart';

class CanIdComparison {
  const CanIdComparison({required this.id, required this.thisCount, required this.otherCount});

  final int id;
  final int thisCount;
  final int otherCount;

  int get delta => otherCount - thisCount;
  String get formattedId => '0x${id.toRadixString(16).toUpperCase()}';
}

class SessionComparison {
  const SessionComparison({
    required this.thisSummary,
    required this.otherSummary,
    required this.idComparisons,
  });

  final CanSessionSummary thisSummary;
  final CanSessionSummary otherSummary;
  final List<CanIdComparison> idComparisons;

  int get frameDelta => otherSummary.totalFrames - thisSummary.totalFrames;
  int get errorFrameDelta => otherSummary.errorFrames - thisSummary.errorFrames;
  double get errorRateDelta => otherSummary.errorRate - thisSummary.errorRate;
  int get healthScoreDelta => otherSummary.healthScore - thisSummary.healthScore;
  int get reconnectDelta => otherSummary.reconnectCount - thisSummary.reconnectCount;
}

class SessionComparisonBuilder {
  SessionComparisonBuilder({SessionSummaryBuilder? summaryBuilder})
      : _summaryBuilder = summaryBuilder ?? SessionSummaryBuilder();

  final SessionSummaryBuilder _summaryBuilder;

  SessionComparison build(CanSession thisSession, CanSession otherSession) {
    final thisSummary = _summaryBuilder.build(thisSession);
    final otherSummary = _summaryBuilder.build(otherSession);
    final thisCounts = <int, int>{};
    final otherCounts = <int, int>{};

    for (final frame in thisSession.frames) {
      thisCounts[frame.id] = (thisCounts[frame.id] ?? 0) + 1;
    }
    for (final frame in otherSession.frames) {
      otherCounts[frame.id] = (otherCounts[frame.id] ?? 0) + 1;
    }

    final ids = {...thisCounts.keys, ...otherCounts.keys}.toList();
    final idComparisons = ids
        .map((id) => CanIdComparison(
              id: id,
              thisCount: thisCounts[id] ?? 0,
              otherCount: otherCounts[id] ?? 0,
            ))
        .where((comparison) => comparison.delta != 0)
        .toList()
      ..sort((a, b) => b.delta.abs().compareTo(a.delta.abs()));

    return SessionComparison(
      thisSummary: thisSummary,
      otherSummary: otherSummary,
      idComparisons: idComparisons,
    );
  }
}

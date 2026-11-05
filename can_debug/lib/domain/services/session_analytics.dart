import 'dart:math';

import '../detection/can_error_checker.dart';
import '../models/can_frame.dart';
import '../models/can_session.dart';

/// Helpers and models to compute extended analytics for a saved session
class SessionAnalyticsData {
  final Map<CanErrorType, int> errorStats;
  final List<TimeBucketPoint> errorsOverTime;
  final List<RatioBucketPoint> bitErrorRatioOverTime;
  final HeatmapData heatmap;
  final List<IdErrorStat> errorsPerId; // sorted desc by percent
  final List<String> recommendations;

  SessionAnalyticsData({
    required this.errorStats,
    required this.errorsOverTime,
    required this.bitErrorRatioOverTime,
    required this.heatmap,
    required this.errorsPerId,
    required this.recommendations,
  });
}

class TimeBucketPoint {
  final DateTime bucketStart;
  final int count;
  TimeBucketPoint(this.bucketStart, this.count);
}

class RatioBucketPoint {
  final DateTime bucketStart;
  final double ratio; // 0..1
  RatioBucketPoint(this.bucketStart, this.ratio);
}

class HeatmapData {
  // hour -> list of 6 buckets (10-min segments)
  final Map<int, List<int>> matrix;
  final int maxCount;
  HeatmapData(this.matrix, this.maxCount);
}

class IdErrorStat {
  final int id;
  final int totalFrames;
  final int errorFrames;
  double get percent => totalFrames == 0 ? 0.0 : (errorFrames / totalFrames) * 100.0;
  IdErrorStat({required this.id, required this.totalFrames, required this.errorFrames});
}

class SessionAnalyticsBuilder {
  final _checker = CanErrorChecker();

  SessionAnalyticsData build(CanSession session) {
    final frames = List<CanFrame>.from(session.frames);
    // Compute error stats via checker to avoid relying on untyped saved errors
    final errorStats = _checker.getErrorStatistics(frames);

    final errorsOverTime = _buildErrorsOverTime(frames);
    final bitErrorRatio = _buildBitErrorRatioOverTime(frames);
    final heatmap = _buildHeatmap(frames);
    final perId = _buildErrorsPerId(frames);
    final recs = _checker.getRecommendations(errorStats, session.totalFrames);

    perId.sort((a, b) => b.percent.compareTo(a.percent));

    return SessionAnalyticsData(
      errorStats: errorStats,
      errorsOverTime: errorsOverTime,
      bitErrorRatioOverTime: bitErrorRatio,
      heatmap: heatmap,
      errorsPerId: perId.take(20).toList(),
      recommendations: recs,
    );
  }

  List<TimeBucketPoint> _buildErrorsOverTime(List<CanFrame> frames) {
    if (frames.isEmpty) return [];
    // Choose bucket size: for short sessions use seconds, otherwise minutes
    frames.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final start = frames.first.timestamp;
    final end = frames.last.timestamp;
    final totalSeconds = end.difference(start).inSeconds.clamp(1, 1 << 31);
    final useSeconds = totalSeconds <= 180; // <= 3 minutes → second buckets
    final bucketDuration = Duration(seconds: useSeconds ? 1 : 60);
    final buckets = <DateTime, int>{};

    for (final f in frames) {
      final key = _bucketKey(f.timestamp, bucketDuration);
      final hasErr = _checker.analyzeFrame(f).isNotEmpty;
      if (hasErr) {
        buckets[key] = (buckets[key] ?? 0) + 1;
      } else {
        buckets.putIfAbsent(key, () => 0);
      }
    }

    final orderedKeys = buckets.keys.toList()..sort();
    return orderedKeys.map((k) => TimeBucketPoint(k, buckets[k] ?? 0)).toList();
  }

  List<RatioBucketPoint> _buildBitErrorRatioOverTime(List<CanFrame> frames) {
    if (frames.isEmpty) return [];
    frames.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final start = frames.first.timestamp;
    final end = frames.last.timestamp;
    final totalSeconds = end.difference(start).inSeconds.clamp(1, 1 << 31);
    final useSeconds = totalSeconds <= 180;
    final bucketDuration = Duration(seconds: useSeconds ? 1 : 60);
    final bitsByBucket = <DateTime, int>{};
    final errBitsByBucket = <DateTime, int>{};

    for (final f in frames) {
      final key = _bucketKey(f.timestamp, bucketDuration);
      final totalBits = _estimateTotalBits(f);
      bitsByBucket[key] = (bitsByBucket[key] ?? 0) + totalBits;

      final errors = _checker.analyzeFrame(f);
      final errBits = errors.fold<int>(0, (sum, e) => sum + _estimateErrorBits(e));
      errBitsByBucket[key] = (errBitsByBucket[key] ?? 0) + errBits;
    }

    final keys = bitsByBucket.keys.toList()..sort();
    return keys.map((k) {
      final total = bitsByBucket[k] ?? 1;
      final err = errBitsByBucket[k] ?? 0;
      final ratio = total == 0 ? 0.0 : err / total;
      return RatioBucketPoint(k, ratio.clamp(0.0, 1.0));
    }).toList();
  }

  HeatmapData _buildHeatmap(List<CanFrame> frames) {
    // 24 x 6 (hour x 10-minute slots)
    final matrix = <int, List<int>>{for (var h = 0; h < 24; h++) h: List.filled(6, 0)};
    var maxCount = 0;
    for (final f in frames) {
      final hasErr = _checker.analyzeFrame(f).isNotEmpty;
      if (!hasErr) continue;
      final hour = f.timestamp.hour;
      final slot = (f.timestamp.minute / 10).floor().clamp(0, 5);
      final newVal = ++matrix[hour]![slot];
      if (newVal > maxCount) maxCount = newVal;
    }
    return HeatmapData(matrix, maxCount);
  }

  List<IdErrorStat> _buildErrorsPerId(List<CanFrame> frames) {
    final perIdTotal = <int, int>{};
    final perIdErr = <int, int>{};
    for (final f in frames) {
      perIdTotal[f.id] = (perIdTotal[f.id] ?? 0) + 1;
      final hasErr = _checker.analyzeFrame(f).isNotEmpty;
      if (hasErr) perIdErr[f.id] = (perIdErr[f.id] ?? 0) + 1;
    }
    final list = <IdErrorStat>[];
    for (final entry in perIdTotal.entries) {
      list.add(IdErrorStat(
        id: entry.key,
        totalFrames: entry.value,
        errorFrames: perIdErr[entry.key] ?? 0,
      ));
    }
    list.sort((a, b) => b.percent.compareTo(a.percent));
    return list;
  }

  DateTime _bucketKey(DateTime ts, Duration bucket) {
    final micros = ts.microsecondsSinceEpoch;
    final bucketMicros = bucket.inMicroseconds;
    final start = (micros ~/ bucketMicros) * bucketMicros;
    return DateTime.fromMicrosecondsSinceEpoch(start);
  }

  int _estimateTotalBits(CanFrame f) {
    // Approximate: standard CAN frame ~ 47 bits overhead + dlc*8 data bits.
    // We don't track IDE here; assume standard-ish frame length.
    return 47 + (f.dlc * 8) + 15; // include CRC field length
  }

  int _estimateErrorBits(CanErrorInfo e) {
    switch (e.type) {
      case CanErrorType.crcError:
        return 2; // assume ~2 bits flipped
      case CanErrorType.stuffingError:
        final seq = e.details['sequence'] as String?;
        if (seq == null) return 1;
        // stuffing violation occurs after 5 identical bits
        return max(1, seq.length - 5);
      case CanErrorType.formError:
      case CanErrorType.formatError:
        return 1;
      case CanErrorType.ackError:
        return 1;
      case CanErrorType.overloadError:
        return 0; // not a bit flip but bus condition
      case CanErrorType.activeError:
      case CanErrorType.passiveError:
      case CanErrorType.busOffError:
        return 0;
      case CanErrorType.none:
        return 0;
    }
  }
}

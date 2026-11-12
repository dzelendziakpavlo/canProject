import '../../domain/services/recorded_frame_errors.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../domain/detection/can_error_checker.dart';
import '../../domain/models/can_session.dart';
import '../../domain/models/can_frame.dart';
import '../../domain/services/session_analytics.dart';
import '../../core/theme.dart';

class ErrorOverTimeChart extends StatelessWidget {
  final List<TimeBucketPoint> points;
  final String title;
  final Color color;
  const ErrorOverTimeChart({
    super.key,
    required this.points,
    this.title = 'Errors Over Time',
    this.color = Colors.orange,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(title: title),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: points.isEmpty
                ? _EmptyChart()
                : LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        getDrawingHorizontalLine: (_) =>
                            FlLine(color: Colors.white10, strokeWidth: 1),
                        getDrawingVerticalLine: (_) =>
                            FlLine(color: Colors.white10, strokeWidth: 1),
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 32,
                            getTitlesWidget: (v, m) => Text(
                              v.toInt().toString(),
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(color: Colors.white10),
                      ),
                      minX: 0,
                      maxX: points.length < 2
                          ? 1
                          : (points.length - 1).toDouble(),
                      minY: 0,
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          fitInsideHorizontally: true,
                          fitInsideVertically: true,
                          getTooltipItems: (spots) => spots
                              .map(
                                (s) => LineTooltipItem(
                                  '${s.y.toInt()} frames',
                                  const TextStyle(color: Colors.white),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                      maxY: _maxY(
                        points.map((p) => p.count.toDouble()).toList(),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: points
                              .asMap()
                              .entries
                              .map(
                                (e) => FlSpot(
                                  e.key.toDouble(),
                                  e.value.count.toDouble(),
                                ),
                              )
                              .toList(),
                          isCurved: false,
                          color: color,
                          barWidth: 3,
                          dotData: FlDotData(show: points.length < 25),
                          belowBarData: BarAreaData(
                            show: true,
                            color: color.withOpacity(0.2),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  double _maxY(List<double> values) {
    if (values.isEmpty) return 10;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    return (maxV * 1.3).clamp(5.0, double.infinity);
  }
}

class BitErrorRatioChart extends StatelessWidget {
  final List<RatioBucketPoint> points;
  const BitErrorRatioChart({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Header(title: 'Stored Frame Error Ratio'),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: points.isEmpty
                ? _EmptyChart()
                : LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        getDrawingHorizontalLine: (_) =>
                            FlLine(color: Colors.white10, strokeWidth: 1),
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 40,
                            getTitlesWidget: (v, m) => Text(
                              '${v.toStringAsFixed(1)}%',
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                        bottomTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(color: Colors.white10),
                      ),
                      minX: 0,
                      maxX: points.length < 2
                          ? 1
                          : (points.length - 1).toDouble(),
                      minY: 0,
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          fitInsideHorizontally: true,
                          fitInsideVertically: true,
                          getTooltipItems: (spots) => spots
                              .map(
                                (s) => LineTooltipItem(
                                  '${s.y.toStringAsFixed(1)}%',
                                  const TextStyle(color: Colors.white),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                      maxY: points.isEmpty
                          ? 5
                          : (points
                                        .map((p) => p.ratio * 100)
                                        .reduce((a, b) => a > b ? a : b) *
                                    1.2)
                                .clamp(5.0, 100.0),
                      lineBarsData: [
                        LineChartBarData(
                          spots: points
                              .asMap()
                              .entries
                              .map(
                                (e) => FlSpot(
                                  e.key.toDouble(),
                                  (e.value.ratio * 100.0),
                                ),
                              )
                              .toList(),
                          isCurved: false,
                          color: AppTheme.accentRed,
                          barWidth: 3,
                          dotData: FlDotData(show: points.length < 25),
                          belowBarData: BarAreaData(
                            show: true,
                            color: AppTheme.accentRed.withOpacity(0.15),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class ErrorHeatmap extends StatelessWidget {
  final HeatmapData data;
  const ErrorHeatmap({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final maxC = data.maxCount == 0 ? 1 : data.maxCount;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Header(title: 'Errors Heatmap (hour x 10m)'),
          const SizedBox(height: 8),
          SizedBox(
            height: 260,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Hours axis
                SizedBox(
                  width: 28,
                  child: Column(
                    children: List.generate(
                      24,
                      (h) => Expanded(
                        child: Center(
                          child: Text(
                            h.toString().padLeft(2, '0'),
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Grid 24 x 6
                Expanded(
                  child: Column(
                    children: List.generate(
                      24,
                      (h) => Expanded(
                        child: Row(
                          children: List.generate(6, (s) {
                            final val = data.matrix[h]![s];
                            final t = val / maxC;
                            final color =
                                Color.lerp(
                                  Colors.transparent,
                                  AppTheme.accentRed,
                                  t,
                                ) ??
                                Colors.red;
                            return Expanded(
                              child: Container(
                                margin: const EdgeInsets.all(1),
                                decoration: BoxDecoration(
                                  color: color.withOpacity(0.6 * t),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            );
                          }),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ErrorsPerIdBarChart extends StatelessWidget {
  final List<IdErrorStat> stats;
  const ErrorsPerIdBarChart({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final top = stats.take(10).toList();
    if (top.isEmpty) return const _Card(child: _EmptyChart());

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Header(title: 'Errors per CAN ID (%)'),
          const SizedBox(height: 8),
          SizedBox(
            height: 220,
            child: BarChart(
              BarChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: Colors.white10, strokeWidth: 1),
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (v, m) => Text(
                        '${v.toStringAsFixed(1)}%',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (v, m) {
                        final idx = v.toInt();
                        if (idx < 0 || idx >= top.length) {
                          return const SizedBox();
                        }
                        final id = top[idx].id;
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '0x${id.toRadixString(16).toUpperCase()}',
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 10,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(color: Colors.white10),
                ),
                barGroups: List.generate(top.length, (i) {
                  final p = top[i].percent.clamp(0, 100);
                  return BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: p.toDouble(),
                        color: AppTheme.primaryOrange,
                        width: 12,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                    showingTooltipIndicators: [],
                  );
                }),
                // Hide intrusive tooltips; details are shown via pie slice tap sheet
                barTouchData: BarTouchData(enabled: false),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showErrorTypeDetailsSheet(
  BuildContext context,
  CanSession session,
  CanErrorType type, {
  required SessionAnalyticsBuilder builder,
}) async {
  final frames = session.frames;
  final matching = <CanFrame>[];
  for (final f in frames) {
    final errs = recordedFrameErrors(f);
    if (errs.any((e) => e.type == type)) matching.add(f);
  }
  matching.sort((a, b) => b.timestamp.compareTo(a.timestamp));

  final total = frames.length;
  final count = matching.length;
  final percent = total == 0 ? 0.0 : (count / total) * 100.0;

  // Aggregate by CAN ID
  final perId = <int, int>{};
  for (final f in matching) {
    perId[f.id] = (perId[f.id] ?? 0) + 1;
  }
  final topPerId = perId.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  showModalBottomSheet(
    context: context,
    backgroundColor: AppTheme.darkSurface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    builder: (_) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline, color: AppTheme.primaryOrange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${type.name.toUpperCase()} DETAILS',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  '${percent.toStringAsFixed(1)}%',
                  style: const TextStyle(color: AppTheme.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Stored matching frames: $count of $total frames',
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            const Text(
              'Stored classifications retain their origin. Legacy labels may be inferred or simulated; aggregate TWAI counters do not confirm protocol error subtypes.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            if (topPerId.isNotEmpty) ...[
              const Text(
                'Top affected CAN IDs',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 90,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: topPerId.length.clamp(0, 6),
                  itemBuilder: (context, i) {
                    final e = topPerId[i];
                    return Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.darkContainer,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '0x${e.key.toRadixString(16).toUpperCase()}',
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${e.value} hits',
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
            ],
            const Text(
              'Recent samples',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ...matching
                .take(6)
                .map(
                  (f) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Text(
                          '${f.timestamp.hour.toString().padLeft(2, '0')}:${f.timestamp.minute.toString().padLeft(2, '0')}:${f.timestamp.second.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'ID 0x${f.id.toRadixString(16).toUpperCase()} • DLC ${f.dlc}',
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: child,
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  const _Header({required this.title});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.insights, color: AppTheme.primaryOrange, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyChart extends StatelessWidget {
  const _EmptyChart();
  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      child: const Text('No data', style: TextStyle(color: AppTheme.textMuted)),
    );
  }
}

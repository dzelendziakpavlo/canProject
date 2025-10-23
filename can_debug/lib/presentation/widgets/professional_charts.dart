import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../domain/detection/can_error_checker.dart';

/// Професійний віджет для відображення live error rate chart
class ProfessionalErrorRateChart extends StatelessWidget {
  final List<double> errorRateHistory;
  final Map<CanErrorType, int> errorStats;
  final double currentErrorRate;
  final bool isRunning;

  const ProfessionalErrorRateChart({
    super.key,
    required this.errorRateHistory,
    required this.errorStats,
    required this.currentErrorRate,
    required this.isRunning,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context),
          const SizedBox(height: 16),
          Expanded(
            child: _buildChart(context),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Live Error Rate',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: isRunning ? Colors.green : Colors.red,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${currentErrorRate.toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: _getErrorRateColor(),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildChart(BuildContext context) {
    if (errorRateHistory.isEmpty) {
      return Center(
        child: Text(
          'No data available',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Colors.grey,
          ),
        ),
      );
    }

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          horizontalInterval: 5,
          verticalInterval: 10,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.grey.withOpacity(0.3),
              strokeWidth: 1,
            );
          },
          getDrawingVerticalLine: (value) {
            return FlLine(
              color: Colors.grey.withOpacity(0.3),
              strokeWidth: 1,
            );
          },
        ),
        titlesData: FlTitlesData(
          show: true,
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: 20,
              getTitlesWidget: (value, meta) {
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text(
                    '${value.toInt()}s',
                    style: const TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.w400,
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 10,
              reservedSize: 40,
              getTitlesWidget: (value, meta) {
                return Text(
                  '${value.toInt()}%',
                  style: const TextStyle(
                    color: Colors.grey,
                    fontWeight: FontWeight.w400,
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.left,
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(
            color: Colors.grey.withOpacity(0.3),
            width: 1,
          ),
        ),
        minX: 0,
        maxX: errorRateHistory.length.toDouble() - 1,
        minY: 0,
        maxY: _getMaxY(),
        lineBarsData: [
          LineChartBarData(
            spots: _getSpots(),
            isCurved: true,
            color: _getErrorRateColor(),
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: errorRateHistory.length < 20,
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 4,
                  color: _getErrorRateColor(),
                  strokeWidth: 2,
                  strokeColor: Colors.white,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              color: _getErrorRateColor().withOpacity(0.2),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _getErrorRateColor().withOpacity(0.3),
                  _getErrorRateColor().withOpacity(0.05),
                ],
              ),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            tooltipBgColor: Colors.blueGrey.withOpacity(0.9),
            tooltipRoundedRadius: 8,
            getTooltipItems: (List<LineBarSpot> touchedBarSpots) {
              return touchedBarSpots.map((barSpot) {
                return LineTooltipItem(
                  'Error Rate: ${barSpot.y.toStringAsFixed(1)}%\\nTime: ${barSpot.x.toInt()}s',
                  const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                );
              }).toList();
            },
          ),
        ),
      ),
    );
  }

  List<FlSpot> _getSpots() {
    return errorRateHistory.asMap().entries.map((entry) {
      return FlSpot(entry.key.toDouble(), entry.value);
    }).toList();
  }

  double _getMaxY() {
    if (errorRateHistory.isEmpty) return 100;
    final maxValue = errorRateHistory.reduce((a, b) => a > b ? a : b);
    // Add 20% padding to the top
    return (maxValue * 1.2).clamp(10, 100);
  }

  Color _getErrorRateColor() {
    if (currentErrorRate < 5) return Colors.green;
    if (currentErrorRate < 15) return Colors.orange;
    return Colors.red;
  }
}

/// Професійний pie chart для розподілу типів помилок
class ErrorTypeDistributionChart extends StatelessWidget {
  final Map<CanErrorType, int> errorStats;

  const ErrorTypeDistributionChart({
    super.key,
    required this.errorStats,
  });

  @override
  Widget build(BuildContext context) {
    final totalErrors = errorStats.values.fold(0, (sum, count) => sum + count);
    
    if (totalErrors == 0) {
      return Container(
        height: 200,
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Center(
          child: Text(
            'No errors detected',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return Container(
      height: 200,
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Error Distribution',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: PieChart(
                    PieChartData(
                      sections: _getPieSections(totalErrors),
                      borderData: FlBorderData(show: false),
                      sectionsSpace: 2,
                      centerSpaceRadius: 40,
                      pieTouchData: PieTouchData(
                        touchCallback: (FlTouchEvent event, pieTouchResponse) {
                          // Handle touch events if needed
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 1,
                  child: _buildLegend(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<PieChartSectionData> _getPieSections(int totalErrors) {
    final sections = <PieChartSectionData>[];

    for (final entry in errorStats.entries) {
      if (entry.value > 0) {
        final percentage = (entry.value / totalErrors) * 100;
        sections.add(
          PieChartSectionData(
            color: _getErrorTypeColor(entry.key),
            value: entry.value.toDouble(),
            title: '${percentage.toStringAsFixed(1)}%',
            radius: 60,
            titleStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            titlePositionPercentageOffset: 0.6,
          ),
        );
      }
    }

    return sections;
  }

  Widget _buildLegend(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: errorStats.entries
          .where((entry) => entry.value > 0)
          .map((entry) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _getErrorTypeColor(entry.key),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _getErrorTypeName(entry.key),
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${entry.value}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ))
          .toList(),
    );
  }

  Color _getErrorTypeColor(CanErrorType type) {
    switch (type) {
      case CanErrorType.crcError:
        return Colors.red;
      case CanErrorType.stuffingError:
        return Colors.orange;
      case CanErrorType.formatError:
        return Colors.purple;
      case CanErrorType.ackError:
        return Colors.blue;
      case CanErrorType.overloadError:
        return Colors.green;
      case CanErrorType.formError:
        return Colors.teal;
      default:
        return Colors.grey;
    }
  }

  String _getErrorTypeName(CanErrorType type) {
    switch (type) {
      case CanErrorType.crcError:
        return 'CRC';
      case CanErrorType.stuffingError:
        return 'Bit Stuffing';
      case CanErrorType.formatError:
        return 'Format';
      case CanErrorType.ackError:
        return 'ACK';
      case CanErrorType.overloadError:
        return 'Overload';
      case CanErrorType.formError:
        return 'Form';
      default:
        return 'Unknown';
    }
  }
}
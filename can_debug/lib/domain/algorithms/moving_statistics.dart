import 'dart:math' as math;
import 'dart:collection';

/// **Експоненційно згладжені статистики**
/// 
/// **Що робить**: Відстежує mean, variance, std dev з експоненційним decay
/// **Переваги**: Новіші значення мають більший вплив, швидко адаптується
/// **Використання**: Outlier detection, trend analysis, adaptive thresholds
class ExponentialMovingStatistics {
  final double _alpha;  // Decay factor (0.0-1.0, більше = швидша адаптація)
  double _mean = 0.0;
  double _variance = 0.0;
  int _count = 0;
  
  /// Створює EMS з заданим decay factor
  /// 
  /// [alpha] - швидкість адаптації:
  ///   0.01 = дуже повільна (стабільна)
  ///   0.1  = середня (збалансована) 
  ///   0.3  = швидка (реактивна)
  ExponentialMovingStatistics({double alpha = 0.1}) : _alpha = alpha;
  
  /// Додає нове значення та оновлює статистики
  void addValue(double value) {
    _count++;
    
    if (_count == 1) {
      // Перше значення
      _mean = value;
      _variance = 0.0;
    } else {
      // Exponential moving average
      final delta = value - _mean;
      _mean += _alpha * delta;
      
      // Exponential moving variance
      _variance = (1 - _alpha) * (_variance + _alpha * delta * delta);
    }
  }
  
  /// Поточний mean
  double get mean => _mean;
  
  /// Standard deviation
  double get stdDev => math.sqrt(_variance);
  
  /// Variance
  double get variance => _variance;
  
  /// Coefficient of variation (относительная изменчивость)
  double get coefficientOfVariation => _mean != 0 ? stdDev / _mean.abs() : 0.0;
  
  /// Z-score для значення (кількість стандартних відхилень від mean)
  double zScore(double value) => stdDev != 0 ? (value - mean) / stdDev : 0.0;
  
  /// Чи є значення outlier (за Z-score)
  bool isOutlier(double value, {double threshold = 2.0}) {
    return zScore(value).abs() > threshold;
  }
  
  /// Скидає всі статистики
  void reset() {
    _mean = 0.0;
    _variance = 0.0;
    _count = 0;
  }
  
  /// Кількість оброблених значень
  int get count => _count;
  
  /// Рівень впевненості в статистиках (0-1)
  double get confidence => math.min(1.0, _count / 30.0);
}

/// **Багатовимірний статистичний аналізатор**
class CanStatisticsEngine {
  final Map<String, ExponentialMovingStatistics> _metrics = {};
  final Map<String, Queue<double>> _history = {};
  final int _maxHistory = 100;
  
  /// Оновлює метрику новим значенням
  void updateMetric(String name, double value) {
    // Оновлюємо EMS статистики
    _metrics[name] ??= ExponentialMovingStatistics();
    _metrics[name]!.addValue(value);
    
    // Зберігаємо історію
    _history[name] ??= Queue<double>();
    _history[name]!.add(value);
    
    // Обмежуємо розмір історії
    if (_history[name]!.length > _maxHistory) {
      _history[name]!.removeFirst();
    }
  }
  
  /// Перевіряє чи є значення outlier
  bool isOutlier(String metric, double value, {double threshold = 2.0}) {
    final stats = _metrics[metric];
    return stats != null && stats.isOutlier(value, threshold: threshold);
  }
  
  /// Отримує статистики для метрики
  ExponentialMovingStatistics? getStatistics(String metric) => _metrics[metric];
  
  /// Отримує історію метрики
  List<double> getHistory(String metric) {
    return _history[metric]?.toList() ?? [];
  }
  
  /// Всі доступні метрики
  List<String> get availableMetrics => _metrics.keys.toList();
  
  /// Створює звіт по всіх метриках
  StatisticsReport generateReport() {
    final metricReports = <String, MetricReport>{};
    
    for (final name in _metrics.keys) {
      final stats = _metrics[name]!;
      final history = _history[name]!.toList();
      
      metricReports[name] = MetricReport(
        name: name,
        mean: stats.mean,
        stdDev: stats.stdDev,
        coefficientOfVariation: stats.coefficientOfVariation,
        confidence: stats.confidence,
        outlierCount: _countOutliers(name),
        trend: _calculateTrend(history),
        stability: _calculateStability(history),
      );
    }
    
    return StatisticsReport(metricReports: metricReports);
  }
  
  /// Підраховує кількість outliers за останні N значень
  int _countOutliers(String metric, {int lastN = 20}) {
    final stats = _metrics[metric];
    final history = _history[metric];
    
    if (stats == null || history == null) return 0;
    
    final recentValues = history.toList().takeLast(lastN);
    return recentValues.where((value) => stats.isOutlier(value)).length;
  }
  
  /// Обчислює trend напрямок
  TrendDirection _calculateTrend(List<double> values) {
    if (values.length < 5) return TrendDirection.stable;
    
    final recent = values.takeLast(10).toList();
    final slope = _calculateLinearRegressionSlope(recent);
    
    if (slope > 0.1) return TrendDirection.increasing;
    if (slope < -0.1) return TrendDirection.decreasing;
    return TrendDirection.stable;
  }
  
  /// Обчислює стабільність (CV останніх значень)
  double _calculateStability(List<double> values) {
    if (values.length < 5) return 1.0;
    
    final recent = values.takeLast(10);
    final mean = recent.reduce((a, b) => a + b) / recent.length;
    final variance = recent.map((x) => math.pow(x - mean, 2)).reduce((a, b) => a + b) / recent.length;
    final stdDev = math.sqrt(variance);
    
    return mean != 0 ? stdDev / mean : 0.0;
  }
  
  /// Обчислює slope лінійної регресії
  double _calculateLinearRegressionSlope(List<double> values) {
    if (values.length < 2) return 0.0;
    
    final n = values.length;
    final x = List.generate(n, (i) => i.toDouble());
    final y = values;
    
    final xMean = x.reduce((a, b) => a + b) / n;
    final yMean = y.reduce((a, b) => a + b) / n;
    
    double numerator = 0.0;
    double denominator = 0.0;
    
    for (int i = 0; i < n; i++) {
      numerator += (x[i] - xMean) * (y[i] - yMean);
      denominator += math.pow(x[i] - xMean, 2);
    }
    
    return denominator != 0 ? numerator / denominator : 0.0;
  }
  
  /// Скидає всі метрики
  void reset() {
    _metrics.clear();
    _history.clear();
  }
}

/// **Звіт по одній метриці**
class MetricReport {
  final String name;
  final double mean;
  final double stdDev;
  final double coefficientOfVariation;
  final double confidence;
  final int outlierCount;
  final TrendDirection trend;
  final double stability;  // 0-1, менше = стабільніше
  
  MetricReport({
    required this.name,
    required this.mean,
    required this.stdDev,
    required this.coefficientOfVariation,
    required this.confidence,
    required this.outlierCount,
    required this.trend,
    required this.stability,
  });
  
  /// Загальна оцінка здоров'я метрики
  HealthStatus get healthStatus {
    if (stability > 0.5 || outlierCount > 5) return HealthStatus.critical;
    if (stability > 0.3 || outlierCount > 2) return HealthStatus.warning;
    if (stability > 0.1 || outlierCount > 0) return HealthStatus.caution;
    return HealthStatus.healthy;
  }
}

/// **Загальний звіт статистик**
class StatisticsReport {
  final Map<String, MetricReport> metricReports;
  
  StatisticsReport({required this.metricReports});
  
  /// Загальний health status системи
  HealthStatus get overallHealth {
    final statuses = metricReports.values.map((r) => r.healthStatus).toList();
    
    if (statuses.any((s) => s == HealthStatus.critical)) return HealthStatus.critical;
    if (statuses.any((s) => s == HealthStatus.warning)) return HealthStatus.warning;
    if (statuses.any((s) => s == HealthStatus.caution)) return HealthStatus.caution;
    return HealthStatus.healthy;
  }
  
  /// Кількість метрик по health status
  Map<HealthStatus, int> get healthSummary {
    final summary = <HealthStatus, int>{};
    
    for (final status in HealthStatus.values) {
      summary[status] = metricReports.values.where((r) => r.healthStatus == status).length;
    }
    
    return summary;
  }
}

enum TrendDirection { increasing, decreasing, stable }
enum HealthStatus { healthy, caution, warning, critical }

/// **Extension для кращої роботи з колекціями**
extension TakeLast<T> on Iterable<T> {
  Iterable<T> takeLast(int count) {
    final list = toList();
    final startIndex = math.max(0, list.length - count);
    return list.sublist(startIndex);
  }
}
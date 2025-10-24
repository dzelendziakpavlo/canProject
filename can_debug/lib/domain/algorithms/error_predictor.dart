import 'dart:math' as math;
import 'dart:collection';

/// **ARIMA-based Error Rate Predictor**
/// 
/// **Що робить**: Прогнозує майбутні error rates на основі історії
/// **Модель**: Auto-Regressive Integrated Moving Average (ARIMA)
/// **Переваги**: Враховує trends, seasonality, та autocorrelation
/// **Використання**: Early warning system, capacity planning
class ErrorPredictor {
  final Queue<double> _errorHistory = Queue();
  final Queue<double> _predictions = Queue();
  final int _maxHistory = 200;
  final int _predictionHorizon = 10;
  
  // ARIMA model parameters
  final List<double> _arCoeffs = [0.7, -0.2, 0.1];  // Auto-Regressive coefficients
  final List<double> _maCoeffs = [0.3, -0.1];       // Moving Average coefficients
  
  // Adaptive parameters
  double _baselineMean = 0.0;
  double _adaptiveAlpha = 0.1;
  
  /// Додає новий error rate та оновлює модель
  void addErrorRate(double errorRate) {
    _errorHistory.add(errorRate);
    
    // Підтримуємо sliding window
    if (_errorHistory.length > _maxHistory) {
      _errorHistory.removeFirst();
    }
    
    // Оновлюємо baseline mean
    _updateBaseline(errorRate);
    
    // Автоматично підстроюємо коефіцієнти
    if (_errorHistory.length > 50) {
      _adaptCoefficients();
    }
  }
  
  /// Прогнозує наступний error rate
  PredictionResult predictNextErrorRate() {
    if (_errorHistory.length < _arCoeffs.length + _maCoeffs.length) {
      return PredictionResult(
        prediction: _baselineMean,
        confidence: 0.1,
        trend: TrendDirection.stable,
        alertLevel: AlertLevel.normal,
      );
    }
    
    final history = _errorHistory.toList();
    
    // Detrending (differencing)
    final detrended = _applyDifferencing(history);
    
    // AR component (Auto-Regressive)
    double arPrediction = 0.0;
    for (int i = 0; i < _arCoeffs.length && i < detrended.length; i++) {
      final index = detrended.length - 1 - i;
      arPrediction += _arCoeffs[i] * detrended[index];
    }
    
    // MA component (Moving Average of residuals)
    final residuals = _calculateResiduals(history);
    double maPrediction = 0.0;
    for (int i = 0; i < _maCoeffs.length && i < residuals.length; i++) {
      final index = residuals.length - 1 - i;
      maPrediction += _maCoeffs[i] * residuals[index];
    }
    
    // Combined ARIMA prediction
    double rawPrediction = _baselineMean + arPrediction + maPrediction;
    
    // Ensure non-negative error rate
    rawPrediction = math.max(0.0, rawPrediction);
    
    // Calculate confidence based on historical accuracy
    final confidence = _calculateConfidence(history, rawPrediction);
    
    // Determine trend direction
    final trend = _calculateTrend(history);
    
    // Determine alert level
    final alertLevel = _determineAlertLevel(rawPrediction, confidence, trend);
    
    // Store prediction for validation
    _predictions.add(rawPrediction);
    if (_predictions.length > _predictionHorizon) {
      _predictions.removeFirst();
    }
    
    return PredictionResult(
      prediction: rawPrediction,
      confidence: confidence,
      trend: trend,
      alertLevel: alertLevel,
    );
  }
  
  /// Прогнозує кілька кроків вперед
  List<PredictionResult> predictMultipleSteps(int steps) {
    final results = <PredictionResult>[];
    final workingHistory = Queue<double>.from(_errorHistory);
    
    for (int i = 0; i < steps; i++) {
      // Створюємо тимчасовий predictor з поточною історією
      final tempPredictor = ErrorPredictor();
      tempPredictor._errorHistory.addAll(workingHistory);
      tempPredictor._baselineMean = _baselineMean;
      
      // Отримуємо прогноз
      final prediction = tempPredictor.predictNextErrorRate();
      results.add(prediction);
      
      // Додаємо прогноз в робочу історію для наступного кроку
      workingHistory.add(prediction.prediction);
      if (workingHistory.length > _maxHistory) {
        workingHistory.removeFirst();
      }
    }
    
    return results;
  }
  
  /// Оцінює точність прогнозів
  double evaluatePredictionAccuracy() {
    if (_predictions.length < 5 || _errorHistory.length < 5) return 0.0;
    
    // Порівнюємо останні прогнози з фактичними значеннями
    final recentHistory = _errorHistory.toList().takeLast(5);
    final recentPredictions = _predictions.toList().takeLast(5);
    
    double totalError = 0.0;
    int comparisons = 0;
    
    for (int i = 0; i < math.min(recentHistory.length, recentPredictions.length); i++) {
      final actual = recentHistory.elementAt(i);
      final predicted = recentPredictions.elementAt(i);
      totalError += (actual - predicted).abs();
      comparisons++;
    }
    
    if (comparisons == 0) return 0.0;
    
    final meanAbsoluteError = totalError / comparisons;
    final historicalRange = _calculateRange(_errorHistory.toList());
    
    // Accuracy as percentage (0-1)
    return historicalRange > 0 ? math.max(0.0, 1.0 - (meanAbsoluteError / historicalRange)) : 0.0;
  }
  
  /// Детектує аномальні patterns в прогнозах
  AnomalyAlert? detectPredictionAnomaly() {
    final multiStep = predictMultipleSteps(5);
    
    // Перевіряємо різкі стрибки
    for (int i = 1; i < multiStep.length; i++) {
      final change = (multiStep[i].prediction - multiStep[i-1].prediction).abs();
      final threshold = _calculateDynamicThreshold();
      
      if (change > threshold) {
        return AnomalyAlert(
          type: AnomalyType.suddenSpike,
          severity: change > threshold * 2 ? AnomalySeverity.critical : AnomalySeverity.high,
          prediction: multiStep[i].prediction,
          timeToOccurrence: i,
          description: 'Прогнозується різкий стрибок error rate через $i кроків',
        );
      }
    }
    
    // Перевіряємо постійне зростання
    final increasing = multiStep.where((p) => p.trend == TrendDirection.increasing).length;
    if (increasing >= 4) {
      return AnomalyAlert(
        type: AnomalyType.sustainedIncrease,
        severity: AnomalySeverity.medium,
        prediction: multiStep.last.prediction,
        timeToOccurrence: multiStep.length,
        description: 'Прогнозується стійке зростання error rate',
      );
    }
    
    return null;
  }
  
  /// Оновлює baseline mean адаптивно
  void _updateBaseline(double newValue) {
    if (_errorHistory.length == 1) {
      _baselineMean = newValue;
    } else {
      _baselineMean = (1 - _adaptiveAlpha) * _baselineMean + _adaptiveAlpha * newValue;
    }
  }
  
  /// Адаптує коефіцієнти на основі performance
  void _adaptCoefficients() {
    final accuracy = evaluatePredictionAccuracy();
    
    if (accuracy < 0.7) {
      // Низька точність - підстроюємо коефіцієнти
      _adaptiveAlpha = math.min(0.3, _adaptiveAlpha * 1.1);
      
      // Зменшуємо AR коефіцієнти якщо trend непередбачуваний
      for (int i = 0; i < _arCoeffs.length; i++) {
        _arCoeffs[i] *= 0.95;
      }
    } else if (accuracy > 0.9) {
      // Висока точність - стабілізуємо
      _adaptiveAlpha = math.max(0.05, _adaptiveAlpha * 0.95);
    }
  }
  
  /// Застосовує differencing для detrending
  List<double> _applyDifferencing(List<double> data) {
    if (data.length < 2) return data;
    
    final differenced = <double>[];
    for (int i = 1; i < data.length; i++) {
      differenced.add(data[i] - data[i-1]);
    }
    
    return differenced;
  }
  
  /// Обчислює residuals (помилки прогнозування)
  List<double> _calculateResiduals(List<double> data) {
    if (data.length < 5) return <double>[];
    
    final residuals = <double>[];
    
    for (int i = 3; i < data.length; i++) {
      // Простий linear predictor для обчислення residual
      final predicted = data[i-1] + (data[i-1] - data[i-2]);
      final residual = data[i] - predicted;
      residuals.add(residual);
    }
    
    return residuals;
  }
  
  /// Обчислює confidence на основі accuracy
  double _calculateConfidence(List<double> history, double prediction) {
    final accuracy = evaluatePredictionAccuracy();
    final variance = _calculateVariance(history.takeLast(10).toList());
    final stabilityFactor = math.exp(-variance);
    
    return (accuracy * 0.7 + stabilityFactor * 0.3).clamp(0.0, 1.0);
  }
  
  /// Розраховує trend direction
  TrendDirection _calculateTrend(List<double> history) {
    if (history.length < 5) return TrendDirection.stable;
    
    final recent = history.takeLast(5).toList();
    final slope = _calculateLinearRegressionSlope(recent);
    
    if (slope > 0.5) return TrendDirection.increasing;
    if (slope < -0.5) return TrendDirection.decreasing;
    return TrendDirection.stable;
  }
  
  /// Визначає alert level
  AlertLevel _determineAlertLevel(double prediction, double confidence, TrendDirection trend) {
    if (prediction > 20.0 && confidence > 0.8) return AlertLevel.critical;
    if (prediction > 15.0 && confidence > 0.7) return AlertLevel.high;
    if (prediction > 10.0 || trend == TrendDirection.increasing) return AlertLevel.medium;
    if (prediction > 5.0) return AlertLevel.low;
    return AlertLevel.normal;
  }
  
  double _calculateVariance(List<double> values) {
    if (values.isEmpty) return 0.0;
    
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values.map((x) => math.pow(x - mean, 2)).reduce((a, b) => a + b) / values.length;
    return variance;
  }
  
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
  
  double _calculateRange(List<double> values) {
    if (values.isEmpty) return 0.0;
    
    final min = values.reduce(math.min);
    final max = values.reduce(math.max);
    return max - min;
  }
  
  double _calculateDynamicThreshold() {
    if (_errorHistory.length < 10) return 5.0;
    
    final recent = _errorHistory.toList().takeLast(10);
    final stdDev = math.sqrt(_calculateVariance(recent.toList()));
    return math.max(2.0, stdDev * 2.5);
  }
  
  /// Скидає predictor
  void reset() {
    _errorHistory.clear();
    _predictions.clear();
    _baselineMean = 0.0;
    _adaptiveAlpha = 0.1;
  }
  
  /// Поточна історія error rates
  List<double> get errorHistory => _errorHistory.toList();
  
  /// Історія прогнозів
  List<double> get predictionHistory => _predictions.toList();
  
  /// Чи готовий predictor до роботи
  bool get isReady => _errorHistory.length >= 10;
}

/// **Результат прогнозування**
class PredictionResult {
  final double prediction;        // Прогнозований error rate
  final double confidence;        // Впевненість 0-1
  final TrendDirection trend;     // Напрямок тренду
  final AlertLevel alertLevel;    // Рівень тривоги
  
  PredictionResult({
    required this.prediction,
    required this.confidence,
    required this.trend,
    required this.alertLevel,
  });
}

/// **Аномальний алерт в прогнозах**
class AnomalyAlert {
  final AnomalyType type;
  final AnomalySeverity severity;
  final double prediction;
  final int timeToOccurrence;     // Кроків до виникнення
  final String description;
  
  AnomalyAlert({
    required this.type,
    required this.severity,
    required this.prediction,
    required this.timeToOccurrence,
    required this.description,
  });
}

enum TrendDirection { increasing, decreasing, stable }
enum AlertLevel { normal, low, medium, high, critical }
enum AnomalyType { suddenSpike, sustainedIncrease, volatilityIncrease }
enum AnomalySeverity { low, medium, high, critical }

/// **Extension для роботи з колекціями**
extension TakeLast<T> on Iterable<T> {
  Iterable<T> takeLast(int count) {
    final list = toList();
    final startIndex = math.max(0, list.length - count);
    return list.sublist(startIndex);
  }
}
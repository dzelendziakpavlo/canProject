import 'dart:math' as math;

/// **Kalman Filter для згладжування error rate**
/// 
/// **Що робить**: Видаляє шум з raw measurements та дає smooth trend
/// **Переваги**: Кращий за простий moving average - адаптується до змін
/// **Використання**: Smooth error rate charts, accurate trend detection
class KalmanFilter {
  double _x = 0.0;  // State estimate (згладжене значення)
  double _p = 1.0;  // Error covariance (невизначеність)
  final double _q;  // Process noise (як швидко змінюється реальність)
  final double _r;  // Measurement noise (наскільки шумні наші вимірювання)
  
  /// Створює Kalman filter
  /// 
  /// [processNoise] - як швидко змінюється error rate (0.01 = повільно)
  /// [measurementNoise] - наскільки шумні raw data (0.1 = середньо)
  KalmanFilter({double processNoise = 0.01, double measurementNoise = 0.1})
      : _q = processNoise, _r = measurementNoise;
  
  /// Обробляє нове вимірювання та повертає згладжене значення
  double filter(double measurement) {
    // **Prediction step**: Прогнозуємо наступний стан
    _p = _p + _q;
    
    // **Update step**: Коригуємо прогноз на основі нового вимірювання
    final k = _p / (_p + _r);  // Kalman gain (наскільки довіряємо новому measurement)
    _x = _x + k * (measurement - _x);  // Оновлюємо стан
    _p = (1 - k) * _p;  // Зменшуємо невизначеність
    
    return _x;
  }
  
  /// Поточне згладжене значення
  double get smoothedValue => _x;
  
  /// Рівень невизначеності (чим менше, тим точніше)
  double get uncertainty => math.sqrt(_p);
  
  /// Скидає фільтр до початкового стану
  void reset() {
    _x = 0.0;
    _p = 1.0;
  }
}

/// **Аналізатор error rate з Kalman фільтрацією**
class ErrorRateAnalyzer {
  final KalmanFilter _filter = KalmanFilter(
    processNoise: 0.008,     // Error rate змінюється повільно
    measurementNoise: 0.15,  // Raw measurements досить шумні
  );
  
  final List<double> _rawHistory = [];
  final List<double> _smoothHistory = [];
  final int _maxHistory = 200;
  
  /// Додає нове raw error rate та повертає згладжене
  double addErrorRate(double rawErrorRate) {
    final smoothed = _filter.filter(rawErrorRate);
    
    // Зберігаємо історію
    _rawHistory.add(rawErrorRate);
    _smoothHistory.add(smoothed);
    
    // Обмежуємо розмір історії
    if (_rawHistory.length > _maxHistory) {
      _rawHistory.removeAt(0);
      _smoothHistory.removeAt(0);
    }
    
    return smoothed;
  }
  
  /// Raw error rates історія
  List<double> get rawHistory => List.unmodifiable(_rawHistory);
  
  /// Згладжені error rates історія  
  List<double> get smoothHistory => List.unmodifiable(_smoothHistory);
  
  /// Поточне згладжене значення
  double get currentSmoothedRate => _filter.smoothedValue;
  
  /// Рівень стабільності (чим менше, тим стабільніше)
  double get stability => _filter.uncertainty;
  
  /// Детектує різкі стрибки error rate
  bool get hasSpike {
    if (_rawHistory.length < 2) return false;
    
    final lastRaw = _rawHistory.last;
    final smoothed = _smoothHistory.last;
    final difference = (lastRaw - smoothed).abs();
    
    // Spike якщо різниця > 3 * uncertainty
    return difference > 3 * _filter.uncertainty;
  }
}
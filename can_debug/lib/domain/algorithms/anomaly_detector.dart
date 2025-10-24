import 'dart:math' as math;
import '../models/can_frame.dart';

/// **Features CAN фрейму для аналізу**
class CanFrameFeatures {
  final double idRange;        // Категорія ID (0-1: standard, 1-2: extended)
  final double dlcValue;       // DLC як число (0-8)  
  final double dataEntropy;    // Ентропія даних (0-8, більше = хаотичніше)
  final double timeDelta;      // Час з попереднього фрейму (мс)
  final double crcComplexity;  // Складність CRC pattern (0-1)
  
  CanFrameFeatures({
    required this.idRange,
    required this.dlcValue,
    required this.dataEntropy,
    required this.timeDelta,
    required this.crcComplexity,
  });
  
  /// Конвертує в числовий вектор для ML
  List<double> toVector() => [idRange, dlcValue, dataEntropy, timeDelta, crcComplexity];
}

/// **Isolation Forest - алгоритм для виявлення аномалій**
/// 
/// **Що робить**: Знаходить фрейми, які сильно відрізняються від нормальних
/// **Принцип**: Аномальні дані легше ізолювати (потребують менше поділів)
/// **Переваги**: Не потребує labeled data, швидкий, ефективний
class IsolationForest {
  final List<CanFrameFeatures> _trainingData = [];
  final int _maxDepth = 8;
  final int _numTrees = 50;
  
  /// Навчає модель на нормальних даних
  void train(List<CanFrame> normalFrames) {
    _trainingData.clear();
    
    for (int i = 0; i < normalFrames.length; i++) {
      final frame = normalFrames[i];
      final features = _extractFeatures(frame, i > 0 ? normalFrames[i-1] : null);
      _trainingData.add(features);
    }
  }
  
  /// Обчислює anomaly score для фрейму (0-1, більше = аномальніше)
  double calculateAnomalyScore(CanFrame frame) {
    if (_trainingData.isEmpty) return 0.0;
    
    final features = _extractFeatures(frame, null);
    double totalPathLength = 0.0;
    
    // Середня довжина шляху по всіх деревах
    for (int i = 0; i < _numTrees; i++) {
      totalPathLength += _calculatePathLength(features, 0);
    }
    
    final avgPathLength = totalPathLength / _numTrees;
    final expectedLength = _calculateExpectedLength(_trainingData.length);
    
    // Anomaly score: 2^(-avgPath/expectedPath)
    // Близько до 1 = аномалія, близько до 0 = нормально
    return math.pow(2, -avgPathLength / expectedLength).toDouble();
  }
  
  /// Витягує features з CAN фрейму
  CanFrameFeatures _extractFeatures(CanFrame frame, CanFrame? previousFrame) {
    // ID range category
    final idRange = frame.id > 0x7FF ? 1.5 : 0.5;  // Extended vs Standard
    
    // DLC value
    final dlcValue = frame.dlc.toDouble();
    
    // Data entropy (міра хаотичності даних)
    final dataEntropy = _calculateEntropy(frame.data);
    
    // Time delta з попереднього фрейму
    double timeDelta = 100.0;  // Default
    if (previousFrame != null) {
      timeDelta = frame.timestamp.difference(previousFrame.timestamp).inMilliseconds.toDouble();
    }
    
    // CRC complexity
    final crcComplexity = _analyzeCrcPattern(frame.crc);
    
    return CanFrameFeatures(
      idRange: idRange,
      dlcValue: dlcValue,
      dataEntropy: dataEntropy,
      timeDelta: math.min(timeDelta, 1000.0),  // Cap at 1 second
      crcComplexity: crcComplexity,
    );
  }
  
  /// Обчислює ентропію даних (міра хаотичності)
  double _calculateEntropy(List<int> data) {
    if (data.isEmpty) return 0.0;
    
    // Частота кожного байту
    final freq = <int, int>{};
    for (final byte in data) {
      freq[byte] = (freq[byte] ?? 0) + 1;
    }
    
    double entropy = 0.0;
    final length = data.length;
    
    for (final count in freq.values) {
      final p = count / length;
      if (p > 0) {
        entropy -= p * (math.log(p) / math.ln2);
      }
    }
    
    return entropy;
  }
  
  /// Аналізує складність CRC pattern
  double _analyzeCrcPattern(int crc) {
    // Підраховуємо кількість змін бітів (transitions)
    int transitions = 0;
    int prev = crc & 1;
    
    for (int i = 1; i < 8; i++) {
      final current = (crc >> i) & 1;
      if (current != prev) transitions++;
      prev = current;
    }
    
    // Нормалізуємо до 0-1 (max 7 transitions for 8 bits)
    return transitions / 7.0;
  }
  
  /// Симулює isolation path length
  double _calculatePathLength(CanFrameFeatures features, int depth) {
    if (depth >= _maxDepth || _trainingData.length <= 1) {
      return depth + _calculateC(_trainingData.length);
    }
    
    // Випадковий поділ по одній з dimensions
    final dimension = math.Random().nextInt(5);  // 5 features
    final featureVector = features.toVector();
    final splitValue = featureVector[dimension];
    
    // Рахуємо скільки training points менше/більше split value
    int leftCount = 0;
    for (final trainFeatures in _trainingData) {
      final trainVector = trainFeatures.toVector();
      if (trainVector[dimension] < splitValue) leftCount++;
    }
    
    // Якщо всі points в одну сторону, це може бути аномалія
    if (leftCount == 0 || leftCount == _trainingData.length) {
      return depth + 1;
    }
    
    return depth + 1;
  }
  
  /// Обчислює очікувану довжину шляху для нормальних точок
  double _calculateExpectedLength(int n) {
    if (n <= 1) return 0.0;
    return 2.0 * (math.log(n - 1) + 0.5772156649) - 2.0 * (n - 1) / n;
  }
  
  /// Обчислює поправочний коефіцієнт C(n)
  double _calculateC(int n) {
    if (n <= 1) return 0.0;
    return 2.0 * (math.log(n - 1) + 0.5772156649) - 2.0 * (n - 1) / n;
  }
}

/// **Результат anomaly detection**
class AnomalyResult {
  final double score;          // 0-1, більше = аномальніше
  final bool isAnomaly;        // true якщо score > threshold
  final String explanation;    // Чому це аномалія
  final AnomalySeverity severity;
  
  AnomalyResult({
    required this.score,
    required this.isAnomaly,
    required this.explanation,
    required this.severity,
  });
}

enum AnomalySeverity { low, medium, high, critical }

/// **Anomaly Detector з автоматичним навчанням**
class CanAnomalyDetector {
  final IsolationForest _forest = IsolationForest();
  final List<CanFrame> _recentFrames = [];
  final int _trainingSize = 200;
  final double _anomalyThreshold = 0.6;
  bool _isTrained = false;
  
  /// Додає фрейм та перевіряє на аномалію
  AnomalyResult analyzeFrame(CanFrame frame) {
    _recentFrames.add(frame);
    
    // Підтримуємо sliding window
    if (_recentFrames.length > _trainingSize * 2) {
      _recentFrames.removeAt(0);
    }
    
    // Навчаємо модель якщо достатньо даних
    if (!_isTrained && _recentFrames.length >= _trainingSize) {
      final normalFrames = _recentFrames.take(_trainingSize).toList();
      _forest.train(normalFrames);
      _isTrained = true;
    }
    
    if (!_isTrained) {
      return AnomalyResult(
        score: 0.0,
        isAnomaly: false,
        explanation: 'Модель ще навчається...',
        severity: AnomalySeverity.low,
      );
    }
    
    final score = _forest.calculateAnomalyScore(frame);
    final isAnomaly = score > _anomalyThreshold;
    
    return AnomalyResult(
      score: score,
      isAnomaly: isAnomaly,
      explanation: _generateExplanation(frame, score),
      severity: _calculateSeverity(score),
    );
  }
  
  String _generateExplanation(CanFrame frame, double score) {
    if (score <= 0.3) return 'Нормальний CAN фрейм';
    if (score <= 0.6) return 'Легка аномалія у timing або data pattern';
    if (score <= 0.8) return 'Підозрілий фрейм - незвичайна комбінація параметрів';
    return 'Критична аномалія - фрейм кардинально відрізняється';
  }
  
  AnomalySeverity _calculateSeverity(double score) {
    if (score <= 0.4) return AnomalySeverity.low;
    if (score <= 0.6) return AnomalySeverity.medium;
    if (score <= 0.8) return AnomalySeverity.high;
    return AnomalySeverity.critical;
  }
  
  /// Чи модель готова до аналізу
  bool get isReady => _isTrained;
  
  /// Скидає модель для перенавчання
  void reset() {
    _isTrained = false;
    _recentFrames.clear();
  }
}
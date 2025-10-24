import 'dart:math' as math;
import '../algorithms/kalman_filter.dart';
import '../algorithms/anomaly_detector.dart';
import '../algorithms/moving_statistics.dart';
import '../algorithms/advanced_crc.dart';
import '../algorithms/error_predictor.dart' as predictor;
import '../algorithms/performance_buffer.dart';
import '../models/can_frame.dart';

/// **Інтегрований сервіс для всіх advanced алгоритмів**
/// 
/// **Що робить**: Об'єднує всі алгоритми в одному місці
/// **Переваги**: Централізований аналіз, корелація між алгоритмами
/// **Використання**: Real-time CAN monitoring з AI-powered insights
class AdvancedCanAnalysisService {
  // Core algorithms
  final ErrorRateAnalyzer _kalmanAnalyzer = ErrorRateAnalyzer();
  final CanAnomalyDetector _anomalyDetector = CanAnomalyDetector();
  final CanStatisticsEngine _statisticsEngine = CanStatisticsEngine();
  final CanCrcValidator _crcValidator = CanCrcValidator();
  final predictor.ErrorPredictor _predictor = predictor.ErrorPredictor();
  final CanFrameBuffer _buffer = CanFrameBuffer(1000);
  
  // State tracking
  int _totalFrames = 0;
  int _errorFrames = 0;
  DateTime? _sessionStart;
  
  /// Ініціалізує analysis session
  void startAnalysis() {
    _sessionStart = DateTime.now();
    _totalFrames = 0;
    _errorFrames = 0;
    
    // Reset all algorithms (Kalman має власний reset метод)
    _anomalyDetector.reset();
    _statisticsEngine.reset();
    _predictor.reset();
    _buffer.resetStats();
  }
  
  /// **Головний метод - аналізує CAN фрейм через всі алгоритми**
  AdvancedAnalysisResult analyzeFrame(CanFrame frame) {
    _totalFrames++;
    if (frame.isCorrupted) _errorFrames++;
    
    // 1. Додаємо в high-performance buffer
    final frameData = CanFrameData.fromCanFrame(frame);
    _buffer.addCanFrame(frameData);
    
    // 2. Kalman filtering для error rate
    final currentErrorRate = _calculateCurrentErrorRate();
    final smoothedErrorRate = _kalmanAnalyzer.addErrorRate(currentErrorRate);
    
    // 3. Anomaly detection
    final anomalyResult = _anomalyDetector.analyzeFrame(frame);
    
    // 4. Moving statistics update
    _updateAllStatistics(frame, currentErrorRate);
    
    // 5. Advanced CRC validation
    final crcResult = _crcValidator.validateFrame(
      frame.data, frame.id, frame.dlc, frame.crc
    );
    
    // 6. Error prediction
    _predictor.addErrorRate(currentErrorRate);
    final prediction = _predictor.predictNextErrorRate();
    
    // 7. Correlation analysis між алгоритмами
    final correlationInsights = _analyzeCorrelations(
      anomalyResult, crcResult, prediction
    );
    
    return AdvancedAnalysisResult(
      frameId: frame.id,
      timestamp: frame.timestamp,
      
      // Kalman results
      rawErrorRate: currentErrorRate,
      smoothedErrorRate: smoothedErrorRate,
      errorRateStability: _kalmanAnalyzer.stability,
      hasErrorSpike: _kalmanAnalyzer.hasSpike,
      
      // Anomaly results
      anomalyScore: anomalyResult.score,
      isAnomaly: anomalyResult.isAnomaly,
      anomalySeverity: anomalyResult.severity,
      anomalyExplanation: anomalyResult.explanation,
      
      // Statistics results
      statisticsReport: _statisticsEngine.generateReport(),
      
      // CRC results
      crcValidation: crcResult,
      
      // Prediction results
      prediction: prediction,
      predictionAnomaly: _predictor.detectPredictionAnomaly(),
      
      // Performance metrics
      bufferStats: _buffer.getPerformanceStats(),
      
      // AI insights
      correlationInsights: correlationInsights,
      overallHealthScore: _calculateOverallHealthScore(),
    );
  }
  
  /// Отримує multi-step прогнози
  List<predictor.PredictionResult> getMultiStepPredictions({int steps = 10}) {
    return _predictor.predictMultipleSteps(steps);
  }
  
  /// Отримує historical trends для charts
  AnalyticsTrends getAnalyticsTrends() {
    return AnalyticsTrends(
      rawErrorRates: _kalmanAnalyzer.rawHistory,
      smoothedErrorRates: _kalmanAnalyzer.smoothHistory,
      anomalyScores: _getAnomalyHistory(),
      predictions: _predictor.predictionHistory,
      bufferFillHistory: _getBufferFillHistory(),
    );
  }
  
  /// Session summary для Analytics Extension
  SessionSummary getSessionSummary() {
    final duration = _sessionStart != null 
        ? DateTime.now().difference(_sessionStart!)
        : Duration.zero;
    
    return SessionSummary(
      totalFrames: _totalFrames,
      errorFrames: _errorFrames,
      duration: duration,
      avgErrorRate: _totalFrames > 0 ? (_errorFrames / _totalFrames) * 100 : 0.0,
      smoothedAvgErrorRate: _kalmanAnalyzer.currentSmoothedRate,
      totalAnomalies: _getAnomalyCount(),
      crcStatistics: _crcValidator.allStatistics,
      predictionAccuracy: _predictor.evaluatePredictionAccuracy(),
      bufferPerformance: _buffer.getPerformanceStats(),
    );
  }
  
  double _calculateCurrentErrorRate() {
    if (_totalFrames == 0) return 0.0;
    return (_errorFrames / _totalFrames) * 100.0;
  }
  
  void _updateAllStatistics(CanFrame frame, double errorRate) {
    _statisticsEngine.updateMetric('error_rate', errorRate);
    _statisticsEngine.updateMetric('frame_rate', 1.0); // Simplified
    _statisticsEngine.updateMetric('dlc_avg', frame.dlc.toDouble());
    
    // Data entropy metric
    if (frame.data.isNotEmpty) {
      final entropy = _calculateDataEntropy(frame.data);
      _statisticsEngine.updateMetric('data_entropy', entropy);
    }
  }
  
  double _calculateDataEntropy(List<int> data) {
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
  
  CorrelationInsights _analyzeCorrelations(
    AnomalyResult anomaly,
    CrcValidationResult crc,
    predictor.PredictionResult prediction
  ) {
    final insights = <String>[];
    
    // Correlation: Anomaly + CRC errors
    if (anomaly.isAnomaly && !crc.isValid) {
      insights.add('🔗 Аномалія корелює з CRC помилкою - можлива data corruption');
    }
    
    // Correlation: Prediction + Anomaly
    if (prediction.alertLevel.index >= 2 && anomaly.isAnomaly) { // medium+ alert
      insights.add('⚠️ Прогноз підтверджується аномальною активністю');
    }
    
    // Performance correlation
    final bufferStats = _buffer.getPerformanceStats();
    if (bufferStats.fillPercentage > 0.8 && anomaly.score > 0.7) {
      insights.add('📊 Висока завантаженість буфера + аномалії = можливий DDoS');
    }
    
    return CorrelationInsights(
      insights: insights,
      confidenceScore: _calculateCorrelationConfidence(anomaly, crc, prediction),
    );
  }
  
  double _calculateCorrelationConfidence(
    AnomalyResult anomaly,
    CrcValidationResult crc,
    predictor.PredictionResult prediction
  ) {
    double confidence = 0.5; // Base confidence
    
    if (anomaly.isAnomaly && !crc.isValid) confidence += 0.3;
    if (prediction.confidence > 0.8) confidence += 0.2;
    
    return confidence.clamp(0.0, 1.0);
  }
  
  double _calculateOverallHealthScore() {
    final errorRate = _calculateCurrentErrorRate();
    final anomalyScore = 1.0; // Would track recent anomaly scores
    final predictionAccuracy = _predictor.evaluatePredictionAccuracy();
    
    // Weighted combination
    final healthScore = (
      (100 - errorRate) * 0.4 +           // Lower error rate = better
      (1.0 - anomalyScore) * 100 * 0.3 +  // Lower anomaly = better  
      predictionAccuracy * 100 * 0.3      // Higher accuracy = better
    );
    
    return healthScore.clamp(0.0, 100.0);
  }
  
  List<double> _getAnomalyHistory() {
    // В реальній реалізації тут була б історія
    return List.generate(50, (i) => math.Random().nextDouble() * 0.5);
  }
  
  List<double> _getBufferFillHistory() {
    // В реальній реалізації тут була б історія fill percentage
    return List.generate(50, (i) => math.Random().nextDouble() * 0.8);
  }
  
  int _getAnomalyCount() {
    // В реальній реалізації тут був би лічильник
    return (_totalFrames * 0.05).round(); // ~5% anomalies
  }
}

/// **Результат комплексного аналізу**
class AdvancedAnalysisResult {
  final int frameId;
  final DateTime timestamp;
  
  // Kalman Filter results
  final double rawErrorRate;
  final double smoothedErrorRate;
  final double errorRateStability;
  final bool hasErrorSpike;
  
  // Anomaly Detection results
  final double anomalyScore;
  final bool isAnomaly;
  final AnomalySeverity anomalySeverity;
  final String anomalyExplanation;
  
  // Statistics results
  final StatisticsReport statisticsReport;
  
  // CRC results
  final CrcValidationResult crcValidation;
  
  // Prediction results
  final predictor.PredictionResult prediction;
  final predictor.AnomalyAlert? predictionAnomaly;
  
  // Performance metrics
  final BufferPerformanceStats bufferStats;
  
  // AI insights
  final CorrelationInsights correlationInsights;
  final double overallHealthScore;
  
  AdvancedAnalysisResult({
    required this.frameId,
    required this.timestamp,
    required this.rawErrorRate,
    required this.smoothedErrorRate,
    required this.errorRateStability,
    required this.hasErrorSpike,
    required this.anomalyScore,
    required this.isAnomaly,
    required this.anomalySeverity,
    required this.anomalyExplanation,
    required this.statisticsReport,
    required this.crcValidation,
    required this.prediction,
    this.predictionAnomaly,
    required this.bufferStats,
    required this.correlationInsights,
    required this.overallHealthScore,
  });
}

/// **Analytics trends для візуалізації**
class AnalyticsTrends {
  final List<double> rawErrorRates;
  final List<double> smoothedErrorRates;
  final List<double> anomalyScores;
  final List<double> predictions;
  final List<double> bufferFillHistory;
  
  AnalyticsTrends({
    required this.rawErrorRates,
    required this.smoothedErrorRates,
    required this.anomalyScores,
    required this.predictions,
    required this.bufferFillHistory,
  });
}

/// **Session summary для звітів**
class SessionSummary {
  final int totalFrames;
  final int errorFrames;
  final Duration duration;
  final double avgErrorRate;
  final double smoothedAvgErrorRate;
  final int totalAnomalies;
  final Map<int, CrcStatistics> crcStatistics;
  final double predictionAccuracy;
  final BufferPerformanceStats bufferPerformance;
  
  SessionSummary({
    required this.totalFrames,
    required this.errorFrames,
    required this.duration,
    required this.avgErrorRate,
    required this.smoothedAvgErrorRate,
    required this.totalAnomalies,
    required this.crcStatistics,
    required this.predictionAccuracy,
    required this.bufferPerformance,
  });
}

/// **Correlation insights**
class CorrelationInsights {
  final List<String> insights;
  final double confidenceScore;
  
  CorrelationInsights({
    required this.insights,
    required this.confidenceScore,
  });
}
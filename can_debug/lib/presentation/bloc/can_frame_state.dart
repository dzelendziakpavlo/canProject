import 'package:equatable/equatable.dart';
import '../../domain/models/can_frame.dart';
import '../../domain/detection/can_error_checker.dart';

/// CAN Frame States для BLoC архітектури
abstract class CanFrameState extends Equatable {
  const CanFrameState();

  @override
  List<Object> get props => [];
}

/// Початковий стан моніторингу
class CanFrameInitial extends CanFrameState {
  const CanFrameInitial();
}

/// Стан завантаження/ініціалізації
class CanFrameLoading extends CanFrameState {
  const CanFrameLoading();
}

/// Активний стан моніторингу з даними
class CanFrameMonitoring extends CanFrameState {
  final List<CanFrame> frames;
  final List<CanFrame> recentFrames; // Last 50 frames for UI
  final Map<CanErrorType, int> errorStats;
  final List<double> errorRateHistory; // For charts
  final int totalFrames;
  final int errorFrames;
  final double currentErrorRate;
  final bool isRunning;
  final CanFrame? selectedFrame;
  final DateTime? lastFrameTime;
  
  // Configuration
  final double simulatorErrorRate;
  final int simulatorFrameRate;
  final bool advancedErrorsEnabled;

  const CanFrameMonitoring({
    required this.frames,
    required this.recentFrames,
    required this.errorStats,
    required this.errorRateHistory,
    required this.totalFrames,
    required this.errorFrames,
    required this.currentErrorRate,
    required this.isRunning,
    this.selectedFrame,
    this.lastFrameTime,
    this.simulatorErrorRate = 0.1,
    this.simulatorFrameRate = 100,
    this.advancedErrorsEnabled = true,
  });

  /// Зручний геттер для error rate percentage
  double get errorRatePercentage => totalFrames > 0 ? (errorFrames / totalFrames) * 100 : 0.0;

  /// Зручний геттер для frames per second
  double get framesPerSecond {
    if (frames.length < 2) return 0.0;
    final firstFrame = frames.first;
    final lastFrame = frames.last;
    final duration = lastFrame.timestamp.difference(firstFrame.timestamp);
    if (duration.inMilliseconds == 0) return 0.0;
    return (frames.length / duration.inMilliseconds) * 1000;
  }

  /// Копіювання стану з новими параметрами
  CanFrameMonitoring copyWith({
    List<CanFrame>? frames,
    List<CanFrame>? recentFrames,
    Map<CanErrorType, int>? errorStats,
    List<double>? errorRateHistory,
    int? totalFrames,
    int? errorFrames,
    double? currentErrorRate,
    bool? isRunning,
    CanFrame? selectedFrame,
    DateTime? lastFrameTime,
    double? simulatorErrorRate,
    int? simulatorFrameRate,
    bool? advancedErrorsEnabled,
    bool clearSelectedFrame = false,
  }) {
    return CanFrameMonitoring(
      frames: frames ?? this.frames,
      recentFrames: recentFrames ?? this.recentFrames,
      errorStats: errorStats ?? this.errorStats,
      errorRateHistory: errorRateHistory ?? this.errorRateHistory,
      totalFrames: totalFrames ?? this.totalFrames,
      errorFrames: errorFrames ?? this.errorFrames,
      currentErrorRate: currentErrorRate ?? this.currentErrorRate,
      isRunning: isRunning ?? this.isRunning,
      selectedFrame: clearSelectedFrame ? null : (selectedFrame ?? this.selectedFrame),
      lastFrameTime: lastFrameTime ?? this.lastFrameTime,
      simulatorErrorRate: simulatorErrorRate ?? this.simulatorErrorRate,
      simulatorFrameRate: simulatorFrameRate ?? this.simulatorFrameRate,
      advancedErrorsEnabled: advancedErrorsEnabled ?? this.advancedErrorsEnabled,
    );
  }

  @override
  List<Object> get props => [
    frames,
    recentFrames,
    errorStats,
    errorRateHistory,
    totalFrames,
    errorFrames,
    currentErrorRate,
    isRunning,
    selectedFrame ?? '',
    lastFrameTime ?? DateTime.now(),
    simulatorErrorRate,
    simulatorFrameRate,
    advancedErrorsEnabled,
  ];
}

/// Стан зупинки моніторингу
class CanFrameStopped extends CanFrameState {
  final List<CanFrame> frames;
  final Map<CanErrorType, int> errorStats;
  final int totalFrames;
  final int errorFrames;

  const CanFrameStopped({
    required this.frames,
    required this.errorStats,
    required this.totalFrames,
    required this.errorFrames,
  });

  @override
  List<Object> get props => [frames, errorStats, totalFrames, errorFrames];
}

/// Стан помилки
class CanFrameError extends CanFrameState {
  final String message;
  final dynamic error;

  const CanFrameError({
    required this.message,
    this.error,
  });

  @override
  List<Object> get props => [message, error ?? ''];
}

/// Стан експорту даних
class CanFrameExporting extends CanFrameState {
  final String format;
  final double progress; // 0.0 to 1.0

  const CanFrameExporting({
    required this.format,
    required this.progress,
  });

  @override
  List<Object> get props => [format, progress];
}

/// Стан успішного експорту
class CanFrameExported extends CanFrameState {
  final String filePath;
  final String format;
  final int recordsExported;

  const CanFrameExported({
    required this.filePath,
    required this.format,
    required this.recordsExported,
  });

  @override
  List<Object> get props => [filePath, format, recordsExported];
}
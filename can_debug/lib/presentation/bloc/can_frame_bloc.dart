import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/models/can_frame.dart';
import '../../domain/simulator/can_frame_simulator.dart';
import '../../domain/detection/can_error_checker.dart';
import 'can_frame_event.dart';
import 'can_frame_state.dart';

/// CAN Frame BLoC для управління станом моніторингу
class CanFrameBloc extends Bloc<CanFrameEvent, CanFrameState> {
  final CanFrameSimulator _simulator;
  final CanErrorChecker _errorChecker;
  StreamSubscription<CanFrame>? _frameSubscription;
  Timer? _statisticsTimer;

  // Internal state
  final List<CanFrame> _allFrames = [];
  final Map<CanErrorType, int> _errorStats = {
    for (var type in CanErrorType.values) type: 0
  };
  final List<double> _errorRateHistory = [];
  static const int _maxHistorySize = 100;
  static const int _maxRecentFrames = 50;

  CanFrameBloc({
    CanFrameSimulator? simulator,
    CanErrorChecker? errorChecker,
  })  : _simulator = simulator ?? CanFrameSimulator(),
        _errorChecker = errorChecker ?? CanErrorChecker(),
        super(const CanFrameInitial()) {
    
    // Register event handlers
    on<StartMonitoring>(_onStartMonitoring);
    on<StopMonitoring>(_onStopMonitoring);
    on<ResetMonitoring>(_onResetMonitoring);
    on<FrameReceived>(_onFrameReceived);
    on<UpdateSimulatorConfig>(_onUpdateSimulatorConfig);
    on<GenerateCustomFrame>(_onGenerateCustomFrame);
    on<SelectFrame>(_onSelectFrame);
    on<ExportStatistics>(_onExportStatistics);
  }

  /// Обробка початку моніторингу
  Future<void> _onStartMonitoring(
    StartMonitoring event,
    Emitter<CanFrameState> emit,
  ) async {
    try {
      emit(const CanFrameLoading());

      // Start simulator
      _simulator.start();

      // Subscribe to frames
      _frameSubscription = _simulator.frameStream.listen(
        (frame) => add(FrameReceived(frame)),
        onError: (error) => add(const StopMonitoring()),
      );

      // Start periodic statistics update
      _statisticsTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _updateStatistics(emit),
      );

      emit(CanFrameMonitoring(
        frames: List.from(_allFrames),
        recentFrames: _getRecentFrames(),
        errorStats: Map.from(_errorStats),
        errorRateHistory: List.from(_errorRateHistory),
        totalFrames: _allFrames.length,
        errorFrames: _getErrorFrameCount(),
        currentErrorRate: _calculateCurrentErrorRate(),
        isRunning: true,
        lastFrameTime: _allFrames.isNotEmpty ? _allFrames.last.timestamp : null,
      ));
    } catch (error) {
      emit(CanFrameError(
        message: 'Failed to start monitoring: ${error.toString()}',
        error: error,
      ));
    }
  }

  /// Обробка зупинки моніторингу
  Future<void> _onStopMonitoring(
    StopMonitoring event,
    Emitter<CanFrameState> emit,
  ) async {
    try {
      // Stop simulator
      _simulator.stop();

      // Cancel subscriptions
      await _frameSubscription?.cancel();
      _frameSubscription = null;

      // Stop timers
      _statisticsTimer?.cancel();
      _statisticsTimer = null;

      emit(CanFrameStopped(
        frames: List.from(_allFrames),
        errorStats: Map.from(_errorStats),
        totalFrames: _allFrames.length,
        errorFrames: _getErrorFrameCount(),
      ));
    } catch (error) {
      emit(CanFrameError(
        message: 'Failed to stop monitoring: ${error.toString()}',
        error: error,
      ));
    }
  }

  /// Обробка скидання моніторингу
  Future<void> _onResetMonitoring(
    ResetMonitoring event,
    Emitter<CanFrameState> emit,
  ) async {
    try {
      // Stop everything first
      _simulator.stop();
      await _frameSubscription?.cancel();
      _frameSubscription = null;
      _statisticsTimer?.cancel();
      _statisticsTimer = null;

      // Clear all data
      _allFrames.clear();
      _errorStats.updateAll((key, value) => 0);
      _errorRateHistory.clear();

      emit(const CanFrameInitial());
    } catch (error) {
      emit(CanFrameError(
        message: 'Failed to reset monitoring: ${error.toString()}',
        error: error,
      ));
    }
  }

  /// Обробка нового frame
  Future<void> _onFrameReceived(
    FrameReceived event,
    Emitter<CanFrameState> emit,
  ) async {
    try {
      final frame = event.frame;
      
      // Add frame to collection
      _allFrames.add(frame);

      // Update error statistics
      if (frame.errors.isNotEmpty) {
        for (final error in frame.errors) {
          if (error is CanErrorInfo) {
            _errorStats[error.type] = (_errorStats[error.type] ?? 0) + 1;
          }
        }
      }

      // Emit updated state if currently monitoring
      if (state is CanFrameMonitoring) {
        final currentState = state as CanFrameMonitoring;
        emit(currentState.copyWith(
          frames: List.from(_allFrames),
          recentFrames: _getRecentFrames(),
          errorStats: Map.from(_errorStats),
          totalFrames: _allFrames.length,
          errorFrames: _getErrorFrameCount(),
          currentErrorRate: _calculateCurrentErrorRate(),
          lastFrameTime: frame.timestamp,
        ));
      }
    } catch (error) {
      emit(CanFrameError(
        message: 'Failed to process frame: ${error.toString()}',
        error: error,
      ));
    }
  }

  /// Обробка оновлення конфігурації симулятора
  Future<void> _onUpdateSimulatorConfig(
    UpdateSimulatorConfig event,
    Emitter<CanFrameState> emit,
  ) async {
    try {
      // Update error checker configuration
      if (event.errorRate != null) {
        // Update error rates in error checker (if supported)
        // This would require adding configuration methods to CanErrorChecker
      }
      if (state is CanFrameMonitoring) {
        final currentState = state as CanFrameMonitoring;
        emit(currentState.copyWith(
          simulatorErrorRate: event.errorRate ?? currentState.simulatorErrorRate,
          simulatorFrameRate: event.frameRate ?? currentState.simulatorFrameRate,
          advancedErrorsEnabled: event.enableAdvancedErrors ?? currentState.advancedErrorsEnabled,
        ));
      }
    } catch (error) {
      emit(CanFrameError(
        message: 'Failed to update configuration: ${error.toString()}',
        error: error,
      ));
    }
  }

  /// Обробка генерації custom frame
  Future<void> _onGenerateCustomFrame(
    GenerateCustomFrame event,
    Emitter<CanFrameState> emit,
  ) async {
    try {
      _simulator.generateCustomFrame(
        id: event.id,
        dlc: event.dlc,
        data: event.data,
        isCorrupted: event.isCorrupted,
      );
    } catch (error) {
      emit(CanFrameError(
        message: 'Failed to generate custom frame: ${error.toString()}',
        error: error,
      ));
    }
  }

  /// Обробка вибору frame
  Future<void> _onSelectFrame(
    SelectFrame event,
    Emitter<CanFrameState> emit,
  ) async {
    if (state is CanFrameMonitoring) {
      final currentState = state as CanFrameMonitoring;
      emit(currentState.copyWith(
        selectedFrame: event.frame,
        clearSelectedFrame: event.frame == null,
      ));
    }
  }

  /// Обробка експорту статистики
  Future<void> _onExportStatistics(
    ExportStatistics event,
    Emitter<CanFrameState> emit,
  ) async {
    try {
      emit(CanFrameExporting(format: event.format, progress: 0.0));

      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'can_statistics_$timestamp.${event.format}';
      final filePath = '${directory.path}/$fileName';

      String content;
      switch (event.format.toLowerCase()) {
        case 'json':
          content = _exportToJson();
          break;
        case 'csv':
          content = _exportToCsv();
          break;
        default:
          throw Exception('Unsupported export format: ${event.format}');
      }

      emit(CanFrameExporting(format: event.format, progress: 0.5));

      final file = File(filePath);
      await file.writeAsString(content);

      emit(CanFrameExporting(format: event.format, progress: 1.0));

      emit(CanFrameExported(
        filePath: filePath,
        format: event.format,
        recordsExported: _allFrames.length,
      ));
    } catch (error) {
      emit(CanFrameError(
        message: 'Failed to export statistics: ${error.toString()}',
        error: error,
      ));
    }
  }

  /// Оновлення статистики
  void _updateStatistics(Emitter<CanFrameState> emit) {
    if (state is CanFrameMonitoring) {
      final currentErrorRate = _calculateCurrentErrorRate();
      
      // Add to history
      _errorRateHistory.add(currentErrorRate);
      if (_errorRateHistory.length > _maxHistorySize) {
        _errorRateHistory.removeAt(0);
      }

      final currentState = state as CanFrameMonitoring;
      emit(currentState.copyWith(
        errorRateHistory: List.from(_errorRateHistory),
        currentErrorRate: currentErrorRate,
      ));
    }
  }

  /// Отримати останні frames для UI
  List<CanFrame> _getRecentFrames() {
    final startIndex = _allFrames.length > _maxRecentFrames 
        ? _allFrames.length - _maxRecentFrames 
        : 0;
    return _allFrames.sublist(startIndex);
  }

  /// Підрахувати кількість frames з помилками
  int _getErrorFrameCount() {
    return _allFrames.where((frame) => 
      frame.isCorrupted || frame.errors.isNotEmpty).length;
  }

  /// Розрахувати поточний error rate
  double _calculateCurrentErrorRate() {
    if (_allFrames.isEmpty) return 0.0;
    return (_getErrorFrameCount() / _allFrames.length) * 100;
  }

  /// Експорт у JSON формат
  String _exportToJson() {
    final data = {
      'timestamp': DateTime.now().toIso8601String(),
      'totalFrames': _allFrames.length,
      'errorFrames': _getErrorFrameCount(),
      'errorRate': _calculateCurrentErrorRate(),
      'errorStats': _errorStats.map((key, value) => MapEntry(key.toString(), value)),
      'frames': _allFrames.map((frame) => {
        'id': '0x${frame.id.toRadixString(16).toUpperCase()}',
        'dlc': frame.dlc,
        'data': frame.dataHex,
        'crc': '0x${frame.crc.toRadixString(16).toUpperCase()}',
        'timestamp': frame.timestamp.toIso8601String(),
        'isCorrupted': frame.isCorrupted,
        'errors': frame.errors.map((e) => e.toString()).toList(),
      }).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// Експорт у CSV формат
  String _exportToCsv() {
    final buffer = StringBuffer();
    buffer.writeln('ID,DLC,Data,CRC,Timestamp,IsCorrupted,ErrorCount');
    
    for (final frame in _allFrames) {
      buffer.writeln([
        '0x${frame.id.toRadixString(16).toUpperCase()}',
        frame.dlc,
        '"${frame.dataHex}"',
        '0x${frame.crc.toRadixString(16).toUpperCase()}',
        frame.timestamp.toIso8601String(),
        frame.isCorrupted,
        frame.errors.length,
      ].join(','));
    }
    
    return buffer.toString();
  }

  @override
  Future<void> close() async {
    await _frameSubscription?.cancel();
    _statisticsTimer?.cancel();
    _simulator.dispose();
    return super.close();
  }
}
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../domain/models/can_frame.dart';
import '../../domain/models/can_stats.dart';
import '../../domain/models/can_session.dart';
import '../../domain/models/can_session_event.dart';
import '../../domain/source/can_frame_source.dart';
import '../../domain/source/serial_can_source.dart';
import '../../domain/source/ble_can_source.dart';
import '../../domain/services/telemetry_diagnostics.dart';
import '../../domain/services/recorded_frame_errors.dart';
import '../../domain/simulator/can_frame_simulator.dart';
import '../../domain/detection/can_error_checker.dart';
import '../../domain/detection/can_health_analyzer.dart';
import '../../domain/detection/can_anomaly_analyzer.dart';
import '../../domain/services/can_session_service.dart';
import '../../core/theme.dart';
import '../../core/windows_capture_guard.dart';
import '../widgets/animated_widgets.dart';
import '../widgets/can_bus_diagnostics_panel.dart';

/// Monitor screen that displays live CAN frame data
class MonitorScreen extends StatefulWidget {
  final CanFrameSource? source;
  final DateTime Function()? diagnosticsClock;
  const MonitorScreen({super.key, this.source, this.diagnosticsClock});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen>
    with WidgetsBindingObserver {
  late final TelemetryDiagnostics _telemetryDiagnostics;
  bool get _isHardware => _source.statsStream != null;
  DateTime get _diagnosticsNow =>
      (widget.diagnosticsClock ?? DateTime.now)().toUtc();
  bool _accepting = false;
  bool _transitioning = false;
  Future<void>? _stopFuture;
  late CanFrameSource _source;
  SerialCanSource? get _serial =>
      _source is SerialCanSource ? _source as SerialCanSource : null;
  int _uiDroppedFrames = 0;
  WindowsCaptureGuard? _windowGuard;
  late StreamSubscription<CanFrame> _subscription;
  final CanErrorChecker _errorChecker = CanErrorChecker();
  final CanHealthAnalyzer _healthAnalyzer = CanHealthAnalyzer();
  final CanAnomalyAnalyzer _anomalyAnalyzer = const CanAnomalyAnalyzer();
  final CanSessionService _sessionService = CanSessionService.instance;

  final List<CanFrame> _frames = [];
  final int _maxFramesToShow = 100; // Limit displayed frames for performance

  int _totalFrames = 0;
  int _errorFrames = 0;

  // Detailed error statistics
  final Map<CanErrorType, int> _errorStats = {
    for (var type in CanErrorType.values) type: 0,
  };

  // Error rate history for live chart
  final List<double> _errorRateHistory = [];
  final int _maxHistoryPoints = 50; // Keep last 50 data points

  bool _isRunning = false;

  // BLE connection state (null for simulator)
  SourceState? _sourceState;
  StreamSubscription<SourceState>? _stateSub;

  // Phase 5: frame batching — decouples CAN bus rate from UI render rate
  final List<CanFrame> _pendingFrames = [];
  final List<DateTime> _recentFrameTimes = [];
  Timer? _uiTimer;

  // Phase 5: TWAI hardware stats (null for simulator)
  CanStats? _latestStats;
  StreamSubscription<CanStats>? _statsStreamSub;

  DateTime? _lastFrameAt;
  double _framesPerSecond = 0.0;
  int _reconnectCount = 0;
  CanHealthReport _healthReport = const CanHealthReport(
    score: 100,
    severity: SessionSeverity.normal,
    findings: [],
  );
  List<CanAnomaly> _anomalies = const [];
  bool _busIsSilent = false;

  void _recordDiagnostics(Iterable<CanSessionEvent> events) {
    for (final event in events) {
      _sessionService.recordSessionEvent(event);
    }
  }

  void _refreshDiagnostics() {
    if (!_isHardware) return;
    _recordDiagnostics(_telemetryDiagnostics.poll(sourceName: _source.name));
    final current = _telemetryDiagnostics.snapshot;
    _latestStats = current.stats;
    _busIsSilent = current.traffic == CanTrafficState.silent;
  }

  void _recordSourceEvent({
    required CanSessionEventType type,
    required String message,
    Map<String, dynamic> data = const {},
  }) {
    _sessionService.recordSessionEvent(
      CanSessionEvent.create(
        type: type,
        message: message,
        sourceName: _source.name,
        data: {
          'sourceName': _source.name,
          'sourceState': _sourceState?.name,
          'monitorMode': _source.statsStream != null ? 'hardware' : 'simulator',
          ...data,
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _source = widget.source ?? CanFrameSimulator();
    _telemetryDiagnostics = TelemetryDiagnostics(clock: () => _diagnosticsNow);
    _sourceState = _serial?.state;
    if (_serial != null) {
      _windowGuard = WindowsCaptureGuard(() async {
        if (_isRunning) {
          await _stopSimulation();
        } else {
          await _source.stop();
        }
      });
      unawaited(_windowGuard!.enable());
    }
    _stateSub = _source.stateStream.listen((s) {
      final previousState = _sourceState;
      if (s == previousState) return;
      if (s == SourceState.reconnecting) _reconnectCount++;
      if (_isHardware) {
        _recordDiagnostics(
          _telemetryDiagnostics.updateSourceState(s, sourceName: _source.name),
        );
        _refreshDiagnostics();
      }
      if (mounted) setState(() => _sourceState = s);
      _recordSourceEvent(
        type: CanSessionEventType.sourceStateChanged,
        message: 'Source state changed to $s',
        data: {
          'previousState': previousState?.name,
          'newState': s.name,
          'isStreaming': s == SourceState.streaming,
          'isDisconnected': s == SourceState.disconnected,
          'reconnectCount': _reconnectCount,
        },
      );
    });
    _statsStreamSub = _source.statsStream?.listen((stats) {
      if (!_accepting) return;
      _sessionService.recordStatsSnapshot(stats);
      _recordSourceEvent(
        type: CanSessionEventType.statsSnapshot,
        message: 'TWAI stats snapshot received',
        data: {
          'rxTotal': stats.rxTotal,
          'txErrorCounter': stats.txErrorCounter,
          'rxErrorCounter': stats.rxErrorCounter,
          'busState': stats.busState,
          'rxMissed': stats.rxMissed,
          'busErrorCount': stats.busErrorCount,
          'arbLostCount': stats.hasWireCounter('arb')
              ? stats.arbLostCount
              : null,
          'txFailedCount': stats.hasWireCounter('txfail')
              ? stats.txFailedCount
              : null,
          'rxOverrunCount': stats.hasWireCounter('ovr')
              ? stats.rxOverrunCount
              : null,
          'isErrorPassive': stats.isErrorPassive,
          'isErrorWarning': stats.isErrorWarning,
          'isBusOff': stats.isBusOff,
          'isRecovering': stats.isRecovering,
          'isNoAckMode': stats.isNoAckMode,
          'isSpeedMismatchDemo': stats.isSpeedMismatchDemo,
          'telemetrySchema': stats.telemetrySchema,
          'nodeName': stats.nodeName,
          'firmwareVersion': stats.firmwareVersion,
          'uptimeMs': stats.uptimeMs,
          'bitrate': stats.bitrate,
          'reasonCode': stats.reasonCode,
        },
      );
      final previous = _latestStats;
      final countersReset =
          previous != null &&
          (stats.rxTotal < previous.rxTotal ||
              stats.busErrorCount < previous.busErrorCount ||
              (stats.uptimeMs != null &&
                  previous.uptimeMs != null &&
                  stats.uptimeMs! < previous.uptimeMs!));
      final prev = countersReset ? null : previous;

      // TWAI deltas since last stats packet (arrives every ~1 s from ESP32)
      final errorDelta =
          stats.busErrorCount - (prev?.busErrorCount ?? stats.busErrorCount);
      final rxDelta = stats.rxTotal - (prev?.rxTotal ?? stats.rxTotal);
      if (prev != null) {
        final total = errorDelta + rxDelta;
        _errorRateHistory.add(
          (total > 0 ? errorDelta / total * 100.0 : 0.0).clamp(0.0, 100.0),
        );
        if (_errorRateHistory.length > _maxHistoryPoints) {
          _errorRateHistory.removeAt(0);
        }
      }
      _recordDiagnostics(
        _telemetryDiagnostics.accept(stats, sourceName: _source.name),
      );
      _refreshDiagnostics();
      setState(() {});
      _updateHealthReport();
      _updateAnomalyReport();
    });
    _setupFrameListener();
    _startSimulation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Cancel listeners before stop(): a source may emit its final state synchronously.
    _stateSub?.cancel();
    _statsStreamSub?.cancel();
    _subscription.cancel();
    if (_accepting) {
      // Route disposal cannot be awaited. Stop radio delivery and checkpoint the
      // accepted tail; an interrupted capture remains recoverable on next launch.
      _accepting = false;
      unawaited(
        _source.stop().then((_) => _sessionService.checkpoint()).catchError((
          Object e,
        ) {
          debugPrint('Capture checkpoint failed: $e');
        }),
      );
    }
    _windowGuard?.dispose();
    _uiTimer?.cancel();
    _source.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _accepting) {
      unawaited(
        _sessionService.checkpoint().catchError(
          (Object e) => _showPersistenceError(e),
        ),
      );
    }
  }

  void _showPersistenceError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Session storage failed; recording may be incomplete: $error',
        ),
        duration: const Duration(seconds: 10),
      ),
    );
  }

  Future<void> _stopFromUi() async {
    try {
      await _stopSimulation();
    } catch (e) {
      _showPersistenceError(e);
    }
  }

  /// Subscribe to frame stream — frames go into a buffer, not directly into setState.
  /// The UI timer flushes the buffer at 20 fps, keeping the render thread smooth
  /// even when the ESP32 sends 200+ frames/s on a loaded CAN bus.
  void _setupFrameListener() {
    _subscription = _source.frameStream.listen((frame) {
      if (!_accepting) return;
      _sessionService.recordAcceptedFrame(frame);
      _lastFrameAt = DateTime.now();
      if (_isHardware) {
        _recordDiagnostics(
          _telemetryDiagnostics.frameReceived(sourceName: _source.name),
        );
        _refreshDiagnostics();
      }
      // The independent experiment journal already received this frame.
      // Bound display backlog even if rendering temporarily stalls.
      if (_pendingFrames.length >= 4096) {
        _uiDroppedFrames++;
        return;
      }
      _pendingFrames.add(frame);
    });
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _flushPending(),
    );
  }

  /// Drain the pending-frames buffer in a single setState (one render per 50 ms).
  void _flushPending() {
    if (!mounted) return;

    if (_sessionService.persistenceError != null &&
        _accepting &&
        _stopFuture == null) {
      _showPersistenceError(_sessionService.persistenceError!);
      unawaited(_stopFromUi());
    }
    final now = DateTime.now();
    _recentFrameTimes.removeWhere(
      (timestamp) => now.difference(timestamp) > const Duration(seconds: 1),
    );
    final nextFps = _recentFrameTimes.length.toDouble();

    _refreshDiagnostics();

    if (_pendingFrames.isEmpty) {
      if (_framesPerSecond != nextFps) {
        setState(() => _framesPerSecond = nextFps);
      }
      _updateHealthReport();
      _updateAnomalyReport();
      return;
    }
    final batch = List<CanFrame>.of(_pendingFrames);
    _pendingFrames.clear();

    final prevTotal = _totalFrames;

    _recentFrameTimes.addAll(batch.map((frame) => frame.timestamp));
    _recentFrameTimes.removeWhere(
      (timestamp) => now.difference(timestamp) > const Duration(seconds: 1),
    );
    _framesPerSecond = _recentFrameTimes.length.toDouble();

    setState(() {
      for (final frame in batch) {
        _totalFrames++;

        final storedErrors = _getStoredErrors(frame);
        final hasAnyError = frame.isCorrupted || storedErrors.isNotEmpty;
        if (hasAnyError) _errorFrames++;

        if (hasAnyError) {
          _recordSourceEvent(
            type: CanSessionEventType.errorDetected,
            message:
                'Error detected in frame 0x${frame.id.toRadixString(16).toUpperCase()}',
            data: {
              'frameId': frame.id,
              'frameHexId': frame.idHex,
              'status': frame.status,
              'timestamp': frame.timestamp.toIso8601String(),
              'corrupted': frame.isCorrupted,
              'isRtr': frame.isRtr,
              'isExtended': frame.isExtended,
              'dataLength': frame.dlc,
              'dataHex': frame.dataHex,
              'errorTypes': storedErrors
                  .map((error) => error.type.name)
                  .toList(),
              'errorOrigins': storedErrors
                  .map((error) => error.origin.name)
                  .toList(),
              'errorDescriptions': storedErrors
                  .map((error) => error.description)
                  .toList(),
              'errorSeverities': storedErrors
                  .map((error) => error.severity)
                  .toList(),
              'maxSeverity': storedErrors.isNotEmpty
                  ? storedErrors
                        .map((error) => error.severity)
                        .reduce((a, b) => a > b ? a : b)
                  : (frame.isCorrupted ? 3 : 0),
            },
          );
        }

        for (final error in storedErrors) {
          _errorStats[error.type] = (_errorStats[error.type] ?? 0) + 1;
        }

        _frames.insert(0, frame);
      }

      if (_frames.length > _maxFramesToShow) {
        _frames.removeRange(_maxFramesToShow, _frames.length);
      }

      // Chart: simulator mode only — hardware mode feeds chart from TWAI stats delta
      if (_source.statsStream == null && _totalFrames > 0) {
        final rate = (_errorFrames / _totalFrames) * 100;
        _errorRateHistory.add(rate);
        if (_errorRateHistory.length > _maxHistoryPoints) {
          _errorRateHistory.removeAt(0);
        }
      }
    });

    // Session update every 50 frames (was every 10, but batching makes finer
    // granularity irrelevant — 50 frames ≈ 2.5 s at simulator rate)
    if (_totalFrames > 0 && _totalFrames ~/ 50 != prevTotal ~/ 50) {
      _sessionService.updateCurrentSession(
        frames: _frames,
        errorStats: _errorStats,
        totalFrames: _totalFrames,
        errorFrames: _errorFrames,
        errorRate: _errorRate,
      );
    }

    _recordSourceEvent(
      type: CanSessionEventType.frameBatch,
      message:
          'Processed frame batch of ${batch.length} frames from ${_source.name}',
      data: {
        'batchSize': batch.length,
        'totalFrames': _totalFrames,
        'errorFrames': _errorFrames,
        'batchErrorFrames': batch
            .where(
              (frame) =>
                  frame.isCorrupted || _getStoredErrors(frame).isNotEmpty,
            )
            .length,
        'sourceState': _sourceState?.name,
        'batchStartTimestamp': batch.isNotEmpty
            ? batch.first.timestamp.toIso8601String()
            : null,
        'batchEndTimestamp': batch.isNotEmpty
            ? batch.last.timestamp.toIso8601String()
            : null,
        'containsCorruptedFrames': batch.any((frame) => frame.isCorrupted),
        'containsAnalyzedErrors': batch.any(
          (frame) => _getStoredErrors(frame).isNotEmpty,
        ),
      },
    );
    _updateHealthReport();
    _updateAnomalyReport();
  }

  void _updateHealthReport() {
    final report = _healthAnalyzer.analyze(
      latestStats: _latestStats,
      errorRate: _errorRate,
      errorDetectedEvents: _errorFrames,
      reconnectCount: _reconnectCount,
      busIsSilent: _busIsSilent,
      transport: _serial != null ? 'usbSerial' : 'ble',
      rxOverflowActive: _isHardware
          ? _telemetryDiagnostics.snapshot.rxOverflowActive
          : null,
    );
    _recordNewHealthFindings(report);
    if (mounted &&
        (report.score != _healthReport.score ||
            report.severity != _healthReport.severity ||
            report.findings.length != _healthReport.findings.length)) {
      setState(() => _healthReport = report);
    } else {
      _healthReport = report;
    }
  }

  void _recordNewHealthFindings(CanHealthReport report) {
    final previousTitles = _healthReport.findings
        .map((finding) => finding.title)
        .toSet();
    for (final finding in report.findings) {
      if (previousTitles.contains(finding.title)) continue;
      if (_isHardware &&
          const {
            'Silent CAN bus',
            'Bus-off',
            'Bus recovery in progress',
            'Error passive',
            'Error warning',
            'RX overflow',
          }.contains(finding.title)) {
        continue; // Recorded by the shared diagnostics lifecycle.
      }

      _sessionService.recordSessionEvent(
        CanSessionEvent.create(
          type: CanSessionEventType.diagnostic,
          message: finding.title,
          sourceName: _source.name,
          diagnosticSeverity: _diagnosticSeverityFor(finding.severity),
          diagnosticCause: _diagnosticCauseFor(finding.title),
          explanation: finding.explanation,
          recommendation: finding.recommendation,
          data: {
            'healthScore': report.score,
            'sourceState': _sourceState?.name,
            'reconnectCount': _reconnectCount,
          },
        ),
      );
    }
  }

  void _updateAnomalyReport() {
    final session = _sessionService.currentSession;
    final anomalies = _anomalyAnalyzer.analyze(
      frames: _frames,
      statsSnapshots: session?.statsSnapshots ?? const [],
      events: session?.events ?? const [],
      transport: _serial != null ? 'usbSerial' : 'ble',
    );
    final previousTitles = _anomalies.map((anomaly) => anomaly.title).toSet();
    for (final anomaly in anomalies) {
      if (previousTitles.contains(anomaly.title)) continue;
      if (_isHardware && anomaly.type == CanAnomalyType.silentPeriod) continue;
      _sessionService.recordSessionEvent(
        CanSessionEvent.create(
          type: CanSessionEventType.diagnostic,
          message: anomaly.title,
          sourceName: _source.name,
          diagnosticSeverity: _diagnosticSeverityFor(anomaly.severity),
          diagnosticCause: _diagnosticCauseForAnomaly(anomaly.type),
          explanation: anomaly.explanation,
          recommendation: anomaly.recommendation,
          data: {
            'confidence': anomaly.confidence,
            'anomalyType': anomaly.type.name,
            'sourceState': _sourceState?.name,
          },
        ),
      );
    }
    if (mounted) setState(() => _anomalies = anomalies);
  }

  DiagnosticCause _diagnosticCauseForAnomaly(CanAnomalyType type) {
    switch (type) {
      case CanAnomalyType.packetLoss:
        return DiagnosticCause.rxOverflow;
      case CanAnomalyType.arbitrationLost:
        return DiagnosticCause.arbitrationLost;
      case CanAnomalyType.silentPeriod:
        return DiagnosticCause.silentBus;
      case CanAnomalyType.reconnectStorm:
        return _serial != null
            ? DiagnosticCause.transportLoss
            : DiagnosticCause.bleLoss;
      case CanAnomalyType.counterSpike:
      case CanAnomalyType.repeatedError:
      case CanAnomalyType.burstTraffic:
      case CanAnomalyType.unstableRecovery:
        return DiagnosticCause.unknown;
    }
  }

  DiagnosticSeverity _diagnosticSeverityFor(SessionSeverity severity) {
    switch (severity) {
      case SessionSeverity.normal:
      case SessionSeverity.low:
        return DiagnosticSeverity.info;
      case SessionSeverity.medium:
        return DiagnosticSeverity.warning;
      case SessionSeverity.high:
        return DiagnosticSeverity.error;
      case SessionSeverity.critical:
        return DiagnosticSeverity.critical;
    }
  }

  DiagnosticCause _diagnosticCauseFor(String title) {
    switch (title) {
      case 'Silent CAN bus':
        return DiagnosticCause.silentBus;
      case 'Bus-off':
      case 'Bus recovery in progress':
        return DiagnosticCause.busOff;
      case 'Error passive':
      case 'Error warning':
      case 'High frame error rate':
        return DiagnosticCause.unknown;
      case 'RX overflow':
        return DiagnosticCause.rxOverflow;
      case 'Reconnect storm':
        return _serial != null
            ? DiagnosticCause.transportLoss
            : DiagnosticCause.bleLoss;
      default:
        return DiagnosticCause.unknown;
    }
  }

  /// Start the CAN frame simulation
  Future<void> _startSimulation() async {
    if (_isRunning || _transitioning || _stopFuture != null) return;
    _transitioning = true;
    try {
      if (_sessionService.currentSession != null) {
        await _sessionService.completeCurrentSession();
      }
      _frames.clear();
      _pendingFrames.clear();
      _totalFrames = 0;
      _errorFrames = 0;
      _errorStats.updateAll((key, value) => 0);
      _telemetryDiagnostics.reset();
      if (_isHardware) {
        _telemetryDiagnostics.updateSourceState(
          _sourceState ?? SourceState.connecting,
          sourceName: _source.name,
        );
      }
      _lastFrameAt = null;
      _latestStats = null;
      _busIsSilent = false;
      setState(() {
        _isRunning = true;
      });

      // Create new session
      await _sessionService.createSession(sourceName: _source.name);
      if (!mounted) {
        await _sessionService.completeCurrentSession();
        return;
      }
      _accepting = true;
      _recordSourceEvent(
        type: CanSessionEventType.sourceStarted,
        message: 'Monitoring started from ${_source.name}',
        data: {
          'frameBufferLimit': _maxFramesToShow,
          'historyLimit': _maxHistoryPoints,
        },
      );
      await _source.start();
      if (!mounted) return;
      if (_serial != null) {
        setState(() => _sourceState = _serial!.state);
        _recordSourceEvent(
          type: CanSessionEventType.note,
          message: 'USB Serial experimental capture',
          data: {..._serial!.connectionMetadata, 'monitorMode': 'hardware'},
        );
      }
    } catch (e) {
      _accepting = false;
      if (mounted) setState(() => _isRunning = false);
      _showPersistenceError(e);
    } finally {
      _transitioning = false;
    }
  }

  /// Stop the source, then drain and await storage before reporting completion.
  Future<void> _stopSimulation() =>
      _stopFuture ??= _finishCapture().whenComplete(() => _stopFuture = null);
  Future<void> _finishCapture() async {
    if (mounted) {
      setState(() {
        _isRunning = false;
      });
    }
    await _source.stop();
    // StreamController broadcasts queued before stop are delivered before sealing.
    await Future<void>.value();
    _accepting = false;
    _flushPending();
    if (_source is BleCanSource) {
      _sessionService.updateCaptureMetadata(
        (_source as BleCanSource).receptionDiagnostics,
      );
    }
    _recordSourceEvent(
      type: CanSessionEventType.sourceStopped,
      message: 'Monitoring stopped for ${_source.name}',
      data: {
        'totalFrames': _totalFrames,
        'errorFrames': _errorFrames,
        'errorRate': _errorRate,
        'recentFramesStored': _frames.length,
        'lastFrameTime': _lastFrameAt?.toIso8601String(),
        'framesPerSecond': _framesPerSecond,
        'lastFrameAgeMs': _lastFrameAt == null
            ? null
            : DateTime.now().difference(_lastFrameAt!).inMilliseconds,
        'reconnectCount': _reconnectCount,
        if (_serial != null) ..._serial!.connectionMetadata,
        'uiDroppedFrames': _uiDroppedFrames,
      },
    );

    // Save current session
    _sessionService.updateCurrentSession(
      sourceName: _source.name,
      frames: _frames,
      errorStats: _errorStats,
      totalFrames: _totalFrames,
      errorFrames: _errorFrames,
      errorRate: _errorRate,
    );
    await _sessionService.completeCurrentSession();
  }

  /// Reset all counters and clear frames
  void _resetSimulation() async {
    if (_isRunning || _sessionService.currentSession != null) {
      try {
        await _stopSimulation();
      } catch (e) {
        _showPersistenceError(e);
        return;
      }
    }
    _uiTimer?.cancel();
    _pendingFrames.clear();
    await _subscription.cancel();
    await _source.stop();
    _setupFrameListener();

    setState(() {
      _frames.clear();
      _totalFrames = 0;
      _errorFrames = 0;
      _isRunning = false;
      _telemetryDiagnostics.reset();
      _latestStats = null;
      _busIsSilent = false;

      // Reset error statistics
      for (var type in CanErrorType.values) {
        _errorStats[type] = 0;
      }

      // Clear error rate history
      _errorRateHistory.clear();
      _recentFrameTimes.clear();
      _framesPerSecond = 0.0;
      _reconnectCount = 0;
      _healthReport = const CanHealthReport(
        score: 100,
        severity: SessionSeverity.normal,
        findings: [],
      );
      _anomalies = const [];
    });
  }

  /// Get error rate as percentage
  double get _errorRate {
    return _totalFrames > 0 ? (_errorFrames / _totalFrames) * 100 : 0.0;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!_isRunning) {
          try {
            await _stopSimulation();
          } catch (e) {
            _showPersistenceError(e);
            return;
          }
          if (context.mounted) Navigator.of(context).pop();
          return;
        }

        final choice = await showDialog<String>(
          context: context,
          builder: (context) {
            return AlertDialog(
              backgroundColor: AppTheme.darkSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: AppTheme.primaryOrange.withValues(alpha: 0.3),
                ),
              ),
              title: Text(
                'Monitoring running',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              content: Text(
                'Monitoring is still running. Stop to flush the experimental log and save this session.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop('cancel'),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop('leave'),
                  child: const Text('Leave without saving'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryAmber,
                  ),
                  onPressed: () => Navigator.of(context).pop('stop_save'),
                  child: const Text('Stop & Save'),
                ),
              ],
            );
          },
        );

        if (!context.mounted) return;
        if (choice == 'stop_save') {
          try {
            await _stopSimulation();
          } catch (e) {
            _showPersistenceError(e);
            return;
          }
          if (context.mounted) Navigator.of(context).pop();
        } else if (choice == 'leave') {
          await _source.stop();
          _accepting = false;
          await _sessionService.discardCurrentSession();
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.darkBackground,
        appBar: AppBar(
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.monitor, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              const Flexible(
                child: Text('CAN Monitor', overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          backgroundColor: AppTheme.darkSurface,
          foregroundColor: AppTheme.textPrimary,
          elevation: 0,
          actions: [
            AnimatedIconButton(
              icon: _isRunning
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_filled,
              onPressed: _isRunning ? _stopFromUi : _startSimulation,
              tooltip: _isRunning ? 'Disconnect & Save' : 'Connect / Start',
              color: _isRunning ? AppTheme.primaryAmber : AppTheme.accentGreen,
            ).animate().scale(duration: 200.ms),
            AnimatedIconButton(
              icon: Icons.analytics,
              onPressed: _showDetailedErrorStats,
              tooltip: 'Error Statistics',
              color: AppTheme.primaryOrange,
            ).animate(delay: 100.ms).scale(duration: 200.ms),
            AnimatedIconButton(
              icon: Icons.refresh,
              onPressed: _resetSimulation,
              tooltip: 'Reset',
              color: AppTheme.primaryAmber,
            ).animate(delay: 200.ms).scale(duration: 200.ms),
            const SizedBox(width: 8),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: SizedBox(
              height: _isHardware ? null : constraints.maxHeight,
              child: Column(
                children: [
                  // BLE connection state banner (hidden for simulator)
                  if (_source.statsStream != null) _buildConnectionBanner(),
                  if (_serial != null) _buildSerialStatus(),
                  if (_source is BleCanSource) _buildBleRecordingStatus(),

                  // Statistics Panel
                  _buildStatisticsPanel(),

                  if (_isHardware)
                    CanBusDiagnosticsPanel(
                      snapshot: _telemetryDiagnostics.snapshot,
                      events: _telemetryDiagnostics.recentEvents,
                    ),

                  // Frame List Header
                  _buildFrameListHeader(),

                  // Frame List
                  if (_isHardware)
                    SizedBox(
                      height: constraints.maxHeight.clamp(320.0, 560.0),
                      child: _buildFrameList(),
                    )
                  else
                    Expanded(flex: 2, child: _buildFrameList()),

                  // Live Error Rate Chart
                  Container(
                    height: 140,
                    margin: const EdgeInsets.all(16.0),
                    padding: const EdgeInsets.all(16.0),
                    decoration: BoxDecoration(
                      gradient: AppTheme.backgroundGradient,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppTheme.primaryAmber.withValues(alpha: 0.3),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primaryAmber.withValues(alpha: 0.1),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: _buildErrorRateChart(),
                  ).animate(delay: 1200.ms).fadeIn().slideY(begin: 0.3, end: 0),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Alert banner for hardware bus anomalies: BUS_OFF, RECOVERING, Error Passive, or silent bus.
  Widget _buildBleRecordingStatus() {
    final reception = (_source as BleCanSource).receptionDiagnostics;
    final storage = _sessionService.persistenceDiagnostics;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        'Android RX ${reception['androidAcceptedFrames']} / stats ${reception['androidAcceptedStats']} '
        '? DB ${storage['committedFrames'] ?? 0} ? pending ${storage['pendingRecords'] ?? 0} '
        '? seq gaps ${reception['sequenceGaps']} ? duplicates ${reception['duplicateSequences']} '
        '? rejected ${reception['rejectedMessages']} ? incomplete ${reception['incompleteMessages']}\n'
        'TWAI RX is receiver lifetime; Android RX is this client. BLE enqueue count is unavailable. '
        'Error Frames counts stored frame evidence; chart uses interval TWAI buserr/(buserr+RX), not a measured bit error rate.'
        '${_sessionService.persistenceError == null ? '' : '\nSTORAGE ERROR: ${_sessionService.persistenceError}'}',
        style: TextStyle(
          color: _sessionService.persistenceError == null
              ? AppTheme.textSecondary
              : AppTheme.accentRed,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _buildConnectionBanner() {
    final state = _sourceState;
    if (state == null || state == SourceState.idle) {
      return const SizedBox.shrink();
    }

    final (label, color, showSpinner) = switch (state) {
      SourceState.connecting => (
        'Connecting to ESP32…',
        AppTheme.primaryOrange,
        true,
      ),
      SourceState.scanning => (
        'Scanning for ESP32 CAN Stand…',
        AppTheme.primaryOrange,
        true,
      ),
      SourceState.connected => (
        _serial != null
            ? 'COM port open — waiting for JSON…'
            : 'Connected — subscribing…',
        AppTheme.primaryAmber,
        true,
      ),
      SourceState.streaming => (
        'Streaming from ESP32 CAN Stand',
        AppTheme.accentGreen,
        false,
      ),
      SourceState.reconnecting => (
        'Reconnecting to ESP32…',
        AppTheme.primaryOrange,
        true,
      ),
      SourceState.disconnected => (
        _serial != null
            ? 'USB disconnected — stop, then reconnect'
            : 'Disconnected — reconnecting…',
        AppTheme.accentRed,
        _serial == null,
      ),
      SourceState.lost => ('CAN Stand not found', AppTheme.accentRed, false),
      SourceState.error => (
        _serial != null
            ? 'USB Serial error — manual reconnect'
            : 'Connection error — retrying…',
        AppTheme.accentRed,
        _serial == null,
      ),
      SourceState.idle => ('', AppTheme.textMuted, false),
    };

    if (label.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: color.withValues(alpha: 0.12),
      child: Row(
        children: [
          if (showSpinner)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$label · ${_source.name}',
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// Build the statistics panel at the top
  Widget _buildSerialStatus() {
    final serial = _serial!;
    final stale =
        serial.lastMessageAt != null &&
        DateTime.now().toUtc().difference(serial.lastMessageAt!) >
            const Duration(seconds: 4);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'USB RX ${serial.receivedFrames} · stats ${serial.receivedStats} · bytes ${serial.bytesRead} · reads ${serial.readOperations} · lines ${serial.completedLines} · rejected ${serial.serialParseErrors} · sequence gaps ${serial.sequenceGaps} · UI skipped $_uiDroppedFrames${stale ? ' · telemetry stale' : ''}',
              style: const TextStyle(fontSize: 11),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.description_outlined),
            tooltip: 'Experimental recording details',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Experimental recording'),
                content: SingleChildScrollView(
                  child: SelectableText(
                    'CSV: ${serial.journal?.csvPath ?? 'not opened'}\nJSONL: ${serial.journal?.jsonlPath ?? 'not opened'}\n'
                    'Written: ${serial.journal?.writtenRecords ?? 0}\n'
                    'Read diagnostics: bytesRead=${serial.bytesRead}, readOperations=${serial.readOperations}, readErrors=${serial.readErrors}, completedLines=${serial.completedLines}, decodedFrames=${serial.receivedFrames}, decodedStats=${serial.receivedStats}\n'
                    'Native reader: ${serial.transportDiagnostics}\n'
                    'Serial error: ${serial.lastError ?? 'none'}\nParse error: ${serial.lastParseError ?? 'none'}\n'
                    'Recording error: ${serial.journal?.failure ?? 'none'}\n'
                    'Firmware transport counters: ${serial.firmwareCounters}\n'
                    'The recording includes all received messages independently of the 100-frame display buffer.',
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ),
          if (serial.lastError != null)
            const Tooltip(
              message: 'Open recording details for the error',
              child: Icon(Icons.error_outline, color: AppTheme.accentRed),
            ),
        ],
      ),
    );
  }

  Widget _buildStatisticsPanel() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        gradient: AppTheme.backgroundGradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryOrange.withValues(alpha: 0.1),
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildStatCard(
                    'Total Frames',
                    _totalFrames.toString(),
                    Icons.analytics,
                    AppTheme.primaryAmber,
                  )
                  .animate(delay: 100.ms)
                  .fadeIn()
                  .scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                    'Error Frames',
                    _errorFrames.toString(),
                    Icons.error_outline,
                    AppTheme.accentRed,
                  )
                  .animate(delay: 200.ms)
                  .fadeIn()
                  .scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                    'Error Rate',
                    '${_errorRate.toStringAsFixed(1)}%',
                    Icons.warning_amber,
                    _errorRate > 15
                        ? AppTheme.accentRed
                        : AppTheme.primaryOrange,
                  )
                  .animate(delay: 300.ms)
                  .fadeIn()
                  .scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                    'Status',
                    _isRunning ? 'Running' : 'Stopped',
                    _isRunning
                        ? Icons.play_circle_filled
                        : Icons.pause_circle_filled,
                    _isRunning ? AppTheme.accentGreen : AppTheme.textMuted,
                  )
                  .animate(delay: 400.ms)
                  .fadeIn()
                  .scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                    'Frame Rate',
                    '${_framesPerSecond.toStringAsFixed(1)} /s',
                    Icons.speed,
                    AppTheme.accentGreen,
                  )
                  .animate(delay: 500.ms)
                  .fadeIn()
                  .scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                    'Reconnects',
                    _reconnectCount.toString(),
                    Icons.sync,
                    AppTheme.primaryOrange,
                  )
                  .animate(delay: 600.ms)
                  .fadeIn()
                  .scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                    'Last Frame',
                    _formatFrameAge(),
                    Icons.access_time,
                    AppTheme.primaryAmber,
                  )
                  .animate(delay: 700.ms)
                  .fadeIn()
                  .scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                    'Health',
                    _isHardware && _latestStats == null
                        ? 'N/A'
                        : '${_healthReport.score}/100',
                    Icons.health_and_safety,
                    _healthColor(_healthReport.severity),
                  )
                  .animate(delay: 800.ms)
                  .fadeIn()
                  .scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                    'Anomalies',
                    _anomalies.length.toString(),
                    Icons.insights,
                    _anomalies.isEmpty
                        ? AppTheme.accentGreen
                        : AppTheme.primaryOrange,
                  )
                  .animate(delay: 900.ms)
                  .fadeIn()
                  .scale(begin: const Offset(0.8, 0.8)),
            ],
          ),
        ),
      ),
    );
  }

  String _formatFrameAge() {
    final lastFrame = _lastFrameAt;
    if (lastFrame == null) return 'n/a';
    final age = DateTime.now().difference(lastFrame);
    if (age.inSeconds > 0) return '${age.inSeconds}s ago';
    return '${age.inMilliseconds}ms';
  }

  Color _healthColor(SessionSeverity severity) {
    switch (severity) {
      case SessionSeverity.normal:
        return AppTheme.accentGreen;
      case SessionSeverity.low:
        return AppTheme.primaryAmber;
      case SessionSeverity.medium:
        return AppTheme.primaryOrange;
      case SessionSeverity.high:
      case SessionSeverity.critical:
        return AppTheme.accentRed;
    }
  }

  /// Build individual statistic card
  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return SizedBox(
      width: 85, // Fixed width to prevent overflow
      child: AnimatedCard(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                shape: BoxShape.circle,
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color,
              ),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                fontSize: 9,
                color: AppTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// Build the frame list header
  Widget _buildFrameListHeader() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.darkContainer, AppTheme.darkSurface],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
        border: Border.all(
          color: AppTheme.primaryOrange.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              'ID',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.primaryOrange,
              ),
            ),
          ),
          SizedBox(
            width: 25,
            child: Text(
              'DLC',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.primaryAmber,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Data',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          SizedBox(
            width: 35,
            child: Text(
              'CRC',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.primaryAmber,
              ),
            ),
          ),
          SizedBox(
            width: 50,
            child: Text(
              'Time',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              'Status',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.accentGreen,
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 500.ms).slideY(begin: -0.3, end: 0);
  }

  /// Build the scrollable frame list
  Widget _buildFrameList() {
    if (_frames.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16.0),
        decoration: BoxDecoration(
          color: AppTheme.darkSurface,
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
          border: Border.all(
            color: AppTheme.primaryOrange.withValues(alpha: 0.3),
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: AppTheme.primaryGradient,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isRunning ? Icons.wifi_find : Icons.wifi_off,
                          size: 40,
                          color: AppTheme.textPrimary,
                        ),
                      )
                      .animate(delay: 600.ms)
                      .scale(duration: 600.ms, curve: Curves.elasticOut),
                  const SizedBox(height: 24),
                  Text(
                    _isRunning
                        ? 'Waiting for CAN frames...'
                        : 'Simulation stopped',
                    style: const TextStyle(
                      fontSize: 16,
                      color: AppTheme.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ).animate(delay: 800.ms).fadeIn().slideY(begin: 0.3, end: 0),
                  if (!_isRunning) ...[
                    const SizedBox(height: 24),
                    AnimatedButton(
                          onPressed: _startSimulation,
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.play_arrow),
                              SizedBox(width: 8),
                              Text('Start Monitoring'),
                            ],
                          ),
                        )
                        .animate(delay: 1000.ms)
                        .fadeIn()
                        .scale(begin: const Offset(0.8, 0.8)),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0),
      decoration: BoxDecoration(
        color: AppTheme.darkSurface,
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
        border: Border.all(
          color: AppTheme.primaryOrange.withValues(alpha: 0.3),
        ),
      ),
      child: ListView.builder(
        itemCount: _frames.length,
        itemBuilder: (context, index) {
          final frame = _frames[index];
          return _buildFrameRow(frame, index)
              .animate(delay: (50 * (index % 10)).ms)
              .fadeIn(duration: 300.ms)
              .slideX(begin: index.isEven ? -0.1 : 0.1, duration: 300.ms);
        },
      ),
    );
  }

  /// Get stored errors from frame
  List<CanErrorInfo> _getStoredErrors(CanFrame frame) =>
      recordedFrameErrors(frame);

  /// Build individual frame row
  Widget _buildFrameRow(CanFrame frame, int index) {
    final errors = _getStoredErrors(frame);
    final hasAnyError = frame.isCorrupted || errors.isNotEmpty;
    final isRtr = frame.isRtr;
    final isExt = frame.isExtended;

    final Color backgroundColor;
    final Color textColor;
    if (hasAnyError) {
      backgroundColor = AppTheme.accentRed.withValues(alpha: 0.1);
      textColor = AppTheme.accentRed;
    } else if (isRtr) {
      backgroundColor = AppTheme.primaryAmber.withValues(alpha: 0.08);
      textColor = AppTheme.primaryAmber;
    } else if (isExt) {
      backgroundColor = AppTheme.accentGreen.withValues(alpha: 0.06);
      textColor = AppTheme.accentGreen;
    } else {
      backgroundColor = index % 2 == 0
          ? AppTheme.darkContainer.withValues(alpha: 0.3)
          : Colors.transparent;
      textColor = AppTheme.textPrimary;
    }

    return InkWell(
      onTap: hasAnyError ? () => _showFrameErrorDetails(frame, errors) : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(8),
          border: hasAnyError
              ? Border.all(
                  color: AppTheme.accentRed.withValues(alpha: 0.5),
                  width: 1,
                )
              : Border.all(
                  color: AppTheme.darkBorder.withValues(alpha: 0.3),
                  width: 0.5,
                ),
        ),
        child: Row(
          children: [
            // ID
            SizedBox(
              width: 50,
              child: Text(
                frame.idHex,
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: textColor,
                  fontSize: 10,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // DLC
            SizedBox(
              width: 25,
              child: Text(
                frame.dlc.toString(),
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: textColor,
                  fontSize: 10,
                ),
              ),
            ),

            // Data
            Expanded(
              flex: 2,
              child: Text(
                frame.dataHex.isEmpty ? '-' : frame.dataHex,
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: textColor,
                  fontSize: 8,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // CRC
            SizedBox(
              width: 35,
              child: Text(
                '0x${frame.crc.toRadixString(16).toUpperCase().padLeft(2, '0')}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: textColor,
                  fontSize: 10,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // Time
            SizedBox(
              width: 50,
              child: Text(
                frame.timeFormatted.substring(
                  6,
                ), // Show only seconds.milliseconds
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: textColor,
                  fontSize: 8,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // Status
            Expanded(
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: hasAnyError
                          ? AppTheme.accentRed
                          : isRtr
                          ? AppTheme.primaryAmber
                          : AppTheme.accentGreen,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: textColor.withValues(alpha: 0.5),
                          blurRadius: 4,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      hasAnyError
                          ? 'ERROR'
                          : isRtr
                          ? 'RTR'
                          : isExt
                          ? 'EXT'
                          : 'OK',
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Show frame error details dialog
  void _showFrameErrorDetails(CanFrame frame, List<CanErrorInfo> errors) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppTheme.darkSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: AppTheme.primaryOrange.withValues(alpha: 0.3),
            ),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.error_outline,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  'Frame 0x${frame.id.toRadixString(16).toUpperCase()} Errors',
                  style: const TextStyle(color: AppTheme.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.darkContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppTheme.primaryAmber.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Frame ID: 0x${frame.id.toRadixString(16).toUpperCase()}',
                      style: const TextStyle(color: AppTheme.textPrimary),
                    ),
                    Text(
                      'DLC: ${frame.dlc}',
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                    Text(
                      'Data: ${frame.dataHex}',
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                    Text(
                      'Timestamp: ${frame.timeFormatted}',
                      style: const TextStyle(color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Detected Errors:',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryOrange,
                ),
              ),
              const SizedBox(height: 8),

              // Show all detected errors with proper names
              ...errors.map(
                (error) => _buildErrorDetailRow(
                  _getErrorTypeName(error.type),
                  '[${error.origin.name.toUpperCase()}] ${error.description}',
                  _getSeverityColor(error.severity),
                ),
              ),
            ],
          ),
          actions: [
            AnimatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  /// Build error detail row
  Widget _buildErrorDetailRow(String type, String description, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  type,
                  style: TextStyle(fontWeight: FontWeight.bold, color: color),
                ),
                Text(description, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Show detailed error statistics dialog
  void _showDetailedErrorStats() {
    final recommendations = _errorChecker.getRecommendations(
      _errorStats,
      _totalFrames,
    );
    final criticalRate = _errorChecker.isCriticalErrorRate(
      _errorStats,
      _totalFrames,
    );

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppTheme.darkSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: AppTheme.primaryOrange.withValues(alpha: 0.3),
            ),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: criticalRate
                      ? const LinearGradient(
                          colors: [AppTheme.accentRed, Color(0xFFD32F2F)],
                        )
                      : AppTheme.primaryGradient,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  criticalRate ? Icons.warning : Icons.analytics,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Error Statistics',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Overall statistics
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: criticalRate
                        ? LinearGradient(
                            colors: [
                              AppTheme.accentRed.withValues(alpha: 0.1),
                              AppTheme.accentRed.withValues(alpha: 0.05),
                            ],
                          )
                        : LinearGradient(
                            colors: [
                              AppTheme.primaryOrange.withValues(alpha: 0.1),
                              AppTheme.primaryAmber.withValues(alpha: 0.05),
                            ],
                          ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: criticalRate
                          ? AppTheme.accentRed.withValues(alpha: 0.3)
                          : AppTheme.primaryOrange.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'Overall Status: ${criticalRate ? "CRITICAL" : "NORMAL"}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: criticalRate
                              ? AppTheme.accentRed
                              : AppTheme.primaryOrange,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Total Frames: $_totalFrames',
                        style: const TextStyle(color: AppTheme.textPrimary),
                      ),
                      Text(
                        'Total Errors: $_errorFrames',
                        style: const TextStyle(color: AppTheme.textSecondary),
                      ),
                      Text(
                        'Error Rate: ${_errorRate.toStringAsFixed(1)}%',
                        style: const TextStyle(color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Error breakdown
                const Text(
                  'Error Breakdown:',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryAmber,
                  ),
                ),
                const SizedBox(height: 8),

                ...CanErrorType.values
                    .where(
                      (type) =>
                          type != CanErrorType.none &&
                          (_errorStats[type] ?? 0) > 0,
                    )
                    .map(
                      (type) =>
                          _buildErrorStatRow(type, _errorStats[type] ?? 0),
                    ),

                if (recommendations.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Recommendations:',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.accentGreen,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...recommendations.map(
                    (rec) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.lightbulb,
                            size: 16,
                            color: Colors.orange,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              rec,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            AnimatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  /// Build error statistic row
  Widget _buildErrorStatRow(CanErrorType type, int count) {
    final rate = _totalFrames > 0 ? (count / _totalFrames * 100) : 0.0;
    final severity = _getErrorSeverity(type);
    final color = _getSeverityColor(severity);

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _getErrorTypeName(type),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Text(
            '$count (${rate.toStringAsFixed(1)}%)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// Get error type display name
  String _getErrorTypeName(CanErrorType type) {
    switch (type) {
      case CanErrorType.crcError:
        return 'CRC Errors';
      case CanErrorType.formatError:
        return 'Format Errors';
      case CanErrorType.stuffingError:
        return 'Bit Stuffing Errors';
      case CanErrorType.ackError:
        return 'ACK Errors';
      case CanErrorType.overloadError:
        return 'Overload Errors';
      case CanErrorType.formError:
        return 'Form Errors';
      case CanErrorType.activeError:
        return 'Active Error Flags';
      case CanErrorType.passiveError:
        return 'Passive Error Flags';
      case CanErrorType.busOffError:
        return 'Bus-Off Errors';
      default:
        return type.toString().split('.').last;
    }
  }

  /// Get error severity level
  int _getErrorSeverity(CanErrorType type) {
    switch (type) {
      case CanErrorType.crcError:
        return 3;
      case CanErrorType.ackError:
      case CanErrorType.overloadError:
      case CanErrorType.busOffError:
        return 4;
      case CanErrorType.formatError:
      case CanErrorType.formError:
      case CanErrorType.stuffingError:
        return 2;
      case CanErrorType.activeError:
      case CanErrorType.passiveError:
        return 3;
      default:
        return 1;
    }
  }

  /// Get color based on severity
  Color _getSeverityColor(int severity) {
    switch (severity) {
      case 1:
        return Colors.green;
      case 2:
        return Colors.orange;
      case 3:
        return Colors.red;
      case 4:
      case 5:
        return Colors.red.shade800;
      default:
        return Colors.grey;
    }
  }

  /// Build live error rate chart
  Widget _buildErrorRateChart() {
    if (_errorRateHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.trending_up, color: AppTheme.primaryAmber, size: 32),
            const SizedBox(height: 8),
            const Text(
              'Error Rate Chart',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Text(
              'Waiting for data...',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.trending_up,
                size: 16,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Live Error Rate (%)',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color:
                    (_errorRate > 15
                            ? AppTheme.accentRed
                            : AppTheme.accentGreen)
                        .withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _errorRate > 15
                      ? AppTheme.accentRed
                      : AppTheme.accentGreen,
                  width: 1,
                ),
              ),
              child: Text(
                'Current: ${_errorRate.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 11,
                  color: _errorRate > 15
                      ? AppTheme.accentRed
                      : AppTheme.accentGreen,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: CustomPaint(
              painter: ErrorRateChartPainter(
                data: _errorRateHistory,
                maxValue: 100.0,
              ),
              child: Container(),
            ),
          ),
        ),
      ],
    );
  }
}

/// Custom painter for error rate chart
class ErrorRateChartPainter extends CustomPainter {
  final List<double> data;
  final double maxValue;

  ErrorRateChartPainter({required this.data, required this.maxValue});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()..style = PaintingStyle.fill;

    // Draw grid lines
    _drawGrid(canvas, size);

    // Calculate points
    final points = <Offset>[];
    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - (data[i] / maxValue) * size.height;
      points.add(Offset(x, y));
    }

    // Draw area under curve (gradient fill)
    if (points.length > 1) {
      final path = Path();
      path.moveTo(points.first.dx, size.height);
      path.lineTo(points.first.dx, points.first.dy);

      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }

      path.lineTo(points.last.dx, size.height);
      path.close();

      // Gradient fill
      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          _getColorForValue(data.last).withValues(alpha: 0.3),
          _getColorForValue(data.last).withValues(alpha: 0.1),
        ],
      );

      fillPaint.shader = gradient.createShader(
        Rect.fromLTWH(0, 0, size.width, size.height),
      );
      canvas.drawPath(path, fillPaint);
    }

    // Draw line
    if (points.length > 1) {
      paint.color = _getColorForValue(data.last);
      final path = Path();
      path.moveTo(points.first.dx, points.first.dy);

      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }

      canvas.drawPath(path, paint);
    }

    // Draw points
    for (int i = 0; i < points.length; i++) {
      final pointPaint = Paint()
        ..color = _getColorForValue(data[i])
        ..style = PaintingStyle.fill;

      canvas.drawCircle(points[i], 2.0, pointPaint);
    }

    // Draw current value indicator
    if (points.isNotEmpty) {
      final lastPoint = points.last;
      final indicatorPaint = Paint()
        ..color = _getColorForValue(data.last)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(lastPoint, 4.0, indicatorPaint);

      // Draw value text
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${data.last.toStringAsFixed(1)}%',
          style: TextStyle(
            color: _getColorForValue(data.last),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );

      textPainter.layout();
      final textOffset = Offset(
        lastPoint.dx - textPainter.width / 2,
        lastPoint.dy - textPainter.height - 8,
      );
      textPainter.paint(canvas, textOffset);
    }
  }

  void _drawGrid(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 0.5;

    // Horizontal grid lines (error rate levels)
    for (int i = 0; i <= 4; i++) {
      final y = (i / 4) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);

      // Draw percentage labels
      final percentage = (1 - i / 4) * maxValue;
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${percentage.toInt()}%',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 8),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(-25, y - textPainter.height / 2));
    }

    // Vertical grid lines (time intervals)
    for (int i = 0; i <= 4; i++) {
      final x = (i / 4) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
  }

  Color _getColorForValue(double value) {
    if (value > 20) return Colors.red.shade700;
    if (value > 15) return Colors.red;
    if (value > 10) return Colors.orange;
    if (value > 5) return Colors.yellow.shade700;
    return Colors.green;
  }

  @override
  bool shouldRepaint(ErrorRateChartPainter oldDelegate) {
    return oldDelegate.data != data;
  }
}

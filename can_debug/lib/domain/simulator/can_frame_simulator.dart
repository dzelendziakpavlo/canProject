import 'dart:async';
import 'dart:math';

import '../models/can_frame.dart';
import '../models/can_stats.dart';
import '../detection/can_error_checker.dart';
import '../source/can_frame_source.dart';

/// CAN Frame Simulator that generates random CAN frames
class CanFrameSimulator implements CanFrameSource {
  late StreamController<CanFrame> _frameController;
  final StreamController<SourceState> _stateController =
      StreamController<SourceState>.broadcast();
  Timer? _timer;
  final Random _random = Random();
  final CanErrorChecker _errorChecker = CanErrorChecker();

  /// Configuration constants
  static const int minDelay = 100; // milliseconds
  static const int maxDelay = 200; // milliseconds
  static const double corruptionRate = 0.1; // 10% of frames are corrupted
  static const int maxCanId = 0x7FF; // 11-bit CAN ID
  static const int maxExtendedCanId = 0x1FFFFFFF; // 29-bit extended CAN ID

  bool _isRunning = false;
  int _frameCounter = 0;

  CanFrameSimulator() {
    _frameController = StreamController<CanFrame>.broadcast();
  }

  @override
  String get name => 'Simulator';

  @override
  Stream<CanFrame> get frameStream => _frameController.stream;

  @override
  Stream<SourceState> get stateStream => _stateController.stream;

  @override
  Stream<CanStats>? get statsStream => null;

  /// Check if simulator is currently running
  bool get isRunning => _isRunning;

  /// Get total frames generated
  int get frameCount => _frameCounter;

  @override
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _frameCounter = 0;
    _stateController.add(SourceState.streaming);
    _scheduleNextFrame();
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;
    _timer?.cancel();
    _timer = null;
    _stateController.add(SourceState.idle);
  }

  /// Reset the simulator
  Future<void> reset() async {
    await stop();
    _frameCounter = 0;
  }

  /// Schedule the next frame generation
  void _scheduleNextFrame() {
    if (!_isRunning) return;

    final delay = minDelay + _random.nextInt(maxDelay - minDelay + 1);
    _timer = Timer(Duration(milliseconds: delay), () {
      _generateFrame();
      _scheduleNextFrame();
    });
  }

  /// Generate a single CAN frame
  void _generateFrame() {
    final frame = _createRandomFrame();
    _frameCounter++;
    _frameController.add(frame);
  }

  /// Create a random CAN frame
  CanFrame _createRandomFrame() {
    final useExtendedId = _random.nextBool();
    final id = useExtendedId
        ? _random.nextInt(maxExtendedCanId)
        : _random.nextInt(maxCanId);

    final dlc = _random.nextInt(9);
    final data = List.generate(dlc, (index) => _random.nextInt(256));
    final isCorrupted = _random.nextDouble() < corruptionRate;

    final initialFrame = CanFrame.create(
      id: id,
      dlc: dlc,
      data: data,
      timestamp: DateTime.now(),
      isCorrupted: isCorrupted,
    );

    final errorInfos = _errorChecker.analyzeFrame(initialFrame);
    final hasAdditionalErrors = errorInfos.isNotEmpty;

    return CanFrame.create(
      id: id,
      dlc: dlc,
      data: data,
      timestamp: initialFrame.timestamp,
      isCorrupted: isCorrupted || hasAdditionalErrors,
      errors: errorInfos,
    );
  }

  /// Generate a frame with specific parameters (for testing)
  void generateCustomFrame({
    int? id,
    int? dlc,
    List<int>? data,
    bool? isCorrupted,
  }) {
    if (!_isRunning) return;

    final customFrame = CanFrame.create(
      id: id ?? _random.nextInt(maxCanId),
      dlc: dlc ?? _random.nextInt(9),
      data: data ?? List.generate(_random.nextInt(9), (index) => _random.nextInt(256)),
      timestamp: DateTime.now(),
      isCorrupted: isCorrupted ?? false,
    );

    _frameCounter++;
    _frameController.add(customFrame);
  }

  /// Generate a burst of frames (for testing high traffic scenarios)
  void generateBurst(int count) {
    if (!_isRunning) return;

    for (int i = 0; i < count; i++) {
      Timer(Duration(milliseconds: i * 10), () {
        _generateFrame();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _frameController.close();
    _stateController.close();
    _isRunning = false;
  }

  /// Get simulator statistics
  Map<String, dynamic> getStatistics() {
    return {
      'isRunning': _isRunning,
      'frameCount': _frameCounter,
      'uptime': _isRunning ? 'Running' : 'Stopped',
    };
  }
}

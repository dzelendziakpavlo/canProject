import 'dart:async';
import 'dart:math';

import '../models/can_frame.dart';
import '../detection/can_error_checker.dart';

/// CAN Frame Simulator that generates random CAN frames
class CanFrameSimulator {
  late StreamController<CanFrame> _controller;
  late Timer _timer;
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

  /// Constructor initializes the stream controller
  CanFrameSimulator() {
    _controller = StreamController<CanFrame>.broadcast();
  }

  /// Get the stream of CAN frames
  Stream<CanFrame> get frameStream => _controller.stream;

  /// Check if simulator is currently running
  bool get isRunning => _isRunning;

  /// Get total frames generated
  int get frameCount => _frameCounter;

  /// Start generating CAN frames
  void start() {
    if (_isRunning) return;
    
    _isRunning = true;
    _frameCounter = 0;
    _scheduleNextFrame();
  }

  /// Stop generating CAN frames
  void stop() {
    if (!_isRunning) return;
    
    _isRunning = false;
    _timer.cancel();
  }

  /// Reset the simulator
  void reset() {
    stop();
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
    _controller.add(frame);
  }

  /// Create a random CAN frame
  CanFrame _createRandomFrame() {
    // Generate random CAN ID (mix of standard and extended IDs)
    final useExtendedId = _random.nextBool();
    final id = useExtendedId 
        ? _random.nextInt(maxExtendedCanId)
        : _random.nextInt(maxCanId);

    // Generate random DLC (0-8)
    final dlc = _random.nextInt(9);

    // Generate random data based on DLC
    final data = List.generate(dlc, (index) => _random.nextInt(256));

    // Determine if frame should be corrupted (10% chance)
    final isCorrupted = _random.nextDouble() < corruptionRate;

    // Create initial frame
    final initialFrame = CanFrame.create(
      id: id,
      dlc: dlc,
      data: data,
      timestamp: DateTime.now(),
      isCorrupted: isCorrupted,
    );

    // Analyze frame for additional errors (using the same frame instance)
    final errorInfos = _errorChecker.analyzeFrame(initialFrame);
    
    // Create final frame with all error information
    final hasAdditionalErrors = errorInfos.isNotEmpty;
    
    return CanFrame.create(
      id: id,
      dlc: dlc,
      data: data,
      timestamp: initialFrame.timestamp, // Use same timestamp
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
    _controller.add(customFrame);
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

  /// Dispose of resources
  void dispose() {
    stop();
    _controller.close();
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
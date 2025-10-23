import 'dart:async';
import 'dart:math';

import '../models/can_frame.dart';
import '../detection/can_error_checker.dart';

/// Automotive CAN Protocol Simulator з підтримкою J1939, OBD-II протоколів
class AutomotiveCanSimulator {
  late StreamController<CanFrame> _controller;
  late Timer _timer;
  final Random _random = Random();
  final CanErrorChecker _errorChecker = CanErrorChecker();
  
  /// Configuration constants
  static const int minDelay = 50; // milliseconds - higher frequency for automotive
  static const int maxDelay = 150; // milliseconds
  static const double corruptionRate = 0.05; // 5% of frames are corrupted (more realistic)
  static const int maxCanId = 0x7FF; // 11-bit CAN ID
  static const int maxExtendedCanId = 0x1FFFFFFF; // 29-bit extended CAN ID
  
  bool _isRunning = false;
  int _frameCounter = 0;
  
  // Automotive-specific parameters
  int _engineRpm = 800; // Current engine RPM
  int _vehicleSpeed = 0; // Current vehicle speed (km/h)
  int _engineTemp = 90; // Engine temperature (°C)
  double _fuelLevel = 75.0; // Fuel level (%)
  int _throttlePosition = 0; // Throttle position (%)

  /// Constructor initializes the stream controller
  AutomotiveCanSimulator() {
    _controller = StreamController<CanFrame>.broadcast();
  }

  /// Get the stream of CAN frames
  Stream<CanFrame> get frameStream => _controller.stream;

  /// Check if simulator is currently running
  bool get isRunning => _isRunning;

  /// Get total frames generated
  int get frameCount => _frameCounter;

  /// Start generating automotive CAN frames
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
    _resetVehicleParameters();
  }

  /// Schedule the next frame generation
  void _scheduleNextFrame() {
    if (!_isRunning) return;
    
    final delay = minDelay + _random.nextInt(maxDelay - minDelay + 1);
    _timer = Timer(Duration(milliseconds: delay), () {
      _generateAutomotiveFrame();
      _scheduleNextFrame();
    });
  }

  /// Generate an automotive-specific CAN frame
  void _generateAutomotiveFrame() {
    final frame = _createAutomotiveFrame();
    _frameCounter++;
    _controller.add(frame);
    
    // Update vehicle parameters for next frame
    _updateVehicleParameters();
  }

  /// Create a realistic automotive CAN frame
  CanFrame _createAutomotiveFrame() {
    // Randomly select frame type
    final frameType = _random.nextInt(10);
    
    CanFrame frame;
    
    switch (frameType) {
      case 0:
      case 1:
        frame = _createEngineDataFrame();
        break;
      case 2:
        frame = _createVehicleSpeedFrame();
        break;
      case 3:
        frame = _createEngineTempFrame();
        break;
      case 4:
        frame = _createFuelLevelFrame();
        break;
      case 5:
        frame = _createThrottlePositionFrame();
        break;
      case 6:
        frame = _createOBDResponseFrame();
        break;
      case 7:
        frame = _createJ1939Frame();
        break;
      case 8:
        frame = _createDiagnosticFrame();
        break;
      default:
        frame = _createGenericFrame();
        break;
    }

    // Determine if frame should be corrupted
    final isCorrupted = _random.nextDouble() < corruptionRate;
    
    if (isCorrupted) {
      // Create corrupted version
      final corruptedFrame = CanFrame.create(
        id: frame.id,
        dlc: frame.dlc,
        data: frame.data,
        timestamp: frame.timestamp,
        isCorrupted: true,
      );
      
      // Analyze for errors
      final errorInfos = _errorChecker.analyzeFrame(corruptedFrame);
      
      return CanFrame.create(
        id: frame.id,
        dlc: frame.dlc,
        data: frame.data,
        timestamp: frame.timestamp,
        isCorrupted: true,
        errors: errorInfos,
      );
    }

    return frame;
  }

  /// Create engine RPM data frame (Standard OBD-II PID 0x0C)
  CanFrame _createEngineDataFrame() {
    const canId = 0x7E8; // OBD-II response ID
    final rpmValue = (_engineRpm / 4).round();
    final rpmHigh = (rpmValue ~/ 256);
    final rpmLow = (rpmValue % 256);
    
    return CanFrame.create(
      id: canId,
      dlc: 5,
      data: [0x04, 0x41, 0x0C, rpmHigh, rpmLow], // OBD-II response format
      timestamp: DateTime.now(),
    );
  }

  /// Create vehicle speed frame (Standard OBD-II PID 0x0D)
  CanFrame _createVehicleSpeedFrame() {
    const canId = 0x7E8; // OBD-II response ID
    
    return CanFrame.create(
      id: canId,
      dlc: 4,
      data: [0x03, 0x41, 0x0D, _vehicleSpeed], // OBD-II response format
      timestamp: DateTime.now(),
    );
  }

  /// Create engine temperature frame (Standard OBD-II PID 0x05)
  CanFrame _createEngineTempFrame() {
    const canId = 0x7E8; // OBD-II response ID
    final tempValue = _engineTemp + 40; // OBD-II offset
    
    return CanFrame.create(
      id: canId,
      dlc: 4,
      data: [0x03, 0x41, 0x05, tempValue],
      timestamp: DateTime.now(),
    );
  }

  /// Create fuel level frame (Standard OBD-II PID 0x2F)
  CanFrame _createFuelLevelFrame() {
    const canId = 0x7E8; // OBD-II response ID
    final fuelValue = ((_fuelLevel / 100) * 255).round();
    
    return CanFrame.create(
      id: canId,
      dlc: 4,
      data: [0x03, 0x41, 0x2F, fuelValue],
      timestamp: DateTime.now(),
    );
  }

  /// Create throttle position frame (Standard OBD-II PID 0x11)
  CanFrame _createThrottlePositionFrame() {
    const canId = 0x7E8; // OBD-II response ID
    final throttleValue = ((_throttlePosition / 100) * 255).round();
    
    return CanFrame.create(
      id: canId,
      dlc: 4,
      data: [0x03, 0x41, 0x11, throttleValue],
      timestamp: DateTime.now(),
    );
  }

  /// Create OBD-II response frame
  CanFrame _createOBDResponseFrame() {
    const canId = 0x7E8; // OBD-II response ID
    final pid = _random.nextInt(256);
    final dataValue = _random.nextInt(256);
    
    return CanFrame.create(
      id: canId,
      dlc: 4,
      data: [0x03, 0x41, pid, dataValue],
      timestamp: DateTime.now(),
    );
  }

  /// Create J1939 frame (29-bit extended ID)
  CanFrame _createJ1939Frame() {
    // J1939 uses 29-bit extended IDs
    final priority = _random.nextInt(8); // 3 bits
    final pgn = _random.nextInt(0x1FFFF); // Parameter Group Number
    final sourceAddress = _random.nextInt(256); // Source address
    
    final canId = (priority << 26) | (pgn << 8) | sourceAddress;
    final dlc = 1 + _random.nextInt(8);
    final data = List.generate(dlc, (index) => _random.nextInt(256));
    
    return CanFrame.create(
      id: canId,
      dlc: dlc,
      data: data,
      timestamp: DateTime.now(),
    );
  }

  /// Create diagnostic frame
  CanFrame _createDiagnosticFrame() {
    const canId = 0x7DF; // Diagnostic request ID
    final service = 0x01 + _random.nextInt(10); // Service ID
    final pid = _random.nextInt(256); // Parameter ID
    
    return CanFrame.create(
      id: canId,
      dlc: 8,
      data: [service, pid, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
      timestamp: DateTime.now(),
    );
  }

  /// Create generic automotive frame
  CanFrame _createGenericFrame() {
    final useExtendedId = _random.nextBool();
    final id = useExtendedId 
        ? _random.nextInt(maxExtendedCanId)
        : _random.nextInt(maxCanId);

    final dlc = _random.nextInt(9);
    final data = List.generate(dlc, (index) => _random.nextInt(256));

    return CanFrame.create(
      id: id,
      dlc: dlc,
      data: data,
      timestamp: DateTime.now(),
    );
  }

  /// Update vehicle parameters for realistic simulation
  void _updateVehicleParameters() {
    // Simulate engine RPM changes
    final rpmChange = _random.nextInt(200) - 100; // -100 to +100 RPM
    _engineRpm = (_engineRpm + rpmChange).clamp(600, 6000);

    // Simulate vehicle speed changes
    final speedChange = _random.nextInt(10) - 5; // -5 to +5 km/h
    _vehicleSpeed = (_vehicleSpeed + speedChange).clamp(0, 120);

    // Simulate engine temperature changes
    final tempChange = _random.nextInt(6) - 3; // -3 to +3 degrees
    _engineTemp = (_engineTemp + tempChange).clamp(60, 120);

    // Simulate fuel level decrease
    if (_random.nextInt(1000) < 5) { // 0.5% chance per frame
      _fuelLevel = (_fuelLevel - 0.1).clamp(0, 100);
    }

    // Simulate throttle position changes
    final throttleChange = _random.nextInt(20) - 10; // -10 to +10%
    _throttlePosition = (_throttlePosition + throttleChange).clamp(0, 100);
  }

  /// Reset vehicle parameters to default values
  void _resetVehicleParameters() {
    _engineRpm = 800;
    _vehicleSpeed = 0;
    _engineTemp = 90;
    _fuelLevel = 75.0;
    _throttlePosition = 0;
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

  /// Get current vehicle telemetry
  Map<String, dynamic> getVehicleTelemetry() {
    return {
      'engineRpm': _engineRpm,
      'vehicleSpeed': _vehicleSpeed,
      'engineTemp': _engineTemp,
      'fuelLevel': _fuelLevel,
      'throttlePosition': _throttlePosition,
      'isRunning': _isRunning,
      'frameCount': _frameCounter,
    };
  }

  /// Dispose of resources
  void dispose() {
    stop();
    _controller.close();
  }
}
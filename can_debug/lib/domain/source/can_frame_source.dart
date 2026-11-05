import '../models/can_frame.dart';
import '../models/can_stats.dart';

enum SourceState {
  idle,
  scanning,
  connecting,
  connected,
  streaming,
  reconnecting,
  disconnected,
  lost,
  error,
}

abstract class CanFrameSource {
  Stream<CanFrame> get frameStream;
  Stream<SourceState> get stateStream;

  /// Optional TWAI hardware stats stream.
  /// Non-null only for hardware sources (BleCanSource).
  /// Simulator returns null.
  Stream<CanStats>? get statsStream => null;

  String get name;
  Future<void> start();
  Future<void> stop();
  void dispose();
}

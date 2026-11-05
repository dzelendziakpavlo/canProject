import 'dart:async';

import '../models/can_frame.dart';
import '../models/can_session.dart';
import '../models/can_session_event.dart';
import '../models/can_stats.dart';
import 'can_frame_source.dart';

/// Replays a saved session through the same frame-source contract as live input.
class ReplayCanSource implements CanFrameSource {
  ReplayCanSource(this.session);

  final CanSession session;
  final _frameController = StreamController<CanFrame>.broadcast();
  final _stateController = StreamController<SourceState>.broadcast();
  final _statsController = StreamController<CanStats>.broadcast();

  Timer? _timer;
  int _index = 0;
  int _statsIndex = 0;
  double _speed = 1.0;
  bool _isPlaying = false;
  bool _disposed = false;

  @override
  String get name => 'Replay — ${session.name}';

  @override
  Stream<CanFrame> get frameStream => _frameController.stream;

  @override
  Stream<SourceState> get stateStream => _stateController.stream;

  @override
  Stream<CanStats>? get statsStream => _statsController.stream;

  double get speed => _speed;
  bool get isPlaying => _isPlaying;
  int get currentIndex => _index;
  int get totalFrames => session.frames.length;
  double get progress => totalFrames == 0 ? 0.0 : _index / totalFrames;
  Duration get elapsed => _index == 0 || session.frames.isEmpty
      ? Duration.zero
      : session.frames[_index - 1].timestamp.difference(session.frames.first.timestamp);
  Duration get duration => session.frames.isEmpty
      ? Duration.zero
      : session.frames.last.timestamp.difference(session.frames.first.timestamp);
  List<CanSessionEvent> get diagnosticEvents => session.events
      .where((event) => event.type == CanSessionEventType.diagnostic)
      .toList(growable: false);

  Duration eventOffset(CanSessionEvent event) {
    if (session.frames.isEmpty) return Duration.zero;
    return event.timestamp.difference(session.frames.first.timestamp);
  }

  void seekToEvent(CanSessionEvent event) {
    seekTo(eventOffset(event));
  }

  @override
  Future<void> start() async {
    if (_disposed || _isPlaying) return;
    if (_index >= totalFrames) seekTo(Duration.zero);
    _isPlaying = true;
    _stateController.add(SourceState.streaming);
    _emitNext();
  }

  Future<void> pause() async {
    _isPlaying = false;
    _timer?.cancel();
    _timer = null;
  }

  @override
  Future<void> stop() async {
    await pause();
    _index = 0;
    _statsIndex = 0;
    if (!_disposed) _stateController.add(SourceState.idle);
  }

  void setSpeed(double value) {
    _speed = value.clamp(0.25, 8.0).toDouble();
    if (_isPlaying) {
      _timer?.cancel();
      _emitNext();
    }
  }

  void seekTo(Duration position) {
    final wasPlaying = _isPlaying;
    _timer?.cancel();
    _index = session.frames.indexWhere((frame) {
      final offset = frame.timestamp.difference(session.frames.first.timestamp);
      return offset >= position;
    });
    if (_index < 0) _index = totalFrames;
    final frameOrigin = session.frames.isEmpty ? session.startTime : session.frames.first.timestamp;
    _statsIndex = session.statsSnapshots.indexWhere((stats) => stats.timestamp.difference(frameOrigin) >= position);
    if (_statsIndex < 0) _statsIndex = session.statsSnapshots.length;
    if (wasPlaying) _emitNext();
  }

  void seekToIndex(int index) {
    if (session.frames.isEmpty) return;
    final safeIndex = index.clamp(0, session.frames.length - 1).toInt();
    final position = session.frames[safeIndex].timestamp.difference(session.frames.first.timestamp);
    seekTo(position);
  }

  void _emitNext() {
    if (!_isPlaying || _disposed) return;
    if (_index >= totalFrames) {
      _isPlaying = false;
      _stateController.add(SourceState.idle);
      return;
    }

    final frame = session.frames[_index++];
    _frameController.add(frame);
    _emitStatsUntil(frame.timestamp);

    if (_index >= totalFrames) {
      _isPlaying = false;
      _stateController.add(SourceState.idle);
      return;
    }

    final nextDelay = session.frames[_index].timestamp.difference(frame.timestamp);
    final delayMs = (nextDelay.inMilliseconds / _speed).round().clamp(1, 60000);
    _timer = Timer(Duration(milliseconds: delayMs), _emitNext);
  }

  void _emitStatsUntil(DateTime timestamp) {
    while (_statsIndex < session.statsSnapshots.length &&
        !session.statsSnapshots[_statsIndex].timestamp.isAfter(timestamp)) {
      _statsController.add(session.statsSnapshots[_statsIndex]);
      _statsIndex++;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _isPlaying = false;
    _timer?.cancel();
    _frameController.close();
    _stateController.close();
    _statsController.close();
  }
}

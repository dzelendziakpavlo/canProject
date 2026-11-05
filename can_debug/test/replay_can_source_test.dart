import 'package:flutter_test/flutter_test.dart';

import 'package:can_debug/domain/detection/can_error_checker.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/models/can_session.dart';
import 'package:can_debug/domain/models/can_session_event.dart';
import 'package:can_debug/domain/source/replay_can_source.dart';

void main() {
  final start = DateTime(2026, 9, 18, 12, 0, 0);

  CanSession createSession() {
    final frames = [
      CanFrame.create(id: 0x100, dlc: 1, data: [1], timestamp: start),
      CanFrame.create(id: 0x101, dlc: 1, data: [2], timestamp: start.add(const Duration(milliseconds: 2))),
      CanFrame.create(id: 0x102, dlc: 1, data: [3], timestamp: start.add(const Duration(milliseconds: 4))),
    ];
    return CanSession(
      id: 'replay-test',
      name: 'Replay test',
      sourceName: 'Simulator',
      startTime: start,
      endTime: start.add(const Duration(milliseconds: 4)),
      frames: frames,
      errorStats: {for (final type in CanErrorType.values) type: 0},
      totalFrames: frames.length,
      errorFrames: 0,
      errorRate: 0,
      events: [
        CanSessionEvent(
          id: 'diagnostic-1',
          type: CanSessionEventType.diagnostic,
          timestamp: start.add(const Duration(milliseconds: 2)),
          message: 'Bus warning',
          diagnosticSeverity: DiagnosticSeverity.warning,
          diagnosticCause: DiagnosticCause.busNoise,
        ),
      ],
    );
  }

  test('replays frames in recorded order and stops at the end', () async {
    final source = ReplayCanSource(createSession());
    final framesFuture = source.frameStream.take(3).toList();

    await source.start();
    final frames = await framesFuture;

    expect(frames.map((frame) => frame.id), [0x100, 0x101, 0x102]);
    expect(source.isPlaying, isFalse);
    expect(source.currentIndex, 3);
    expect(source.progress, 1.0);
    source.dispose();
  });

  test('seek changes the next replayed frame and speed is clamped', () async {
    final source = ReplayCanSource(createSession());
    source.setSpeed(100);
    expect(source.speed, 8.0);
    source.seekToIndex(1);

    final frameFuture = source.frameStream.first;
    await source.start();
    final frame = await frameFuture;

    expect(frame.id, 0x101);
    source.setSpeed(0.01);
    expect(source.speed, 0.25);
    source.dispose();
  });

  test('seekToEvent jumps to the first frame at the diagnostic marker', () async {
    final source = ReplayCanSource(createSession());
    final event = source.diagnosticEvents.single;
    source.seekToEvent(event);

    final frameFuture = source.frameStream.first;
    await source.start();
    final frame = await frameFuture;

    expect(frame.id, 0x101);
    expect(source.eventOffset(event), const Duration(milliseconds: 2));
    source.dispose();
  });
}

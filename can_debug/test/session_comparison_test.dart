import 'package:flutter_test/flutter_test.dart';

import 'package:can_debug/domain/detection/can_error_checker.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/models/can_session.dart';
import 'package:can_debug/domain/services/session_comparison.dart';

void main() {
  final start = DateTime(2026, 9, 18, 12, 0, 0);

  CanSession session(String id, List<CanFrame> frames) {
    return CanSession(
      id: id,
      name: id,
      startTime: start,
      endTime: start.add(const Duration(seconds: 1)),
      frames: frames,
      errorStats: {for (final type in CanErrorType.values) type: 0},
      totalFrames: frames.length,
      errorFrames: frames.where((frame) => frame.isCorrupted).length,
      errorRate: frames.isEmpty ? 0 : 100 / frames.length,
    );
  }

  test('comparison reports metric deltas and changed CAN IDs', () {
    final baseline = session('baseline', [
      CanFrame.create(id: 0x100, dlc: 1, data: [1], timestamp: start),
      CanFrame.create(id: 0x100, dlc: 1, data: [2], timestamp: start.add(const Duration(milliseconds: 1))),
    ]);
    final incident = session('incident', [
      CanFrame.create(id: 0x100, dlc: 1, data: [1], timestamp: start),
      CanFrame.create(id: 0x200, dlc: 1, data: [2], timestamp: start.add(const Duration(milliseconds: 1)), isCorrupted: true),
      CanFrame.create(id: 0x200, dlc: 1, data: [3], timestamp: start.add(const Duration(milliseconds: 2))),
    ]);

    final comparison = SessionComparisonBuilder().build(baseline, incident);

    expect(comparison.frameDelta, 1);
    expect(comparison.errorFrameDelta, 1);
    expect(comparison.idComparisons.map((entry) => entry.formattedId), containsAll(['0x100', '0x200']));
    expect(comparison.idComparisons.first.delta.abs(), 2);
  });
}

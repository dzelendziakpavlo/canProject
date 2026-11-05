import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/simulator/can_frame_simulator.dart';

void main() {
  group('CanFrame Tests', () {
    test('should create a valid CAN frame', () {
      final frame = CanFrame.create(
        id: 0x123,
        dlc: 4,
        data: [0x01, 0x02, 0x03, 0x04],
        isCorrupted: false,
      );

      expect(frame.id, equals(0x123));
      expect(frame.dlc, equals(4));
      expect(frame.data, equals([0x01, 0x02, 0x03, 0x04]));
      expect(frame.isCorrupted, equals(false));
    });

    test('should create corrupted frame with invalid CRC', () {
      final normalFrame = CanFrame.create(
        id: 0x123,
        dlc: 4,
        data: [0x01, 0x02, 0x03, 0x04],
        isCorrupted: false,
      );

      final corruptedFrame = CanFrame.create(
        id: 0x123,
        dlc: 4,
        data: [0x01, 0x02, 0x03, 0x04],
        isCorrupted: true,
      );

      expect(normalFrame.crc, isNot(equals(corruptedFrame.crc)));
      expect(corruptedFrame.isCorrupted, equals(true));
    });

    test('should format data as hex string', () {
      final frame = CanFrame.create(
        id: 0x123,
        dlc: 3,
        data: [0x01, 0xAB, 0xFF],
      );

      expect(frame.dataHex, equals('01 AB FF'));
    });
  });

  group('CanFrameSimulator Tests', () {
    test('should create simulator instance', () {
      final simulator = CanFrameSimulator();
      expect(simulator.isRunning, equals(false));
      expect(simulator.frameCount, equals(0));
      simulator.dispose();
    });

    test('should start and stop simulation', () {
      final simulator = CanFrameSimulator();
      
      simulator.start();
      expect(simulator.isRunning, equals(true));
      
      simulator.stop();
      expect(simulator.isRunning, equals(false));
      
      simulator.dispose();
    });

    test('should generate frames when running', () async {
      final simulator = CanFrameSimulator();
      final frames = <CanFrame>[];
      
      simulator.frameStream.listen((frame) {
        frames.add(frame);
      });
      
      simulator.start();
      
      // Wait for a few frames to be generated
      await Future.delayed(const Duration(milliseconds: 500));
      
      expect(frames.length, greaterThan(0));
      expect(simulator.frameCount, greaterThan(0));
      
      simulator.dispose();
    });

    test('should deliver explicitly corrupted frames', () async {
      final simulator = CanFrameSimulator();
      final frames = <CanFrame>[];
      
      simulator.frameStream.listen((frame) {
        frames.add(frame);
      });
      
      simulator.start();
      
      // Random generation every 100–200 ms cannot promise >10 frames per second.
      for (var i = 0; i < 12; i++) {
        simulator.generateCustomFrame(id: 0x100, dlc: 1, data: [i], isCorrupted: i == 0);
      }
      await Future<void>.delayed(Duration.zero);
      
      final corruptedFrames = frames.where((f) => f.isCorrupted).length;
      final totalFrames = frames.length;
      
      // Verify delivery and corruption without random/timing assumptions.
      expect(corruptedFrames, greaterThan(0));
      expect(totalFrames, greaterThan(10)); // Ensure we have enough frames
      
      simulator.dispose();
    });
  });
}

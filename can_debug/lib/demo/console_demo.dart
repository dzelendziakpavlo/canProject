import 'dart:io';

import 'package:can_debug/domain/simulator/can_frame_simulator.dart';

/// Simple console-based CAN frame emulator demo
/// Run with: dart run lib/demo/console_demo.dart
void main() async {
  print('🚗 CAN Frame Emulator Console Demo');
  print('=====================================\n');

  final simulator = CanFrameSimulator();
  int totalFrames = 0;
  int errorFrames = 0;

  // Listen to frames
  final subscription = simulator.frameStream.listen((frame) {
    totalFrames++;
    if (frame.isCorrupted) errorFrames++;

    // Print frame in compact format
    final status = frame.isCorrupted ? '❌' : '✅';
    print('$status Frame ${totalFrames.toString().padLeft(3)}: '
          'ID=${frame.id.toRadixString(16).toUpperCase().padLeft(3, '0')} '
          'DLC=${frame.dlc} '
          'CRC=${frame.crc.toRadixString(16).toUpperCase().padLeft(2, '0')} '
          '${frame.timeFormatted}');
  });

  print('Starting simulation... (Press Enter to stop)\n');
  simulator.start();

  // Wait for user input to stop
  stdin.readLineSync();

  simulator.stop();
  print('\n📊 Final Statistics:');
  print('   Total Frames: $totalFrames');
  print('   Error Frames: $errorFrames');
  if (totalFrames > 0) {
    final errorRate = (errorFrames / totalFrames * 100);
    print('   Error Rate: ${errorRate.toStringAsFixed(1)}%');
  }

  await subscription.cancel();
  simulator.dispose();
  print('\n✨ Demo completed!');
}
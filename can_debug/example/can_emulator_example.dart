import 'dart:async';
import '../lib/domain/models/can_frame.dart';
import '../lib/domain/simulator/can_frame_simulator.dart';

/// Example showing how to use the CAN Frame Emulator
void main() async {
  print('=== CAN Frame Emulator Example ===\n');
  
  // Create simulator instance
  final simulator = CanFrameSimulator();
  
  // Variables to track statistics
  int totalFrames = 0;
  int errorFrames = 0;
  
  // Listen to frame stream
  final subscription = simulator.frameStream.listen((frame) {
    totalFrames++;
    if (frame.isCorrupted) {
      errorFrames++;
    }
    
    // Print frame details
    print('Frame ${totalFrames.toString().padLeft(3, '0')}: '
          'ID=0x${frame.id.toRadixString(16).toUpperCase().padLeft(3, '0')} '
          'DLC=${frame.dlc} '
          'Data=[${frame.dataHex}] '
          'CRC=0x${frame.crc.toRadixString(16).toUpperCase().padLeft(2, '0')} '
          'Status=${frame.status} '
          'Time=${frame.timeFormatted}');
  });
  
  // Start simulation
  print('Starting CAN frame simulation...\n');
  simulator.start();
  
  // Run for 5 seconds
  await Future.delayed(const Duration(seconds: 5));
  
  // Stop simulation
  simulator.stop();
  print('\nStopping simulation...\n');
  
  // Print statistics
  final errorRate = totalFrames > 0 ? (errorFrames / totalFrames) * 100 : 0.0;
  print('=== Final Statistics ===');
  print('Total Frames: $totalFrames');
  print('Error Frames: $errorFrames');
  print('Error Rate: ${errorRate.toStringAsFixed(1)}%');
  print('Average Rate: ${(totalFrames / 5).toStringAsFixed(1)} frames/second');
  
  // Generate a few custom frames
  print('\n=== Custom Frame Generation ===');
  simulator.start();
  
  // Generate specific test frames
  simulator.generateCustomFrame(
    id: 0x7FF,
    dlc: 8,
    data: [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77],
    isCorrupted: false,
  );
  
  simulator.generateCustomFrame(
    id: 0x123,
    dlc: 4,
    data: [0xAA, 0xBB, 0xCC, 0xDD],
    isCorrupted: true,
  );
  
  // Generate a burst of frames
  simulator.generateBurst(5);
  
  await Future.delayed(const Duration(milliseconds: 500));
  
  // Clean up
  await subscription.cancel();
  simulator.dispose();
  
  print('\nExample completed successfully!');
}

/// Helper function to demonstrate frame analysis
void analyzeFrame(CanFrame frame) {
  print('\n--- Frame Analysis ---');
  print('ID: 0x${frame.id.toRadixString(16).toUpperCase()} (${frame.id})');
  print('DLC: ${frame.dlc} bytes');
  print('Data: [${frame.dataHex}]');
  print('CRC: 0x${frame.crc.toRadixString(16).toUpperCase()}');
  print('Timestamp: ${frame.timeFormatted}');
  print('Status: ${frame.status}');
  print('Is Corrupted: ${frame.isCorrupted}');
}
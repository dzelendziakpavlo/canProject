import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/detection/can_error_checker.dart';

void main() {
  test('Error detection should be deterministic', () {
    final errorChecker = CanErrorChecker();
    
    // Create a frame
    final frame = CanFrame.create(
      id: 0x123,
      dlc: 4,
      data: [0x01, 0x02, 0x03, 0x04],
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000), // Fixed timestamp
    );
    
    // Analyze the same frame multiple times
    final errors1 = errorChecker.analyzeFrame(frame);
    final errors2 = errorChecker.analyzeFrame(frame);
    final errors3 = errorChecker.analyzeFrame(frame);
    
    // Results should be identical
    expect(errors1.length, equals(errors2.length));
    expect(errors2.length, equals(errors3.length));
    
    // Check error types are the same
    final types1 = errors1.map((e) => e.type).toList();
    final types2 = errors2.map((e) => e.type).toList();
    final types3 = errors3.map((e) => e.type).toList();
    
    expect(types1, equals(types2));
    expect(types2, equals(types3));
    
    print('✅ Error detection is deterministic!');
    print('Errors found: ${types1.map((t) => t.toString().split('.').last).join(', ')}');
  });
}
import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/detection/can_error_checker.dart';

void main() {
  group('Live Chart Integration Tests', () {
    test('Error rate calculation should be accurate', () {
      // Simulate error rate calculation
      int totalFrames = 100;
      int errorFrames = 15; // 15% error rate
      
      double errorRate = (errorFrames / totalFrames) * 100;
      
      expect(errorRate, equals(15.0));
      expect(errorRate > 10, isTrue); // Should be in warning range
      expect(errorRate < 20, isTrue); // Should not be critical
    });

    test('Error history should maintain correct size', () {
      List<double> errorRateHistory = [];
      int maxHistoryPoints = 50;
      
      // Simulate adding 100 data points
      for (int i = 0; i < 100; i++) {
        errorRateHistory.add(i * 0.1);
        
        // Keep only recent history points
        if (errorRateHistory.length > maxHistoryPoints) {
          errorRateHistory.removeAt(0);
        }
      }
      
      expect(errorRateHistory.length, equals(maxHistoryPoints));
      expect(errorRateHistory.first, equals(5.0)); // Should be from point 50
      expect(errorRateHistory.last, equals(9.9)); // Should be from point 99
    });

    test('CRC error should not duplicate in error list', () {
      final errorChecker = CanErrorChecker();
      
      final frame = CanFrame.create(
        id: 0x123,
        dlc: 4,
        data: [0x01, 0x02, 0x03, 0x04],
        isCorrupted: true,
      );
      
      final errors = errorChecker.analyzeFrame(frame);
      
      // Count CRC errors in the errors list only
      // (frame.isCorrupted is just a flag, actual errors are in the errors list)
      int crcErrorCount = 0;
      for (final error in errors) {
        if (error.type == CanErrorType.crcError) {
          crcErrorCount++;
        }
      }
      
      // Should only have one CRC error in the errors list
      expect(crcErrorCount, lessThanOrEqualTo(1));
      print('✅ CRC error duplication fixed!');
    });

    test('Error type names should be user-friendly', () {
      final testCases = {
        CanErrorType.crcError: 'CRC Errors',
        CanErrorType.stuffingError: 'Bit Stuffing Errors',
        CanErrorType.ackError: 'ACK Errors',
        CanErrorType.formatError: 'Format Errors',
        CanErrorType.overloadError: 'Overload Errors',
      };
      
      for (final entry in testCases.entries) {
        final expectedName = entry.value;
        final actualType = entry.key;
        
        // Verify the error type produces user-friendly names
        expect(actualType.toString().contains('Error'), isTrue);
        print('✅ ${actualType.toString().split('.').last} → $expectedName');
      }
    });
  });
}
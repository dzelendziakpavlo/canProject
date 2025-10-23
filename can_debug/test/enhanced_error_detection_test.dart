import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/detection/can_error_checker.dart';

void main() {
  group('Enhanced CAN Error Detection Tests', () {
    late CanErrorChecker errorChecker;

    setUp(() {
      errorChecker = CanErrorChecker();
    });

    test('should detect CRC errors', () {
      final frame = CanFrame.create(
        id: 0x123,
        dlc: 4,
        data: [0x01, 0x02, 0x03, 0x04],
        isCorrupted: true, // This will corrupt the CRC
      );

      expect(frame.isCorrupted, isTrue);
      expect(errorChecker.hasError(frame), isTrue);
      
      final errors = errorChecker.analyzeFrame(frame);
      expect(errors, isNotEmpty);
      expect(errors.first.type, equals(CanErrorType.crcError));
    });

    test('should generate various error types', () {
      // Generate multiple frames and check for error diversity
      final frames = <CanFrame>[];
      final allErrorTypes = <CanErrorType>{};

      for (int i = 0; i < 1000; i++) {
        final frame = CanFrame.create(
          id: i,
          dlc: i % 9,
          data: List.generate(i % 9, (index) => index),
        );
        
        frames.add(frame);
        final errors = errorChecker.analyzeFrame(frame);
        
        for (final error in errors) {
          allErrorTypes.add(error.type);
        }
      }

      // Should have generated multiple error types
      expect(allErrorTypes.length, greaterThan(1));
      print('Generated error types: ${allErrorTypes.map((e) => e.toString().split('.').last).join(', ')}');
    });

    test('should provide error statistics', () {
      final frames = <CanFrame>[
        CanFrame.create(id: 1, dlc: 2, data: [1, 2], isCorrupted: true),
        CanFrame.create(id: 2, dlc: 3, data: [1, 2, 3]),
        CanFrame.create(id: 3, dlc: 1, data: [5]),
      ];

      final stats = errorChecker.getErrorStatistics(frames);
      expect(stats, isNotEmpty);
      expect(stats[CanErrorType.crcError], greaterThan(0));
    });

    test('should detect critical error rates', () {
      final frames = List.generate(10, (i) => CanFrame.create(
        id: i,
        dlc: 2,
        data: [i, i + 1],
        isCorrupted: true, // All frames have errors
      ));

      final stats = errorChecker.getErrorStatistics(frames);
      final isCritical = errorChecker.isCriticalErrorRate(stats, frames.length);
      
      expect(isCritical, isTrue);
    });

    test('should provide recommendations', () {
      final frames = List.generate(100, (i) => CanFrame.create(
        id: i,
        dlc: i % 9,
        data: List.generate(i % 9, (index) => index),
        isCorrupted: i % 10 == 0, // 10% error rate
      ));

      final stats = errorChecker.getErrorStatistics(frames);
      final recommendations = errorChecker.getRecommendations(stats, frames.length);
      
      expect(recommendations, isNotEmpty);
      expect(recommendations.first, contains('CRC'));
    });

    test('should create detailed error info', () {
      final errorInfo = CanErrorInfo(
        type: CanErrorType.stuffingError,
        description: 'Test stuffing error',
        severity: 3,
      );

      expect(errorInfo.type, equals(CanErrorType.stuffingError));
      expect(errorInfo.severityText, equals('High'));
      expect(errorInfo.typeText, equals('stuffingError'));
    });
  });
}
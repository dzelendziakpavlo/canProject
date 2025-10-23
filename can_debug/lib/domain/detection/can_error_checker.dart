import 'dart:math';
import '../models/can_frame.dart';

/// Types of CAN errors that can be detected
enum CanErrorType {
  none,
  crcError,        // CRC checksum mismatch
  formatError,     // Frame format violation
  stuffingError,   // Bit stuffing violation
  ackError,        // Acknowledgment error
  overloadError,   // Bus overload condition
  formError,       // Form error in fixed format bits
  activeError,     // Active error flag detected
  passiveError,    // Passive error flag detected
  busOffError,     // Bus-off condition
}

/// Detailed error information
class CanErrorInfo {
  final CanErrorType type;
  final String description;
  final int severity; // 1-5 (1=low, 5=critical)
  final DateTime timestamp;
  final Map<String, dynamic> details;

  CanErrorInfo({
    required this.type,
    required this.description,
    required this.severity,
    DateTime? timestamp,
    this.details = const {},
  }) : timestamp = timestamp ?? DateTime.now();

  String get severityText {
    switch (severity) {
      case 1: return 'Low';
      case 2: return 'Medium';
      case 3: return 'High';
      case 4: return 'Critical';
      case 5: return 'Fatal';
      default: return 'Unknown';
    }
  }

  String get typeText => type.toString().split('.').last;
}

/// CAN Error Checker for detecting and analyzing frame errors
class CanErrorChecker {
  
  // Error simulation rates (configurable)
  static const double stuffingErrorRate = 0.02;    // 2%
  static const double formatErrorRate = 0.015;     // 1.5%
  static const double ackErrorRate = 0.01;         // 1%
  static const double overloadErrorRate = 0.005;   // 0.5%
  static const double formErrorRate = 0.008;       // 0.8%

  /// Check if a CAN frame has any errors
  bool hasError(CanFrame frame) {
    final errors = analyzeFrame(frame);
    return errors.isNotEmpty;
  }

  /// Analyze frame for all possible error types
  List<CanErrorInfo> analyzeFrame(CanFrame frame) {
    final errors = <CanErrorInfo>[];

    // Check CRC error (already implemented in frame)
    if (frame.isCorrupted) {
      errors.add(CanErrorInfo(
        type: CanErrorType.crcError,
        description: 'CRC checksum mismatch detected',
        severity: 3,
        details: {
          'frameId': frame.id,
          'expectedCrc': _calculateExpectedCrc(frame),
          'actualCrc': frame.crc,
        },
      ));
    }

    // Simulate additional error types
    errors.addAll(_simulateProtocolErrors(frame));
    
    return errors;
  }

  /// Simulate various protocol-level errors (deterministic based on frame properties)
  List<CanErrorInfo> _simulateProtocolErrors(CanFrame frame) {
    final errors = <CanErrorInfo>[];
    
    // Create deterministic seed based on frame properties
    final seed = frame.id ^ frame.dlc ^ frame.data.fold(0, (sum, byte) => sum ^ byte) ^ frame.timestamp.millisecondsSinceEpoch;
    final frameRandom = Random(seed);

    // Bit Stuffing Error
    if (frameRandom.nextDouble() < stuffingErrorRate) {
      errors.add(CanErrorInfo(
        type: CanErrorType.stuffingError,
        description: 'Bit stuffing violation: More than 5 consecutive identical bits',
        severity: 2,
        details: {
          'position': frameRandom.nextInt(64), // Bit position in frame
          'sequence': _generateBadStuffingSequence(frameRandom),
        },
      ));
    }

    // Format Error
    if (frameRandom.nextDouble() < formatErrorRate) {
      errors.add(CanErrorInfo(
        type: CanErrorType.formatError,
        description: 'Frame format violation in reserved bits',
        severity: 3,
        details: {
          'fieldType': _getRandomFormatErrorField(frameRandom),
          'expectedValue': '0',
          'actualValue': '1',
        },
      ));
    }

    // ACK Error
    if (frameRandom.nextDouble() < ackErrorRate) {
      errors.add(CanErrorInfo(
        type: CanErrorType.ackError,
        description: 'No acknowledgment received from any node',
        severity: 4,
        details: {
          'ackSlot': 'recessive',
          'expectedState': 'dominant',
          'busLoad': '${frameRandom.nextInt(100)}%',
        },
      ));
    }

    // Overload Error
    if (frameRandom.nextDouble() < overloadErrorRate) {
      errors.add(CanErrorInfo(
        type: CanErrorType.overloadError,
        description: 'Bus overload condition detected',
        severity: 4,
        details: {
          'overloadFlags': frameRandom.nextInt(3) + 1,
          'cause': _getRandomOverloadCause(frameRandom),
        },
      ));
    }

    // Form Error
    if (frameRandom.nextDouble() < formErrorRate) {
      errors.add(CanErrorInfo(
        type: CanErrorType.formError,
        description: 'Form error in fixed format field',
        severity: 2,
        details: {
          'field': _getRandomFormErrorField(frameRandom),
          'bitPosition': frameRandom.nextInt(8),
        },
      ));
    }

    return errors;
  }

  /// Calculate expected CRC for comparison
  int _calculateExpectedCrc(CanFrame frame) {
    // Simplified CRC calculation (same as in CanFrame)
    int crc = frame.id ^ frame.dlc;
    for (int byte in frame.data) {
      crc ^= byte;
    }
    return crc % 256;
  }

  /// Generate a bit sequence that would cause stuffing error
  String _generateBadStuffingSequence(Random random) {
    final sequences = ['111111', '000000', '1111110', '0000001'];
    return sequences[random.nextInt(sequences.length)];
  }

  /// Get random format error field
  String _getRandomFormatErrorField(Random random) {
    final fields = ['Reserved bit r1', 'Reserved bit r0', 'IDE bit', 'RTR bit'];
    return fields[random.nextInt(fields.length)];
  }

  /// Get random overload cause
  String _getRandomOverloadCause(Random random) {
    final causes = [
      'Internal conditions',
      'External event during intermission',
      'Receiver not ready',
      'Bus timing violation'
    ];
    return causes[random.nextInt(causes.length)];
  }

  /// Get random form error field
  String _getRandomFormErrorField(Random random) {
    final fields = ['SOF', 'EOF', 'ACK delimiter', 'CRC delimiter'];
    return fields[random.nextInt(fields.length)];
  }

  /// Get error statistics for multiple frames
  Map<CanErrorType, int> getErrorStatistics(List<CanFrame> frames) {
    final stats = <CanErrorType, int>{};
    
    for (final errorType in CanErrorType.values) {
      stats[errorType] = 0;
    }

    for (final frame in frames) {
      final errors = analyzeFrame(frame);
      for (final error in errors) {
        stats[error.type] = (stats[error.type] ?? 0) + 1;
      }
    }

    return stats;
  }

  /// Check if error rate is critical
  bool isCriticalErrorRate(Map<CanErrorType, int> errorStats, int totalFrames) {
    if (totalFrames == 0) return false;
    
    final totalErrors = errorStats.values.fold(0, (sum, count) => sum + count);
    final errorRate = totalErrors / totalFrames;
    
    return errorRate > 0.15; // More than 15% error rate is critical
  }

  /// Get recommended actions based on error patterns
  List<String> getRecommendations(Map<CanErrorType, int> errorStats, int totalFrames) {
    final recommendations = <String>[];
    
    if (totalFrames == 0) return recommendations;

    final crcErrors = errorStats[CanErrorType.crcError] ?? 0;
    final stuffingErrors = errorStats[CanErrorType.stuffingError] ?? 0;
    final ackErrors = errorStats[CanErrorType.ackError] ?? 0;
    final overloadErrors = errorStats[CanErrorType.overloadError] ?? 0;

    if (crcErrors / totalFrames > 0.05) {
      recommendations.add('High CRC error rate: Check cable integrity and termination');
    }

    if (stuffingErrors / totalFrames > 0.03) {
      recommendations.add('Bit stuffing violations: Verify bus timing and clock synchronization');
    }

    if (ackErrors / totalFrames > 0.02) {
      recommendations.add('ACK errors: Check node connectivity and bus load');
    }

    if (overloadErrors / totalFrames > 0.01) {
      recommendations.add('Overload conditions: Reduce bus traffic or increase processing capacity');
    }

    return recommendations;
  }
}
import '../detection/can_error_checker.dart';
import '../models/can_frame.dart';

/// Read persisted evidence only. Never run the simulator on captured frames.
List<CanErrorInfo> recordedFrameErrors(CanFrame frame) {
  final errors = frame.errors.whereType<CanErrorInfo>().map((error) {
    const protocolTypes = {
      CanErrorType.crcError,
      CanErrorType.ackError,
      CanErrorType.stuffingError,
      CanErrorType.formError,
      CanErrorType.formatError,
    };
    if (error.origin == CanErrorOrigin.hardware &&
        protocolTypes.contains(error.type) &&
        error.details['evidenceSource'] != 'wire_error_capture') {
      return CanErrorInfo(
        type: error.type,
        description: 'Unverified legacy classification: ${error.description}',
        severity: error.severity,
        origin: CanErrorOrigin.inferred,
        timestamp: error.timestamp,
        details: {
          ...error.details,
          'originalOrigin': 'hardware',
          'evidenceVerified': false,
        },
      );
    }
    return error;
  }).toList();
  if (frame.isCorrupted &&
      !errors.any((e) => e.type == CanErrorType.crcError)) {
    errors.add(
      CanErrorInfo(
        type: CanErrorType.crcError,
        description:
            'Stored corruption flag (simulation; no wire CRC available)',
        severity: 3,
        origin: CanErrorOrigin.simulated,
        timestamp: frame.timestamp,
      ),
    );
  }
  return errors;
}

Map<CanErrorType, int> recordedErrorStatistics(Iterable<CanFrame> frames) {
  final counts = {for (final type in CanErrorType.values) type: 0};
  for (final frame in frames) {
    for (final error in recordedFrameErrors(frame)) {
      counts[error.type] = counts[error.type]! + 1;
    }
  }
  return counts;
}

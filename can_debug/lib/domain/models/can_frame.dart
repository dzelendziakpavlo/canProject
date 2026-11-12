import '../detection/can_error_checker.dart';

/// CAN Frame model representing a CAN bus message
class CanFrame {
  /// CAN Frame identifier (11-bit or 29-bit)
  final int? sequence;
  final int? receiverTimestampMs;
  final Map<String, dynamic>? rawWire;
  final int id;

  /// Data Length Code (0-8 bytes)
  final int dlc;

  /// Data payload (up to 8 bytes)
  final List<int> data;

  /// Cyclic Redundancy Check for error detection
  final int crc;

  /// Timestamp when the frame was created
  final DateTime timestamp;

  /// Flag indicating if the frame contains intentional errors
  final bool isCorrupted;

  /// Remote Transmission Request — frame has no data payload, requests data from another node
  final bool isRtr;

  /// Extended frame format — 29-bit identifier (vs standard 11-bit)
  final bool isExtended;

  /// Additional error information (will be populated by error checker)
  final List<dynamic> errors;

  CanFrame({
    this.sequence,
    this.receiverTimestampMs,
    this.rawWire,
    required this.id,
    required this.dlc,
    required this.data,
    required this.crc,
    required this.timestamp,
    this.isCorrupted = false,
    this.isRtr = false,
    this.isExtended = false,
    this.errors = const [],
  }) : assert(dlc >= 0 && dlc <= 8, 'DLC must be between 0 and 8'),
       assert(data.length <= 8, 'Data length cannot exceed 8 bytes'),
       assert(
         data.every((byte) => byte >= 0 && byte <= 255),
         'Data bytes must be 0-255',
       );

  /// Factory constructor to create a CAN frame with calculated CRC
  factory CanFrame.create({
    int? sequence,
    int? receiverTimestampMs,
    Map<String, dynamic>? rawWire,
    required int id,
    required int dlc,
    required List<int> data,
    DateTime? timestamp,
    bool isCorrupted = false,
    bool isRtr = false,
    bool isExtended = false,
    List<dynamic> errors = const [],
  }) {
    final frameTimestamp = timestamp ?? DateTime.now();
    final crc = _calculateCrc(id, dlc, data);

    return CanFrame(
      sequence: sequence,
      receiverTimestampMs: receiverTimestampMs,
      rawWire: rawWire,
      id: id,
      dlc: dlc,
      data: List.from(data),
      crc: isCorrupted ? (crc + 1) % 256 : crc,
      timestamp: frameTimestamp,
      isCorrupted: isCorrupted,
      isRtr: isRtr,
      isExtended: isExtended,
      errors: errors,
    );
  }

  /// Calculate simple CRC using XOR of all frame components
  static int _calculateCrc(int id, int dlc, List<int> data) {
    int crc = id ^ dlc;
    for (int byte in data) {
      crc ^= byte;
    }
    return crc % 256;
  }

  /// Get frame status as string
  String get status => isCorrupted
      ? 'ERROR'
      : isRtr
      ? 'RTR'
      : isExtended
      ? 'EXT'
      : 'OK';

  /// ID formatted as hex — 8 digits for 29-bit extended, 3 for standard 11-bit
  String get idHex => isExtended
      ? '0x${id.toRadixString(16).toUpperCase().padLeft(8, '0')}'
      : '0x${id.toRadixString(16).toUpperCase().padLeft(3, '0')}';

  /// Get data as hex string
  String get dataHex {
    return data
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
  }

  /// Get timestamp as formatted string
  String get timeFormatted {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}.'
        '${timestamp.millisecond.toString().padLeft(3, '0')}';
  }

  @override
  String toString() {
    return 'CanFrame(id: 0x${id.toRadixString(16).toUpperCase()}, '
        'dlc: $dlc, data: [$dataHex], crc: 0x${crc.toRadixString(16).toUpperCase()}, '
        'timestamp: $timeFormatted, status: $status)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CanFrame &&
        other.id == id &&
        other.dlc == dlc &&
        _listEquals(other.data, data) &&
        other.crc == crc &&
        other.timestamp == timestamp &&
        other.isCorrupted == isCorrupted;
  }

  @override
  int get hashCode {
    return Object.hash(id, dlc, data, crc, timestamp, isCorrupted);
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Convert to Map for JSON serialization
  Map<String, dynamic> toJson() {
    return {
      if (sequence != null) 'seq': sequence,
      if (receiverTimestampMs != null)
        'receiverTimestampMs': receiverTimestampMs,
      if (rawWire != null) 'rawWire': rawWire,
      'id': id,
      'dlc': dlc,
      'data': data,
      'crc': crc,
      if (rawWire != null)
        'crcSource': 'application_xor_placeholder_not_wire_crc',
      'timestamp': timestamp.toIso8601String(),
      'isCorrupted': isCorrupted,
      'isRtr': isRtr,
      'isExtended': isExtended,
      'errors': errors
          .whereType<CanErrorInfo>()
          .map((error) => error.toJson())
          .toList(),
    };
  }

  /// Create from Map (JSON deserialization)
  factory CanFrame.fromJson(Map<String, dynamic> json) {
    return CanFrame(
      sequence: json['seq'] as int?,
      receiverTimestampMs: json['receiverTimestampMs'] as int?,
      rawWire: (json['rawWire'] as Map?)?.cast<String, dynamic>(),
      id: json['id'],
      dlc: json['dlc'],
      data: List<int>.from(json['data']),
      crc: json['crc'],
      timestamp: DateTime.parse(json['timestamp']),
      isCorrupted: json['isCorrupted'] ?? false,
      isRtr: json['isRtr'] ?? false,
      isExtended: json['isExtended'] ?? false,
      errors:
          (json['errors'] as List?)
              ?.whereType<Map>()
              .map(
                (error) =>
                    CanErrorInfo.fromJson(Map<String, dynamic>.from(error)),
              )
              .toList() ??
          const [],
    );
  }
}

/// CAN Frame model representing a CAN bus message
class CanFrame {
  /// CAN Frame identifier (11-bit or 29-bit)
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
  
  /// Additional error information (will be populated by error checker)
  final List<dynamic> errors;

  CanFrame({
    required this.id,
    required this.dlc,
    required this.data,
    required this.crc,
    required this.timestamp,
    this.isCorrupted = false,
    this.errors = const [],
  }) : assert(dlc >= 0 && dlc <= 8, 'DLC must be between 0 and 8'),
       assert(data.length <= 8, 'Data length cannot exceed 8 bytes'),
       assert(data.every((byte) => byte >= 0 && byte <= 255), 'Data bytes must be 0-255');

  /// Factory constructor to create a CAN frame with calculated CRC
  factory CanFrame.create({
    required int id,
    required int dlc,
    required List<int> data,
    DateTime? timestamp,
    bool isCorrupted = false,
    List<dynamic> errors = const [],
  }) {
    final frameTimestamp = timestamp ?? DateTime.now();
    final crc = _calculateCrc(id, dlc, data);
    
    return CanFrame(
      id: id,
      dlc: dlc,
      data: List.from(data),
      crc: isCorrupted ? (crc + 1) % 256 : crc, // Corrupt CRC if needed
      timestamp: frameTimestamp,
      isCorrupted: isCorrupted,
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
  String get status => isCorrupted ? 'ERROR' : 'OK';

  /// Get data as hex string
  String get dataHex {
    return data.map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
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
      'id': id,
      'dlc': dlc,
      'data': data,
      'crc': crc,
      'timestamp': timestamp.toIso8601String(),
      'isCorrupted': isCorrupted,
      'errors': errors,
    };
  }

  /// Create from Map (JSON deserialization)
  factory CanFrame.fromJson(Map<String, dynamic> json) {
    return CanFrame(
      id: json['id'],
      dlc: json['dlc'],
      data: List<int>.from(json['data']),
      crc: json['crc'],
      timestamp: DateTime.parse(json['timestamp']),
      isCorrupted: json['isCorrupted'] ?? false,
      errors: json['errors'] ?? [],
    );
  }
}
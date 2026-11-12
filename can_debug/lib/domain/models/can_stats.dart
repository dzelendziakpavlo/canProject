/// TWAI hardware counters received from ESP32 RECEIVER via BLE Stats characteristic.
/// Maps directly to the `{"t":"s",...}` JSON packet.
class CanStats {
  final Map<String, dynamic>? rawWire;
  final int rxTotal;
  final int txErrorCounter; // TEC — >127 = error passive, 255 = bus-off
  final int rxErrorCounter; // REC — >127 = error passive
  final String busState; // RUNNING | BUS_OFF | RECOVERING | STOPPED
  final int rxMissed; // rx_missed_count — RX buffer overflow
  final int busErrorCount; // cumulative bit/stuff/CRC/form/ACK errors
  final int arbLostCount; // arbitration lost count (multiple senders competing)
  final int txFailedCount; // aggregate failed TX count; subtype unavailable
  final int
  rxOverrunCount; // hardware RX overrun (buffer full, frame dropped at TWAI level)
  final bool isNoAckMode; // firmware mode flag; does not prove missing ACK
  final bool
  isSpeedMismatchDemo; // SENDER at 250k, RECEIVER at 500k → stuffing/format errors
  final int telemetrySchema;
  final String nodeName;
  final String firmwareVersion;
  final int? uptimeMs;
  final int? bitrate;
  final String? reasonCode;
  final DateTime timestamp;

  const CanStats({
    this.rawWire,
    required this.rxTotal,
    required this.txErrorCounter,
    required this.rxErrorCounter,
    required this.busState,
    required this.rxMissed,
    required this.busErrorCount,
    required this.arbLostCount,
    required this.txFailedCount,
    required this.rxOverrunCount,
    required this.isNoAckMode,
    required this.isSpeedMismatchDemo,
    this.telemetrySchema = 1,
    this.nodeName = 'receiver',
    this.firmwareVersion = 'unknown',
    this.uptimeMs,
    this.bitrate,
    this.reasonCode,
    required this.timestamp,
  });

  bool get isBusOff => busState == 'BUS_OFF';
  bool get isRecovering => busState == 'RECOVERING';
  bool get isRunning => busState == 'RUNNING';
  // TEC or REC > 127 means the node entered error-passive state per CAN spec.
  // TWAI keeps state=RUNNING until TEC > 255 (bus-off), so we check counters directly.
  bool get isErrorPassive => txErrorCounter > 127 || rxErrorCounter > 127;

  // TEC or REC in 96–127 range: Error Warning level (ISO 11898-1 §6.15).
  // Node is still error-active but approaching the passive threshold.
  bool get isErrorWarning =>
      !isErrorPassive && (txErrorCounter > 96 || rxErrorCounter > 96);

  factory CanStats.fromJson(Map<String, dynamic> json) => CanStats(
    rawWire: Map<String, dynamic>.from(json),
    rxTotal: json['rx'] as int,
    txErrorCounter: json['txe'] as int,
    rxErrorCounter: json['rxe'] as int,
    busState: json['state'] as String,
    rxMissed: json['missed'] as int,
    busErrorCount: json['buserr'] as int,
    arbLostCount: (json['arb'] as int?) ?? 0,
    txFailedCount: (json['txfail'] as int?) ?? 0,
    rxOverrunCount: (json['ovr'] as int?) ?? 0,
    isNoAckMode: (json['noack'] as int?) == 1,
    isSpeedMismatchDemo: (json['sdemo'] as int?) == 1,
    telemetrySchema: (json['v'] as int?) ?? 1,
    nodeName: (json['node'] as String?) ?? 'receiver',
    firmwareVersion: (json['fw'] as String?) ?? 'unknown',
    uptimeMs: json['uptime'] as int?,
    bitrate: json['bitrate'] as int?,
    reasonCode: json['reason'] as String?,
    timestamp: DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    if (rawWire != null) 'rawWire': rawWire,
    'rx': rxTotal,
    'txe': txErrorCounter,
    'rxe': rxErrorCounter,
    'state': busState,
    'missed': rxMissed,
    'buserr': busErrorCount,
    'arb': arbLostCount,
    'txfail': txFailedCount,
    'ovr': rxOverrunCount,
    'noack': isNoAckMode ? 1 : 0,
    'sdemo': isSpeedMismatchDemo ? 1 : 0,
    'v': telemetrySchema,
    'node': nodeName,
    'fw': firmwareVersion,
    if (uptimeMs != null) 'uptime': uptimeMs,
    if (bitrate != null) 'bitrate': bitrate,
    if (reasonCode != null) 'reason': reasonCode,
    'timestamp': timestamp.toIso8601String(),
  };

  factory CanStats.fromStoredJson(Map<String, dynamic> json) => CanStats(
    rawWire: (json['rawWire'] as Map?)?.cast<String, dynamic>(),
    rxTotal: json['rx'] as int,
    txErrorCounter: json['txe'] as int,
    rxErrorCounter: json['rxe'] as int,
    busState: json['state'] as String,
    rxMissed: json['missed'] as int,
    busErrorCount: json['buserr'] as int,
    arbLostCount: json['arb'] as int,
    txFailedCount: json['txfail'] as int,
    rxOverrunCount: json['ovr'] as int,
    isNoAckMode: (json['noack'] as int?) == 1,
    isSpeedMismatchDemo: (json['sdemo'] as int?) == 1,
    telemetrySchema: (json['v'] as int?) ?? 1,
    nodeName: (json['node'] as String?) ?? 'receiver',
    firmwareVersion: (json['fw'] as String?) ?? 'unknown',
    uptimeMs: json['uptime'] as int?,
    bitrate: json['bitrate'] as int?,
    reasonCode: json['reason'] as String?,
    timestamp: DateTime.parse(json['timestamp'] as String),
  );

  @override
  String toString() =>
      'CanStats(state:$busState rx:$rxTotal tec:$txErrorCounter rec:$rxErrorCounter '
      'missed:$rxMissed buserr:$busErrorCount arb:$arbLostCount '
      'txfail:$txFailedCount ovr:$rxOverrunCount)';
}

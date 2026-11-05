import 'dart:convert';

/// Normalized event stored inside a CAN monitoring session.
///
/// This keeps session history source-agnostic so live BLE, simulator, and
/// replay can all append the same event shape.
enum CanSessionEventType {
  sourceStarted,
  sourceStopped,
  sourceStateChanged,
  statsSnapshot,
  frameBatch,
  errorDetected,
  diagnostic,
  note,
}

enum DiagnosticSeverity { info, warning, error, critical }

enum DiagnosticCause {
  unknown,
  termination,
  baudMismatch,
  busNoise,
  bleLoss,
  transportLoss,
  rxOverflow,
  busOff,
  arbitrationLost,
  silentBus,
}

class CanSessionEvent {
  final String id;
  final CanSessionEventType type;
  final DateTime timestamp;
  final String message;
  final String? sourceName;
  final DiagnosticSeverity diagnosticSeverity;
  final DiagnosticCause diagnosticCause;
  final String? explanation;
  final String? recommendation;
  final Map<String, dynamic> data;

  const CanSessionEvent({
    required this.id,
    required this.type,
    required this.timestamp,
    required this.message,
    this.sourceName,
    this.diagnosticSeverity = DiagnosticSeverity.info,
    this.diagnosticCause = DiagnosticCause.unknown,
    this.explanation,
    this.recommendation,
    this.data = const {},
  });

  factory CanSessionEvent.create({
    required CanSessionEventType type,
    required String message,
    String? sourceName,
    DiagnosticSeverity diagnosticSeverity = DiagnosticSeverity.info,
    DiagnosticCause diagnosticCause = DiagnosticCause.unknown,
    String? explanation,
    String? recommendation,
    Map<String, dynamic> data = const {},
    DateTime? timestamp,
  }) {
    return CanSessionEvent(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: type,
      timestamp: timestamp ?? DateTime.now(),
      message: message,
      sourceName: sourceName,
      diagnosticSeverity: diagnosticSeverity,
      diagnosticCause: diagnosticCause,
      explanation: explanation,
      recommendation: recommendation,
      data: Map<String, dynamic>.from(data),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'timestamp': timestamp.toIso8601String(),
      'message': message,
      'sourceName': sourceName,
      'diagnosticSeverity': diagnosticSeverity.name,
      'diagnosticCause': diagnosticCause.name,
      'explanation': explanation,
      'recommendation': recommendation,
      'data': data,
    };
  }

  factory CanSessionEvent.fromJson(Map<String, dynamic> json) {
    return CanSessionEvent(
      id: json['id'] as String,
      type: CanSessionEventType.values.firstWhere(
        (eventType) => eventType.name == json['type'],
        orElse: () => CanSessionEventType.note,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
      message: json['message'] as String? ?? '',
      sourceName: json['sourceName'] as String?,
      diagnosticSeverity: DiagnosticSeverity.values.firstWhere(
        (severity) => severity.name == json['diagnosticSeverity'],
        orElse: () => DiagnosticSeverity.info,
      ),
      diagnosticCause: DiagnosticCause.values.firstWhere(
        (cause) => cause.name == json['diagnosticCause'],
        orElse: () => DiagnosticCause.unknown,
      ),
      explanation: json['explanation'] as String?,
      recommendation: json['recommendation'] as String?,
      data: (json['data'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value),
          ) ??
          const {},
    );
  }

  @override
  String toString() => jsonEncode(toJson());
}

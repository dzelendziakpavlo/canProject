import 'can_frame.dart';
import 'can_stats.dart';
import 'can_session_event.dart';
import '../detection/can_error_checker.dart';

/// Модель сесії CAN моніторингу
class CanSession {
  static const int currentSchemaVersion = 3;

  final Map<String, dynamic> captureMetadata;
  final String id;
  final String name;
  final String? sourceName;
  final int schemaVersion;
  final DateTime startTime;
  final DateTime? endTime;
  final List<CanFrame> frames;
  final List<CanStats> statsSnapshots;
  final List<CanSessionEvent> events;
  final Map<CanErrorType, int> errorStats;
  final int totalFrames;
  final int errorFrames;
  final double errorRate;
  final bool isActive;

  const CanSession({
    this.captureMetadata = const {},
    required this.id,
    required this.name,
    this.sourceName,
    this.schemaVersion = currentSchemaVersion,
    required this.startTime,
    this.endTime,
    required this.frames,
    this.statsSnapshots = const [],
    this.events = const [],
    required this.errorStats,
    required this.totalFrames,
    required this.errorFrames,
    required this.errorRate,
    this.isActive = false,
  });

  /// Створити нову активну сесію
  factory CanSession.create(String name) {
    return CanSession(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      sourceName: null,
      schemaVersion: currentSchemaVersion,
      startTime: DateTime.now(),
      frames: [],
      statsSnapshots: const [],
      events: const [],
      errorStats: {for (var type in CanErrorType.values) type: 0},
      totalFrames: 0,
      errorFrames: 0,
      errorRate: 0.0,
      isActive: true,
    );
  }

  /// Оновити сесію з новими даними
  CanSession updateWith({
    Map<String, dynamic>? captureMetadata,
    String? sourceName,
    List<CanFrame>? frames,
    List<CanStats>? statsSnapshots,
    List<CanSessionEvent>? events,
    Map<CanErrorType, int>? errorStats,
    int? totalFrames,
    int? errorFrames,
    double? errorRate,
    int? schemaVersion,
  }) {
    return CanSession(
      captureMetadata: captureMetadata ?? this.captureMetadata,
      id: id,
      name: name,
      sourceName: sourceName ?? this.sourceName,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      startTime: startTime,
      endTime: endTime,
      frames: frames ?? this.frames,
      statsSnapshots: statsSnapshots ?? this.statsSnapshots,
      events: events ?? this.events,
      errorStats: errorStats ?? this.errorStats,
      totalFrames: totalFrames ?? this.totalFrames,
      errorFrames: errorFrames ?? this.errorFrames,
      errorRate: errorRate ?? this.errorRate,
      isActive: isActive,
    );
  }

  /// Завершити сесію
  CanSession complete() {
    return CanSession(
      captureMetadata: captureMetadata,
      id: id,
      name: name,
      sourceName: sourceName,
      schemaVersion: schemaVersion,
      startTime: startTime,
      endTime: DateTime.now(),
      frames: frames,
      statsSnapshots: statsSnapshots,
      events: events,
      errorStats: errorStats,
      totalFrames: totalFrames,
      errorFrames: errorFrames,
      errorRate: errorRate,
      isActive: false,
    );
  }

  /// Тривалість сесії
  Duration get duration {
    final end = endTime ?? DateTime.now();
    return end.difference(startTime);
  }

  /// Форматована тривалість
  String get formattedDuration {
    final d = duration;
    final hours = d.inHours;
    final minutes = (d.inMinutes % 60);
    final seconds = (d.inSeconds % 60);

    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  /// Отримати рівень критичності сесії
  SessionSeverity get severity {
    if (errorRate > 20) return SessionSeverity.critical;
    if (errorRate > 15) return SessionSeverity.high;
    if (errorRate > 10) return SessionSeverity.medium;
    if (errorRate > 5) return SessionSeverity.low;
    return SessionSeverity.normal;
  }

  /// Конвертація до Map для збереження
  Map<String, dynamic> toJson() {
    return {
      'captureMetadata': captureMetadata,
      'id': id,
      'name': name,
      'sourceName': sourceName,
      'schemaVersion': schemaVersion,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime?.toIso8601String(),
      'frames': frames.map((f) => f.toJson()).toList(),
      'statsSnapshots': statsSnapshots.map((stats) => stats.toJson()).toList(),
      'events': events.map((event) => event.toJson()).toList(),
      'errorStats': errorStats.map((k, v) => MapEntry(k.toString(), v)),
      'totalFrames': totalFrames,
      'errorFrames': errorFrames,
      'errorRate': errorRate,
      'isActive': isActive,
    };
  }

  /// Створення з Map
  factory CanSession.fromJson(Map<String, dynamic> json) {
    final rawSchemaVersion = json['schemaVersion'];
    final parsedSchemaVersion = rawSchemaVersion is int
        ? rawSchemaVersion
        : int.tryParse(rawSchemaVersion?.toString() ?? '') ?? 1;

    return CanSession(
      captureMetadata:
          (json['captureMetadata'] as Map?)?.cast<String, dynamic>() ??
          const {},
      id: json['id'],
      name: json['name'],
      sourceName: json['sourceName'] as String?,
      schemaVersion: parsedSchemaVersion,
      startTime: DateTime.parse(json['startTime']),
      endTime: json['endTime'] != null ? DateTime.parse(json['endTime']) : null,
      frames:
          (json['frames'] as List?)
              ?.map((f) => CanFrame.fromJson(f))
              .toList() ??
          [],
      statsSnapshots:
          (json['statsSnapshots'] as List?)
              ?.map(
                (stats) => CanStats.fromStoredJson(
                  Map<String, dynamic>.from(stats as Map),
                ),
              )
              .toList() ??
          const [],
      events:
          (json['events'] as List?)
              ?.map(
                (event) => CanSessionEvent.fromJson(
                  Map<String, dynamic>.from(event as Map),
                ),
              )
              .toList() ??
          const [],
      errorStats:
          (json['errorStats'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(
              CanErrorType.values.firstWhere(
                (e) => e.toString() == k || e.name == k,
                orElse: () => CanErrorType.none,
              ),
              v as int,
            ),
          ) ??
          {for (var type in CanErrorType.values) type: 0},
      totalFrames: json['totalFrames'] ?? 0,
      errorFrames: json['errorFrames'] ?? 0,
      errorRate: (json['errorRate'] ?? 0.0).toDouble(),
      isActive: json['isActive'] ?? false,
    );
  }
}

/// Рівні критичності сесії
enum SessionSeverity { normal, low, medium, high, critical }

/// Розширення для SessionSeverity
extension SessionSeverityExtension on SessionSeverity {
  String get displayName {
    switch (this) {
      case SessionSeverity.normal:
        return 'Normal';
      case SessionSeverity.low:
        return 'Low Risk';
      case SessionSeverity.medium:
        return 'Medium Risk';
      case SessionSeverity.high:
        return 'High Risk';
      case SessionSeverity.critical:
        return 'Critical';
    }
  }

  String get description {
    switch (this) {
      case SessionSeverity.normal:
        return 'All systems operating normally';
      case SessionSeverity.low:
        return 'Minor issues detected';
      case SessionSeverity.medium:
        return 'Moderate error rate observed';
      case SessionSeverity.high:
        return 'Significant problems detected';
      case SessionSeverity.critical:
        return 'Critical system errors - immediate attention required';
    }
  }
}

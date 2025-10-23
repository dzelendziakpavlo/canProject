import 'can_frame.dart';
import '../detection/can_error_checker.dart';

/// Модель сесії CAN моніторингу
class CanSession {
  final String id;
  final String name;
  final DateTime startTime;
  final DateTime? endTime;
  final List<CanFrame> frames;
  final Map<CanErrorType, int> errorStats;
  final int totalFrames;
  final int errorFrames;
  final double errorRate;
  final bool isActive;

  const CanSession({
    required this.id,
    required this.name,
    required this.startTime,
    this.endTime,
    required this.frames,
    required this.errorStats,
    required this.totalFrames,
    required this.errorFrames,
    required this.errorRate,
    this.isActive = false,
  });

  /// Створити нову активну сесію
  factory CanSession.create(String name) {
    return CanSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      startTime: DateTime.now(),
      frames: [],
      errorStats: {for (var type in CanErrorType.values) type: 0},
      totalFrames: 0,
      errorFrames: 0,
      errorRate: 0.0,
      isActive: true,
    );
  }

  /// Оновити сесію з новими даними
  CanSession updateWith({
    List<CanFrame>? frames,
    Map<CanErrorType, int>? errorStats,
    int? totalFrames,
    int? errorFrames,
    double? errorRate,
  }) {
    return CanSession(
      id: id,
      name: name,
      startTime: startTime,
      endTime: endTime,
      frames: frames ?? this.frames,
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
      id: id,
      name: name,
      startTime: startTime,
      endTime: DateTime.now(),
      frames: frames,
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
      'id': id,
      'name': name,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime?.toIso8601String(),
      'frames': frames.map((f) => f.toJson()).toList(),
      'errorStats': errorStats.map((k, v) => MapEntry(k.toString(), v)),
      'totalFrames': totalFrames,
      'errorFrames': errorFrames,
      'errorRate': errorRate,
      'isActive': isActive,
    };
  }

  /// Створення з Map
  factory CanSession.fromJson(Map<String, dynamic> json) {
    return CanSession(
      id: json['id'],
      name: json['name'],
      startTime: DateTime.parse(json['startTime']),
      endTime: json['endTime'] != null ? DateTime.parse(json['endTime']) : null,
      frames: (json['frames'] as List?)?.map((f) => CanFrame.fromJson(f)).toList() ?? [],
      errorStats: (json['errorStats'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(
          CanErrorType.values.firstWhere((e) => e.toString() == k),
          v as int,
        ),
      ) ?? {for (var type in CanErrorType.values) type: 0},
      totalFrames: json['totalFrames'] ?? 0,
      errorFrames: json['errorFrames'] ?? 0,
      errorRate: (json['errorRate'] ?? 0.0).toDouble(),
      isActive: json['isActive'] ?? false,
    );
  }
}

/// Рівні критичності сесії
enum SessionSeverity {
  normal,
  low,
  medium,
  high,
  critical,
}

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
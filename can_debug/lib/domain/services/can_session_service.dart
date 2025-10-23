import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/can_session.dart';
import '../models/can_frame.dart';
import '../detection/can_error_checker.dart';

/// Сервіс для управління CAN сесіями
class CanSessionService {
  static const String _sessionsKey = 'can_sessions';
  static const String _sessionCounterKey = 'session_counter';
  
  static CanSessionService? _instance;
  static CanSessionService get instance => _instance ??= CanSessionService._();
  
  CanSessionService._();

  CanSession? _currentSession;
  final List<CanSession> _savedSessions = [];
  final StreamController<List<CanSession>> _sessionsController = 
      StreamController<List<CanSession>>.broadcast();

  /// Stream сесій
  Stream<List<CanSession>> get sessionsStream => _sessionsController.stream;

  /// Список збережених сесій
  List<CanSession> get savedSessions => List.unmodifiable(_savedSessions);

  /// Поточна активна сесія
  CanSession? get currentSession => _currentSession;

  /// Ініціалізація сервісу
  Future<void> initialize() async {
    await _loadSessions();
  }

  /// Створити нову сесію
  Future<CanSession> createSession() async {
    final sessionNumber = await _getNextSessionNumber();
    final sessionName = 'Schema $sessionNumber';
    
    _currentSession = CanSession.create(sessionName);
    return _currentSession!;
  }

  /// Оновити поточну сесію
  void updateCurrentSession({
    required List<CanFrame> frames,
    required Map<CanErrorType, int> errorStats,
    required int totalFrames,
    required int errorFrames,
    required double errorRate,
  }) {
    if (_currentSession == null) return;

    _currentSession = _currentSession!.updateWith(
      frames: List.from(frames),
      errorStats: Map.from(errorStats),
      totalFrames: totalFrames,
      errorFrames: errorFrames,
      errorRate: errorRate,
    );
  }

  /// Завершити поточну сесію та зберегти
  Future<void> completeCurrentSession() async {
    if (_currentSession == null) return;

    final completedSession = _currentSession!.complete();
    _savedSessions.insert(0, completedSession); // Додати на початок списку
    _currentSession = null;

    await _saveSessions();
    _sessionsController.add(_savedSessions);
  }

  /// Видалити сесію
  Future<void> deleteSession(String sessionId) async {
    _savedSessions.removeWhere((session) => session.id == sessionId);
    await _saveSessions();
    _sessionsController.add(_savedSessions);
  }

  /// Очистити всі сесії
  Future<void> clearAllSessions() async {
    _savedSessions.clear();
    await _saveSessions();
    _sessionsController.add(_savedSessions);
  }

  /// Отримати сесію за ID
  CanSession? getSessionById(String id) {
    try {
      return _savedSessions.firstWhere((session) => session.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Отримати статистику всіх сесій
  SessionsAnalytics getOverallAnalytics() {
    if (_savedSessions.isEmpty) {
      return SessionsAnalytics.empty();
    }

    final totalSessions = _savedSessions.length;
    final totalFrames = _savedSessions.fold<int>(0, (sum, session) => sum + session.totalFrames);
    final totalErrors = _savedSessions.fold<int>(0, (sum, session) => sum + session.errorFrames);
    final averageErrorRate = _savedSessions.fold<double>(0, (sum, session) => sum + session.errorRate) / totalSessions;
    
    final severityCounts = <SessionSeverity, int>{};
    for (final severity in SessionSeverity.values) {
      severityCounts[severity] = _savedSessions.where((s) => s.severity == severity).length;
    }

    final totalDuration = _savedSessions.fold<Duration>(
      Duration.zero,
      (sum, session) => sum + session.duration,
    );

    return SessionsAnalytics(
      totalSessions: totalSessions,
      totalFrames: totalFrames,
      totalErrors: totalErrors,
      averageErrorRate: averageErrorRate,
      severityCounts: severityCounts,
      totalDuration: totalDuration,
    );
  }

  /// Завантажити сесії з збереження
  Future<void> _loadSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionsJson = prefs.getString(_sessionsKey);
      
      if (sessionsJson != null) {
        final List<dynamic> sessionsList = jsonDecode(sessionsJson);
        _savedSessions.clear();
        _savedSessions.addAll(
          sessionsList.map((json) => CanSession.fromJson(json)).toList(),
        );
        _sessionsController.add(_savedSessions);
      }
    } catch (e) {
      print('Error loading sessions: $e');
    }
  }

  /// Зберегти сесії
  Future<void> _saveSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionsJson = jsonEncode(_savedSessions.map((s) => s.toJson()).toList());
      await prefs.setString(_sessionsKey, sessionsJson);
    } catch (e) {
      print('Error saving sessions: $e');
    }
  }

  /// Отримати наступний номер сесії
  Future<int> _getNextSessionNumber() async {
    final prefs = await SharedPreferences.getInstance();
    final currentCounter = prefs.getInt(_sessionCounterKey) ?? 0;
    final nextCounter = currentCounter + 1;
    await prefs.setInt(_sessionCounterKey, nextCounter);
    return nextCounter;
  }

  /// Очистити ресурси
  void dispose() {
    _sessionsController.close();
  }
}

/// Аналітика сесій
class SessionsAnalytics {
  final int totalSessions;
  final int totalFrames;
  final int totalErrors;
  final double averageErrorRate;
  final Map<SessionSeverity, int> severityCounts;
  final Duration totalDuration;

  const SessionsAnalytics({
    required this.totalSessions,
    required this.totalFrames,
    required this.totalErrors,
    required this.averageErrorRate,
    required this.severityCounts,
    required this.totalDuration,
  });

  factory SessionsAnalytics.empty() {
    return SessionsAnalytics(
      totalSessions: 0,
      totalFrames: 0,
      totalErrors: 0,
      averageErrorRate: 0.0,
      severityCounts: {for (var s in SessionSeverity.values) s: 0},
      totalDuration: Duration.zero,
    );
  }

  /// Форматована загальна тривалість
  String get formattedTotalDuration {
    final hours = totalDuration.inHours;
    final minutes = (totalDuration.inMinutes % 60);
    
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else {
      return '${minutes}m';
    }
  }
}
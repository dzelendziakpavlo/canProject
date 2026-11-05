import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/can_session.dart';
import '../models/can_frame.dart';
import '../models/can_stats.dart';
import '../models/can_session_event.dart';
import '../models/can_session_summary.dart';
import '../detection/can_error_checker.dart';
import 'session_summary_builder.dart';

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

  final SessionSummaryBuilder _summaryBuilder = SessionSummaryBuilder();

  /// Ініціалізація сервісу
  Future<void> initialize() async {
    await _loadSessions();
  }

  /// Створити нову сесію
  Future<CanSession> createSession({String? sourceName}) async {
    final sessionNumber = await _getNextSessionNumber();
    final sessionName = 'Schema $sessionNumber';
    
    _currentSession = CanSession.create(sessionName).updateWith(
      sourceName: sourceName,
    );
    return _currentSession!;
  }

  /// Оновити поточну сесію
  void updateCurrentSession({
    String? sourceName,
    required List<CanFrame> frames,
    List<CanStats>? statsSnapshots,
    List<CanSessionEvent>? events,
    required Map<CanErrorType, int> errorStats,
    required int totalFrames,
    required int errorFrames,
    required double errorRate,
  }) {
    if (_currentSession == null) return;

    _currentSession = _currentSession!.updateWith(
      sourceName: sourceName,
      frames: List.from(frames),
      statsSnapshots: statsSnapshots != null ? List.from(statsSnapshots) : null,
      events: events != null ? List.from(events) : null,
      errorStats: Map.from(errorStats),
      totalFrames: totalFrames,
      errorFrames: errorFrames,
      errorRate: errorRate,
    );
  }

  /// Додати подію до поточної сесії
  void recordSessionEvent(CanSessionEvent event) {
    if (_currentSession == null) return;

    final updatedEvents = List<CanSessionEvent>.from(_currentSession!.events)..add(event);
    // Complete USB wire history is on disk; bound the live analysis snapshot.
    if (_currentSession!.sourceName?.startsWith('USB Serial') == true && updatedEvents.length > 2000) {
      updatedEvents.removeRange(0, updatedEvents.length - 2000);
    }
    _currentSession = _currentSession!.updateWith(events: updatedEvents);
  }

  /// Додати знімок стану TWAI до поточної сесії
  void recordStatsSnapshot(CanStats stats) {
    if (_currentSession == null) return;

    final updatedSnapshots = List<CanStats>.from(_currentSession!.statsSnapshots)..add(stats);
    if (_currentSession!.sourceName?.startsWith('USB Serial') == true && updatedSnapshots.length > 600) {
      updatedSnapshots.removeRange(0, updatedSnapshots.length - 600);
    }
    _currentSession = _currentSession!.updateWith(statsSnapshots: updatedSnapshots);
  }

  /// Побудувати derived summary для будь-якої сесії.
  CanSessionSummary buildSessionSummary(CanSession session) {
    return _summaryBuilder.build(session);
  }

  /// Derived summary поточної активної сесії, якщо вона існує.
  CanSessionSummary? get currentSessionSummary {
    final session = _currentSession;
    if (session == null) return null;
    return buildSessionSummary(session);
  }

  /// Derived summary для збереженої сесії.
  CanSessionSummary? getSessionSummaryById(String sessionId) {
    final session = getSessionById(sessionId);
    if (session == null) return null;
    return buildSessionSummary(session);
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

  /// Додати імпортовану сесію в збереження
  Future<void> addImportedSession(CanSession session) async {
    // If a session with same id exists, create a new id and mark as imported
    final exists = _savedSessions.any((s) => s.id == session.id);
    CanSession toSave = session;
    if (exists) {
      final Map<String, dynamic> map = session.toJson();
      map['id'] = DateTime.now().millisecondsSinceEpoch.toString();
      map['name'] = '${session.name} (imported)';
      toSave = CanSession.fromJson(map);
    }

    _savedSessions.insert(0, toSave);
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

        final needsMigration = _savedSessions.any(
          (session) => session.schemaVersion < CanSession.currentSchemaVersion,
        );
        if (needsMigration) {
          _savedSessions.replaceRange(
            0,
            _savedSessions.length,
            _savedSessions
                .map(
                  (session) => session.updateWith(
                    schemaVersion: CanSession.currentSchemaVersion,
                  ),
                )
                .toList(),
          );
          await _saveSessions();
        }
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

  /// Відкинути поточну сесію без збереження
  /// Використовується коли користувач відмовляється зберігати сесію
  void discardCurrentSession() {
    _currentSession = null;
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

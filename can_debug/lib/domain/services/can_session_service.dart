import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../data/ble_capture_database.dart';
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

  CanSessionService._()
    : _store = BleCaptureDatabase(),
      _enableBleStorage = Platform.isAndroid;
  CanSessionService.forTesting(BleCaptureDatabase store)
    : _store = store,
      _enableBleStorage = true;
  final BleCaptureDatabase _store;
  final bool _enableBleStorage;
  BleCaptureWriter? _writer;
  Object? persistenceError;
  bool _initialized = false;
  Map<String, dynamic> get persistenceDiagnostics =>
      _writer?.diagnostics ?? const {};
  bool get isStreamingToDatabase => _writer != null;
  void recordAcceptedFrame(CanFrame frame) => _writer?.frame(frame);
  void updateCaptureMetadata(Map<String, dynamic> metadata) {
    if (_currentSession != null) {
      _currentSession = _currentSession!.updateWith(
        captureMetadata: {..._currentSession!.captureMetadata, ...metadata},
      );
    }
  }

  Future<void> checkpoint() async {
    await _writer?.flush();
  }

  Future<CanSession> readStoredSession(CanSession fallback) async {
    if (fallback.captureMetadata['storage'] != 'sqlite') return fallback;
    return await _store.read(fallback.id) ??
        (throw StateError('Stored session missing: ${fallback.id}'));
  }

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
    if (_initialized) return;
    await _loadSessions();
    if (_enableBleStorage) {
      final captures = await _store.previews();
      final ids = captures.map((s) => s.id).toSet();
      _savedSessions.removeWhere((s) => ids.contains(s.id));
      _savedSessions.addAll(captures);
      _savedSessions.sort((a, b) => b.startTime.compareTo(a.startTime));
      _sessionsController.add(savedSessions);
    }
    _initialized = true;
  }

  /// Створити нову сесію
  Future<CanSession> createSession({String? sourceName}) async {
    if (_currentSession != null) {
      throw StateError('Finish the active session before starting another');
    }
    await initialize();
    persistenceError = null;
    final sessionNumber = await _getNextSessionNumber();
    final sessionName = 'Schema $sessionNumber';

    _currentSession = CanSession.create(
      sessionName,
    ).updateWith(sourceName: sourceName);
    if (_enableBleStorage && sourceName?.startsWith('BLE') == true) {
      _currentSession = _currentSession!.updateWith(
        captureMetadata: {
          'storage': 'sqlite',
          'captureScope': 'all accepted BLE messages',
        },
      );
      try {
        await _store.begin(_currentSession!);
        _writer = BleCaptureWriter(
          store: _store,
          session: () => _currentSession!,
          onError: (e) => persistenceError = e,
        );
      } catch (e) {
        _currentSession = null;
        persistenceError = e;
        rethrow;
      }
    }
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
      totalFrames: _writer?.receivedFrames ?? totalFrames,
      errorFrames: errorFrames,
      errorRate: errorRate,
    );
  }

  /// Додати подію до поточної сесії
  void recordSessionEvent(CanSessionEvent event) {
    if (_currentSession == null) return;

    _writer?.event(event);
    final updatedEvents = List<CanSessionEvent>.from(_currentSession!.events)
      ..add(event);
    // Complete USB wire history is on disk; bound the live analysis snapshot.
    if ((_writer != null ||
            _currentSession!.sourceName?.startsWith('USB Serial') == true) &&
        updatedEvents.length > 2000) {
      updatedEvents.removeRange(0, updatedEvents.length - 2000);
    }
    _currentSession = _currentSession!.updateWith(events: updatedEvents);
  }

  /// Додати знімок стану TWAI до поточної сесії
  void recordStatsSnapshot(CanStats stats) {
    if (_currentSession == null) return;

    _writer?.stats(stats);
    final updatedSnapshots = List<CanStats>.from(
      _currentSession!.statsSnapshots,
    )..add(stats);
    if ((_writer != null ||
            _currentSession!.sourceName?.startsWith('USB Serial') == true) &&
        updatedSnapshots.length > 600) {
      updatedSnapshots.removeRange(0, updatedSnapshots.length - 600);
    }
    _currentSession = _currentSession!.updateWith(
      statsSnapshots: updatedSnapshots,
    );
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

    final completedSession = _currentSession!
        .updateWith(
          captureMetadata: {
            ..._currentSession!.captureMetadata,
            ...persistenceDiagnostics,
          },
        )
        .complete();
    if (_writer != null) {
      await _writer!.close(completedSession);
      final stored = await _store.read(completedSession.id, preview: true);
      _savedSessions.insert(0, stored!);
      _writer = null;
    } else {
      final prefs = await SharedPreferences.getInstance();
      final sessions = [
        completedSession,
        ..._savedSessions,
      ].where((s) => s.captureMetadata['storage'] != 'sqlite').toList();
      if (!await prefs.setString(
        _sessionsKey,
        jsonEncode(sessions.map((s) => s.toJson()).toList()),
      )) {
        throw StateError('Session storage rejected the write');
      }
      _savedSessions.insert(0, completedSession);
    }
    _currentSession = null;
    _sessionsController.add(savedSessions);
  }

  /// Видалити сесію
  Future<void> deleteSession(String sessionId) async {
    if (_enableBleStorage) await _store.delete(sessionId);
    _savedSessions.removeWhere((session) => session.id == sessionId);
    await _saveSessions();
    _sessionsController.add(_savedSessions);
  }

  /// Очистити всі сесії
  Future<void> clearAllSessions() async {
    if (_enableBleStorage) {
      for (final session in _savedSessions) {
        if (session.captureMetadata['storage'] == 'sqlite') {
          await _store.delete(session.id);
        }
      }
    }
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
      map['id'] = DateTime.now().microsecondsSinceEpoch.toString();
      map['name'] = '${session.name} (imported)';
      toSave = CanSession.fromJson(map);
    }

    toSave = toSave.updateWith(
      captureMetadata: {
        ...toSave.captureMetadata,
        'storage': 'imported_snapshot',
      },
    );
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
    final totalFrames = _savedSessions.fold<int>(
      0,
      (sum, session) => sum + session.totalFrames,
    );
    final totalErrors = _savedSessions.fold<int>(
      0,
      (sum, session) => sum + session.errorFrames,
    );
    final averageErrorRate =
        _savedSessions.fold<double>(
          0,
          (sum, session) => sum + session.errorRate,
        ) /
        totalSessions;

    final severityCounts = <SessionSeverity, int>{};
    for (final severity in SessionSeverity.values) {
      severityCounts[severity] = _savedSessions
          .where((s) => s.severity == severity)
          .length;
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
      persistenceError = e;
      rethrow;
    }
  }

  /// Зберегти сесії
  Future<void> _saveSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionsJson = jsonEncode(
        _savedSessions
            .where((s) => s.captureMetadata['storage'] != 'sqlite')
            .map((s) => s.toJson())
            .toList(),
      );
      if (!await prefs.setString(_sessionsKey, sessionsJson)) {
        throw StateError('Session storage rejected the write');
      }
    } catch (e) {
      persistenceError = e;
      rethrow;
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
  Future<void> discardCurrentSession() async {
    final writer = _writer;
    final id = _currentSession?.id;
    if (writer != null) {
      await writer.flush();
      writer.abandon();
      if (id != null) await _store.delete(id);
    }
    _writer = null;
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

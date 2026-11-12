import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../domain/models/can_frame.dart';
import '../domain/models/can_session.dart';
import '../domain/models/can_session_event.dart';
import '../domain/models/can_stats.dart';
import '../domain/services/recorded_frame_errors.dart';
import '../domain/detection/can_error_checker.dart';

/// New BLE recordings only. Legacy SharedPreferences and the users DB are
/// retained. One transaction commits records, counters and metadata together.
class BleCaptureDatabase {
  BleCaptureDatabase({Future<Database> Function()? open}) : _open = open;
  final Future<Database> Function()? _open;
  Future<Database>? _database;
  Future<Database> get database => _database ??= _initialize();

  Future<Database> _initialize() async {
    if (_open != null) return _open();
    final path = '${await getDatabasesPath()}/can_capture.db';
    return openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.execute('PRAGMA synchronous = FULL');
      },
      onCreate: createSchema,
    );
  }

  static Future<void> createSchema(Database db, int version) async {
    await db.execute(
      'CREATE TABLE captures (id TEXT PRIMARY KEY, metadata TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE capture_records ('
      'session_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE, '
      'ordinal INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, '
      'PRIMARY KEY(session_id, ordinal))',
    );
    await db.execute(
      'CREATE INDEX capture_kind ON capture_records(session_id, kind, ordinal)',
    );
  }

  static Map<String, dynamic> metadata(CanSession session) => {
    'id': session.id,
    'name': session.name,
    'sourceName': session.sourceName,
    'schemaVersion': session.schemaVersion,
    'startTime': session.startTime.toIso8601String(),
    'endTime': session.endTime?.toIso8601String(),
    'isActive': session.isActive,
    'captureMetadata': session.captureMetadata,
    'totalFrames': session.totalFrames,
    'errorFrames': session.errorFrames,
    'errorRate': session.errorRate,
    'errorStats': session.errorStats.map((k, v) => MapEntry(k.toString(), v)),
    'frames': [],
    'statsSnapshots': [],
    'events': [],
  };

  Future<void> begin(CanSession session) async {
    await (await database).insert('captures', {
      'id': session.id,
      'metadata': jsonEncode(metadata(session)),
    });
  }

  Future<bool> contains(String id) async => (await (await database).query(
    'captures',
    columns: ['id'],
    where: 'id = ?',
    whereArgs: [id],
  )).isNotEmpty;

  Future<CanSession?> read(String id, {bool preview = false}) async {
    final db = await database;
    // A consistent read transaction also permits inspection of an active capture.
    return db.transaction((txn) async {
      final rows = await txn.query(
        'captures',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (rows.isEmpty) return null;
      final data =
          jsonDecode(rows.single['metadata'] as String) as Map<String, dynamic>;
      for (final kind in ['frames', 'statsSnapshots', 'events']) {
        final limit = preview
            ? (kind == 'frames'
                  ? 100
                  : kind == 'statsSnapshots'
                  ? 600
                  : 2000)
            : null;
        final records = await txn.query(
          'capture_records',
          columns: ['payload'],
          where: 'session_id = ? AND kind = ?',
          whereArgs: [id, kind],
          orderBy: preview ? 'ordinal DESC' : 'ordinal ASC',
          limit: limit,
        );
        data[kind] = (preview ? records.reversed : records)
            .map((r) => jsonDecode(r['payload'] as String))
            .toList();
      }
      if (data['isActive'] == true) {
        data['isActive'] = false;
        final capture = Map<String, dynamic>.from(
          data['captureMetadata'] as Map? ?? {},
        );
        data['endTime'] = capture['lastCommittedAt'] ?? data['startTime'];
        data['captureMetadata'] = {
          ...capture,
          'interrupted': true,
          'durability':
              'Committed records recovered; final in-memory tail is unknown',
        };
      }
      return CanSession.fromJson(data);
    });
  }

  Future<List<CanSession>> previews() async {
    final ids = await (await database).query(
      'captures',
      columns: ['id'],
      orderBy: 'id DESC',
    );
    final sessions = <CanSession>[];
    for (final row in ids) {
      final session = await read(row['id'] as String, preview: true);
      if (session != null) sessions.add(session);
    }
    return sessions;
  }

  Future<Map<String, int>> counts(String id) async {
    final rows = await (await database).rawQuery(
      'SELECT kind, COUNT(*) AS n FROM capture_records WHERE session_id = ? GROUP BY kind',
      [id],
    );
    return {for (final row in rows) row['kind'] as String: row['n'] as int};
  }

  Future<void> delete(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'capture_records',
        where: 'session_id = ?',
        whereArgs: [id],
      );
      await txn.delete('captures', where: 'id = ?', whereArgs: [id]);
    });
  }
}

class BleCaptureWriter {
  BleCaptureWriter({
    required this.store,
    required this.session,
    required this.onError,
    this.interval = const Duration(milliseconds: 250),
    this.maxPending = 8192,
  }) {
    _timer = Timer.periodic(interval, (_) => _schedule());
  }
  final BleCaptureDatabase store;
  final CanSession Function() session;
  final void Function(Object) onError;
  final Duration interval;
  final int maxPending;
  final List<Map<String, Object?>> _pending = [];
  Timer? _timer;
  Future<void> _flushTail = Future<void>.value();
  bool _scheduled = false;
  Object? error;
  int receivedFrames = 0,
      committedFrames = 0,
      committedStats = 0,
      committedEvents = 0;
  int _ordinal = 0;
  int _committedErrorFrames = 0;
  final Map<CanErrorType, int> _committedErrors = {};
  bool _closed = false;
  DateTime? lastCommittedAt;

  Map<String, dynamic> get diagnostics => {
    'storage': 'sqlite',
    'database': 'can_capture.db',
    'receivedFrames': receivedFrames,
    'committedFrames': committedFrames,
    'committedStats': committedStats,
    'committedEvents': committedEvents,
    'pendingRecords': _pending.length,
    'lastCommittedAt': lastCommittedAt?.toIso8601String(),
    'storageError': error?.toString(),
    'checkpointIntervalMs': interval.inMilliseconds,
    'durability':
        'Only completed SQLite transactions are guaranteed; force-stop may lose the in-memory tail',
  };

  void frame(CanFrame frame) {
    receivedFrames++;
    _add('frames', frame.toJson());
  }

  void stats(CanStats stats) => _add('statsSnapshots', stats.toJson());
  void event(CanSessionEvent event) => _add('events', event.toJson());

  void _add(String kind, Map<String, dynamic> payload) {
    if (_closed) throw StateError('Capture already closed');
    if (error != null) return;
    if (_pending.length >= maxPending) {
      _fail(StateError('Capture queue overflow; recording is incomplete'));
      return;
    }
    _pending.add({
      'session_id': session().id,
      'ordinal': _ordinal++,
      'kind': kind,
      'payload': jsonEncode(payload),
    });
    if (_pending.length >= 128) _schedule();
  }

  void _fail(Object e) {
    if (error != null) return;
    error = e;
    _timer?.cancel();
    onError(e);
  }

  void _schedule() {
    if (_scheduled || _pending.isEmpty || error != null) return;
    _scheduled = true;
    unawaited(
      flush().then<void>(
        (_) {
          _scheduled = false;
        },
        onError: (Object e, StackTrace stack) {
          _scheduled = false;
          _fail(e);
        },
      ),
    );
  }

  Future<void> flush() async {
    // Serialize timer, lifecycle checkpoints and close even if several callers
    // await the same transaction. Failed records remain queued for explicit retry.
    final task = _flushTail.then((_) => _drain());
    _flushTail = task.then<void>(
      (_) {},
      onError: (Object e, StackTrace stack) {
        _fail(e);
      },
    );
    await task;
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      final batch = _pending.take(128).toList();
      final frames = batch.where((r) => r['kind'] == 'frames').length;
      final frameModels = batch
          .where((r) => r['kind'] == 'frames')
          .map(
            (r) => CanFrame.fromJson(
              jsonDecode(r['payload'] as String) as Map<String, dynamic>,
            ),
          )
          .toList();
      final errorFrames = frameModels
          .where((f) => recordedFrameErrors(f).isNotEmpty)
          .length;
      final errorCounts = recordedErrorStatistics(frameModels);
      final stats = batch.where((r) => r['kind'] == 'statsSnapshots').length;
      final events = batch.where((r) => r['kind'] == 'events').length;
      final committedAt = DateTime.now().toUtc();
      final snapshot = session();
      final data = BleCaptureDatabase.metadata(snapshot);
      data['totalFrames'] = committedFrames + frames;
      data['errorFrames'] = _committedErrorFrames + errorFrames;
      data['errorRate'] = committedFrames + frames == 0
          ? 0.0
          : (_committedErrorFrames + errorFrames) /
                (committedFrames + frames) *
                100;
      data['errorStats'] = {
        for (final type in CanErrorType.values)
          type.toString():
              (_committedErrors[type] ?? 0) + (errorCounts[type] ?? 0),
      };
      data['captureMetadata'] = {
        ...snapshot.captureMetadata,
        ...diagnostics,
        'committedFrames': committedFrames + frames,
        'committedStats': committedStats + stats,
        'committedEvents': committedEvents + events,
        'pendingRecords': _pending.length - batch.length,
        'lastCommittedAt': committedAt.toIso8601String(),
      };
      await (await store.database).transaction((txn) async {
        final writes = txn.batch();
        for (final row in batch) {
          writes.insert('capture_records', row);
        }
        writes.update(
          'captures',
          {'metadata': jsonEncode(data)},
          where: 'id = ?',
          whereArgs: [snapshot.id],
        );
        await writes.commit(noResult: true);
      });
      _pending.removeRange(0, batch.length);
      committedFrames += frames;
      _committedErrorFrames += errorFrames;
      for (final type in CanErrorType.values) {
        _committedErrors[type] =
            (_committedErrors[type] ?? 0) + (errorCounts[type] ?? 0);
      }
      committedStats += stats;
      committedEvents += events;
      lastCommittedAt = committedAt;
    }
  }

  Future<void> close(CanSession completed) async {
    _timer?.cancel();
    await flush();
    final data = BleCaptureDatabase.metadata(completed);
    data['totalFrames'] = committedFrames;
    data['errorFrames'] = _committedErrorFrames;
    data['errorRate'] = committedFrames == 0
        ? 0.0
        : _committedErrorFrames / committedFrames * 100;
    data['errorStats'] = {
      for (final type in CanErrorType.values)
        type.toString(): _committedErrors[type] ?? 0,
    };
    data['captureMetadata'] = {
      ...completed.captureMetadata,
      ...diagnostics,
      'complete': error == null && receivedFrames == committedFrames,
    };
    await (await store.database).update(
      'captures',
      {'metadata': jsonEncode(data)},
      where: 'id = ?',
      whereArgs: [completed.id],
    );
    _closed = true;
  }

  void abandon() {
    _timer?.cancel();
    _closed = true;
  }
}

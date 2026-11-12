import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:can_debug/data/ble_capture_database.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/models/can_session.dart';
import 'package:can_debug/domain/models/can_session_event.dart';
import 'package:can_debug/domain/services/can_session_service.dart';
import 'package:can_debug/domain/services/session_export.dart';
import 'package:can_debug/domain/source/ble_message_decoder.dart';
import 'diagnostic_evidence_test.dart' show stats;

void main() {
  late Directory directory;
  late Database db;
  late BleCaptureDatabase store;
  Future<Database> open(String path) => databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: BleCaptureDatabase.createSchema,
    ),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('can_capture_test_');
    db = await open('${directory.path}/capture.db');
    store = BleCaptureDatabase(open: () async => db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
    final tempRoot = Directory.systemTemp.resolveSymbolicLinksSync();
    final target = directory.resolveSymbolicLinksSync();
    expect(
      target.toLowerCase().startsWith(
        '${tempRoot.toLowerCase()}${Platform.pathSeparator}',
      ),
      isTrue,
    );
    await directory.delete(recursive: true);
  });

  test(
    'BLE broadcast -> SQLite -> JSON/CSV preserves late frames and replays in arrival order',
    () async {
      final service = CanSessionService.forTesting(store);
      await service.createSession(sourceName: 'BLE arrival order regression');
      final frames = StreamController<CanFrame>.broadcast();
      final statsNotifications = StreamController<List<int>>();
      final tracker = BleSequenceTracker();
      final originals = <CanFrame>[];
      final delivered = <CanFrame>[];
      final subscription = frames.stream.listen((frame) {
        delivered.add(frame);
        service.recordAcceptedFrame(frame);
      });
      final frameDecoder = BleMessageDecoder(
        type: 'f',
        onMessage: (m) {
          originals.add(m.frame!);
          tracker.accept(m.frame!.sequence, m.frame!.receiverTimestampMs);
          frames.add(m.frame!);
        },
      );
      final statsDecoder = BleMessageDecoder(
        type: 's',
        onMessage: (m) {
          tracker.observeTelemetry(m.stats!.uptimeMs, m.stats!.rxTotal);
          service.recordStatsSnapshot(m.stats!);
        },
      );
      final statsSubscription = statsNotifications.stream.listen(
        statsDecoder.add,
      );
      final expected = [
        ...List.generate(150, (i) => i + 1000),
        1037,
        1150,
        1149,
        1150,
        1153,
        1151,
        1152,
        ...List.generate(150, (i) => i + 1154),
      ];
      for (var i = 0; i < expected.length; i++) {
        final seq = expected[i];
        final bytes = utf8.encode(
          jsonEncode({
            't': 'f',
            'id': 0x123,
            'dlc': 2,
            'data': [i % 256, 255],
            'seq': seq,
            'ts': seq * 10,
          }),
        );
        frameDecoder.add(bytes.sublist(0, 17));
        frameDecoder.add(bytes.sublist(17));
        if (i % 20 == 0) {
          statsNotifications.add(
            utf8.encode(
              jsonEncode({
                't': 's',
                ...stats(uptime: 10000 + i * 10, rx: 1000 + i).toJson(),
              }),
            ),
          );
        }
        if (i == 140) {
          await service.checkpoint(); // Transaction in flight during input.
        }
      }
      frameDecoder.reset(); // Reconnect boundary: diagnostics must survive.
      statsDecoder.reset();
      await frames.close();
      await statsNotifications.close();
      expect(delivered.map((f) => f.sequence), expected);
      service.updateCaptureMetadata(tracker.toJson());
      final id = service.currentSession!.id;
      await service.completeCurrentSession();
      await subscription.cancel();
      await statsSubscription.cancel();
      await db.close();
      db = await open('${directory.path}/capture.db');
      final restored = (await BleCaptureDatabase(
        open: () async => db,
      ).read(id))!;
      expect(
        restored.frames.map((f) => f.toJson()),
        originals.map((f) => f.toJson()),
      );
      expect(restored.frames.map((f) => f.sequence), expected);
      expect(restored.captureMetadata['committedFrames'], expected.length);
      expect(restored.captureMetadata['receivedFrames'], expected.length);
      expect(restored.captureMetadata['sequenceTrackingVersion'], 2);
      expect(restored.captureMetadata['receiverResets'], 0);
      expect(restored.captureMetadata['duplicateSequences'], 3);
      final export =
          jsonDecode(SessionExport.json(restored)) as Map<String, dynamic>;
      final exportedFrames = (export['session']['frames'] as List).cast<Map>();
      expect(exportedFrames.map((f) => f['seq']), expected);
      expect(
        exportedFrames.map((f) => f['rawWire']),
        originals.map((f) => f.rawWire),
      );
      // First CSV fields contain no embedded quotes/newlines in this fixture.
      // seq is column 8; full escaped JSON is independently checked above.
      final csvSequences = const LineSplitter()
          .convert(SessionExport.csv(restored))
          .where((line) => line.startsWith('"frame",'))
          .map((line) => int.parse(line.split(',')[8].replaceAll('"', '')));
      expect(csvSequences, expected);
      service.dispose();
    },
  );

  test(
    'BLE -> decoder -> service -> SQLite keeps all 513 frames beyond UI snapshot; reopens and exports',
    () async {
      final legacy = CanSession.create('Existing legacy session').complete();
      final prefs = await SharedPreferences.getInstance();
      final originalLegacy = jsonEncode([legacy.toJson()]);
      await prefs.setString('can_sessions', originalLegacy);
      final service = CanSessionService.forTesting(store);
      await service.createSession(sourceName: 'BLE synthetic control');
      final preview = <CanFrame>[];
      final decoder = BleMessageDecoder(
        type: 'f',
        onMessage: (message) {
          service.recordAcceptedFrame(message.frame!);
          preview.add(message.frame!);
          if (preview.length > 100) preview.removeAt(0);
        },
      );
      for (var i = 0; i < 513; i++) {
        final bytes = utf8.encode(
          jsonEncode({
            't': 'f',
            'id': 0x123,
            'dlc': 2,
            'data': [i % 256, 255],
            'seq': i,
            'ts': i * 10,
          }),
        );
        decoder.add(bytes.sublist(0, 20));
        decoder.add(bytes.sublist(20));
      }
      service.recordStatsSnapshot(stats(tec: 17, rec: 23));
      final event = CanSessionEvent.create(
        type: CanSessionEventType.diagnostic,
        message: 'Synthetic event with comma, quote " and newline\n',
        evidence: DiagnosticEvidence.inferred,
      );
      service.recordSessionEvent(event);
      service.updateCurrentSession(
        frames: preview,
        errorStats: {},
        totalFrames: 513,
        errorFrames: 0,
        errorRate: 0,
      );
      final id = service.currentSession!.id;
      await service.completeCurrentSession();
      expect(service.currentSession, isNull);
      expect((await store.counts(id))['frames'], 513);
      expect(service.savedSessions.first.frames, hasLength(100));
      expect(
        prefs.getString('can_sessions'),
        originalLegacy,
      ); // never rewrites user history
      await db.close();
      db = await open('${directory.path}/capture.db');
      final restarted = CanSessionService.forTesting(
        BleCaptureDatabase(open: () async => db),
      );
      await restarted.initialize();
      expect(restarted.savedSessions, hasLength(2));
      final session = await restarted.readStoredSession(
        restarted.getSessionById(id)!,
      );
      expect(session.frames, hasLength(513));
      expect(session.frames.first.sequence, 0);
      expect(session.frames.last.sequence, 512);
      expect(session.frames.last.receiverTimestampMs, 5120);
      expect(session.frames.last.data, [0, 255]);
      expect(session.statsSnapshots.single.txErrorCounter, 17);
      expect(session.statsSnapshots.single.rxErrorCounter, 23);
      expect(session.events.single.id, event.id);
      final export =
          jsonDecode(SessionExport.json(session)) as Map<String, dynamic>;
      expect(export['counts'], {
        'frames': 513,
        'statsSnapshots': 1,
        'events': 1,
      });
      final csv = SessionExport.csv(session);
      expect(
        RegExp(r'^"frame",', multiLine: true).allMatches(csv),
        hasLength(513),
      );
      expect(
        RegExp(r'^"stats",', multiLine: true).allMatches(csv),
        hasLength(1),
      );
      expect(
        RegExp(r'^"event",', multiLine: true).allMatches(csv),
        hasLength(1),
      );
      expect(csv, contains('""')); // JSON and quotes are CSV-escaped
      expect(
        SessionExport.json(CanSession.fromJson(export['session'])),
        isNotEmpty,
      );
      expect(
        (await db.rawQuery('PRAGMA quick_check')).single.values.single,
        'ok',
      );
      restarted.dispose();
      service.dispose();
    },
  );

  test(
    'checkpoint recovery exposes committed prefix and interruption without inventing the tail',
    () async {
      final session = CanSession.create('Synthetic checkpoint').updateWith(
        sourceName: 'BLE test',
        captureMetadata: {'storage': 'sqlite'},
      );
      await store.begin(session);
      final writer = BleCaptureWriter(
        store: store,
        session: () => session,
        interval: const Duration(days: 1),
        onError: (_) {},
      );
      writer.frame(CanFrame.create(id: 1, dlc: 0, data: [], sequence: 1));
      await writer.flush();
      writer.frame(CanFrame.create(id: 1, dlc: 0, data: [], sequence: 2));
      writer
          .abandon(); // Simulated loss of RAM, not a claim of physical force-stop testing.
      await db.close();
      db = await open('${directory.path}/capture.db');
      final recovered = await BleCaptureDatabase(
        open: () async => db,
      ).read(session.id);
      expect(recovered!.frames.single.sequence, 1);
      expect(recovered.totalFrames, 1);
      expect(recovered.captureMetadata['interrupted'], isTrue);
      expect(recovered.isActive, isFalse);
      expect(
        (await db.rawQuery('PRAGMA quick_check')).single.values.single,
        'ok',
      );
    },
  );

  test(
    'transaction failure rolls back data and counters; queued records survive retry without duplicates',
    () async {
      final session = CanSession.create(
        'Synthetic rollback',
      ).updateWith(captureMetadata: {'storage': 'sqlite'});
      await store.begin(session);
      final errors = <Object>[];
      final writer = BleCaptureWriter(
        store: store,
        session: () => session,
        interval: const Duration(days: 1),
        onError: errors.add,
      );
      writer.frame(CanFrame.create(id: 1, dlc: 0, data: []));
      writer.stats(stats());
      await db.execute(
        "CREATE TRIGGER fail_stats BEFORE INSERT ON capture_records WHEN NEW.kind = 'statsSnapshots' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      await expectLater(writer.flush(), throwsA(isA<DatabaseException>()));
      expect(await store.counts(session.id), isEmpty);
      expect(writer.committedFrames, 0);
      expect(errors, hasLength(1));
      await db.execute('DROP TRIGGER fail_stats');
      await writer.flush();
      await writer.flush();
      expect((await store.counts(session.id))['frames'], 1);
      expect((await store.counts(session.id))['statsSnapshots'], 1);
      writer.abandon();
    },
  );

  test(
    'export rejects a preview or incomplete load instead of reporting a full export',
    () {
      final session = CanSession.create('Synthetic mismatch').updateWith(
        captureMetadata: {
          'storage': 'sqlite',
          'committedFrames': 101,
          'committedStats': 0,
          'committedEvents': 0,
        },
      );
      expect(() => SessionExport.json(session), throwsStateError);
      expect(() => SessionExport.csv(session), throwsStateError);
    },
  );

  test(
    'disconnect checkpoint and reconnect keep one session; next capture is isolated',
    () async {
      final service = CanSessionService.forTesting(store);
      await service.createSession(sourceName: 'BLE synthetic reconnect');
      final firstId = service.currentSession!.id;
      final decoder = BleMessageDecoder(
        type: 'f',
        onMessage: (m) => service.recordAcceptedFrame(m.frame!),
      );
      void send(int seq) => decoder.add(
        utf8.encode(
          jsonEncode({
            't': 'f',
            'id': 1,
            'dlc': 0,
            'data': [],
            'ts': seq * 10,
            'seq': seq,
          }),
        ),
      );
      for (var i = 1; i <= 16; i++) {
        send(i);
      }
      decoder.add(utf8.encode('{"t":"f",'));
      decoder.reset();
      await Future.wait([
        service.checkpoint(),
        service.checkpoint(),
        service.checkpoint(),
      ]);
      for (var i = 17; i <= 24; i++) {
        send(i);
      }
      await service.completeCurrentSession();
      expect(
        (await store.read(firstId))!.frames.map((f) => f.sequence),
        List.generate(24, (i) => i + 1),
      );
      await service.createSession(sourceName: 'BLE next synthetic capture');
      final secondId = service.currentSession!.id;
      decoder.startSession();
      send(1);
      await service.completeCurrentSession();
      expect((await store.read(secondId))!.frames.single.sequence, 1);
      expect((await store.counts(firstId))['frames'], 24);
      service.dispose();
    },
  );
}

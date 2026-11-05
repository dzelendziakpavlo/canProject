import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/source/can_frame_source.dart';
import 'package:can_debug/domain/source/serial_can_source.dart';
import 'package:can_debug/domain/source/serial_connection.dart';
import 'package:can_debug/domain/services/experiment_journal.dart';

class FakeConnection implements SerialConnection {
  final input = StreamController<List<int>>.broadcast(sync: true);
  int closes = 0;
  int sentBytes = 0;
  @override
  Stream<List<int>> get bytes => input.stream;
  void send(Map<String, dynamic> json) {
    final bytes = utf8.encode('${jsonEncode(json)}\n');
    sentBytes += bytes.length;
    input.add(bytes);
  }

  @override
  Future<void> close() async {
    closes++;
    await input.close();
  }
}

Map<String, dynamic> packet(int seq, {int? ts}) => {
  't': 'f',
  'id': 192,
  'dlc': 1,
  'data': [seq % 256],
  'ts': ts ?? seq,
  'seq': seq,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('can_serial_test_');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'records 2000 frames and all telemetry independent of display subscribers',
    () async {
      final connection = FakeConnection();
      final source = SerialCanSource(
        portName: 'COM_TEST',
        journalDirectory: temp,
        connector: (_, _) async => connection,
      );
      final frames = <CanFrame>[];
      final subscription = source.frameStream.listen(frames.add);
      await source.start();
      await source.start();
      for (var n = 1; n <= 2000; n++) {
        connection.send(packet(n));
      }
      connection.send({
        't': 's',
        'rx': 2000,
        'txe': 2,
        'rxe': 1,
        'state': 'RUNNING',
        'missed': 0,
        'buserr': 3,
        'uptime': 5000,
        'serialdrop': 7,
      });
      await source.stop();
      final records = await File(source.journal!.jsonlPath).readAsLines();
      expect(records, hasLength(2001));
      expect(frames, hasLength(2000));
      expect(source.bytesRead, connection.sentBytes);
      expect(source.readOperations, 2001);
      expect(source.completedLines, 2001);
      expect(source.readErrors, 0);
      final last = jsonDecode(records.last) as Map;
      expect(last['txErrorCounter'], 2);
      expect(last['serialdrop'], 7);
      expect(last['espTimestamp'], 5000);
      expect(last['hostReceivedAt'], isA<String>());
      expect(
        await File(source.journal!.csvPath).readAsLines(),
        hasLength(2002),
      );
      expect(
        jsonDecode(
          await File(
            '${source.journal!.directory.path}/manifest.json',
          ).readAsString(),
        )['unrecordedRecords'],
        0,
      );
      expect(connection.closes, 1);
      expect(source.state, SourceState.idle);
      await subscription.cancel();
      source.dispose();
      await source.stop();
    },
  );

  test(
    'rejection and sequence gaps are separate from CAN errors, reset starts a baseline',
    () async {
      final connection = FakeConnection();
      final source = SerialCanSource(
        portName: 'COM_TEST',
        journalDirectory: temp,
        connector: (_, _) async => connection,
      );
      await source.start();
      connection.input.add(utf8.encode('not json\n'));
      connection.send(packet(1, ts: 100));
      connection.send(packet(4, ts: 200));
      connection.send({
        't': 's',
        'rx': 4,
        'txe': 0,
        'rxe': 0,
        'state': 'RUNNING',
        'missed': 0,
        'buserr': 0,
        'uptime': 500,
      });
      connection.send(packet(5, ts: 300));
      connection.send(packet(1, ts: 1));
      connection.send(packet(2, ts: 2));
      expect(source.serialParseErrors, 1);
      expect(source.serialErrors, 0);
      expect(source.sequenceGaps, 2);
      expect(source.receivedFrames, 5);
      await source.stop();
      source.dispose();
    },
  );

  test(
    'disconnect flushes existing data and manual restart opens exactly once',
    () async {
      final connections = <FakeConnection>[];
      final source = SerialCanSource(
        portName: 'COM_TEST',
        journalDirectory: temp,
        connector: (_, _) async {
          final connection = FakeConnection();
          connections.add(connection);
          return connection;
        },
      );
      await source.start();
      connections.first.send(packet(1));
      connections.first.input.addError(StateError('unplugged'));
      await source.stop();
      expect(source.lastError, contains('unplugged'));
      expect(source.readErrors, 1);
      expect(await File(source.journal!.jsonlPath).readAsLines(), hasLength(1));
      final oldPath = source.journal!.csvPath;
      await source.start();
      connections.last.send(packet(2));
      await source.stop();
      expect(connections, hasLength(2));
      expect(connections.map((c) => c.closes), everyElement(1));
      expect(source.journal!.csvPath, isNot(oldPath));
      source.dispose();
    },
  );

  test(
    'stop during pending open closes the late port and prevents events',
    () async {
      final pending = Completer<SerialConnection>();
      final connection = FakeConnection();
      final entered = Completer<void>();
      final source = SerialCanSource(
        portName: 'COM_TEST',
        journalDirectory: temp,
        connector: (_, _) {
          entered.complete();
          return pending.future;
        },
      );
      final start = source.start();
      await entered.future;
      final stop = source.stop();
      pending.complete(connection);
      await Future.wait([start, stop]);
      expect(connection.closes, 1);
      expect(source.state, SourceState.idle);
      source.dispose();
    },
  );

  test(
    'busy port reports error and finalizes recording without crashing',
    () async {
      final source = SerialCanSource(
        portName: 'COM_TEST',
        journalDirectory: temp,
        connector: (_, _) async => throw StateError('Access denied / busy'),
      );
      await source.start();
      expect(source.state, SourceState.error);
      expect(source.serialErrors, 1);
      expect(source.lastError, contains('busy'));
      await source.stop();
      source.dispose();
    },
  );

  test('journal overflow is bounded, explicit and marked incomplete', () async {
    final journal = await ExperimentJournal.open(
      temp,
      metadata: {},
      maxPendingRecords: 1,
    );
    journal.append({
      'type': 'f',
      'data': [1],
    });
    journal.append({
      'type': 'f',
      'data': [2],
    });
    expect(
      () => journal.append({
        'type': 'f',
        'data': [3],
      }),
      throwsStateError,
    );
    await journal.close();
    final manifest = jsonDecode(
      await File('${journal.directory.path}/manifest.json').readAsString(),
    );
    expect(manifest['status'], 'incomplete');
    expect(manifest['unrecordedRecords'], greaterThan(0));
  });
}

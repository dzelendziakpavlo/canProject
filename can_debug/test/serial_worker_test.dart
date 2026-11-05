import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/domain/source/serial_connection.dart';
import 'package:can_debug/domain/source/serial_json_decoder.dart';
import 'package:can_debug/domain/source/serial_can_source.dart';

// Runs the production host-side controller/ACK protocol in real isolates,
// without opening hardware or bypassing byte delivery with FakeConnection.
void _worker(List<dynamic> args) {
  final output = args[0] as SendPort;
  final commands = ReceivePort();
  final wire = utf8.encode(
    '{"t":"f","id":192,"dlc":2,"data":[1,255],"ts":123,"seq":1}\r\n'
    '{"t":"s","rx":1,"txe":0,"rxe":0,"state":"RUNNING","missed":0,"buserr":0}\n',
  );
  final chunks = [wire.sublist(0, 13), wire.sublist(13, 90), wire.sublist(90)];
  var sent = 0, acks = 0;
  void report({bool closed = false}) => output.send({
    'kind': 'diagnostics',
    'values': {
      'readerStarted': !closed,
      'acknowledgements': acks,
      'readOperations': sent,
      'closed': closed,
    },
  });
  output.send(commands.sendPort);
  report();
  output.send('ready');
  commands.listen((command) {
    if (command == 'ack') {
      acks++;
      if (args[1] == 'ERROR') {
        output.send({
          'kind': 'diagnostics',
          'values': {'readErrors': 1},
        });
        output.send('simulated read error');
        return;
      }
      if (sent < chunks.length) {
        output.send(Uint8List.fromList(chunks[sent++]));
      }
      report();
    }
    if (command == 'close') {
      report(closed: true);
      commands.close();
      Isolate.exit();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real isolate bytes reach source models and the independent disk journal',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'can_worker_source_',
      );
      final source = SerialCanSource(
        portName: 'TEST',
        journalDirectory: directory,
        connector: (port, baud) => openSerialWorker(port, baud, _worker),
      );
      var frameCount = 0, statsCount = 0;
      final delivered = Completer<void>();
      void complete() {
        if (frameCount == 1 && statsCount == 1 && !delivered.isCompleted) {
          delivered.complete();
        }
      }

      final frames = source.frameStream.listen((_) {
        frameCount++;
        complete();
      });
      final stats = source.statsStream.listen((_) {
        statsCount++;
        complete();
      });
      try {
        await source.start();
        await delivered.future.timeout(const Duration(seconds: 2));
        await source.stop();
        expect(source.readOperations, 3);
        expect(source.bytesRead, greaterThan(0));
        expect(source.completedLines, 2);
        expect(source.serialParseErrors, 0);
        final records = await File(source.journal!.jsonlPath).readAsLines();
        expect(records.map((line) => (jsonDecode(line) as Map)['type']), [
          'f',
          's',
        ]);
        final manifest =
            jsonDecode(
                  await File(
                    '${source.journal!.directory.path}/manifest.json',
                  ).readAsString(),
                )
                as Map;
        expect(manifest['bytesRead'], source.bytesRead);
        expect(manifest['transportDiagnostics']['closed'], true);
      } finally {
        await frames.cancel();
        await stats.cancel();
        await source.stop();
        source.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'USB choice and descriptors distinguish the receiver from legacy COM1',
    () {
      const native = SerialPortInfo(
        'COM1',
        'Communications Port',
        transport: 'native / RS232',
      );
      const receiver = SerialPortInfo(
        'COM4',
        'USB-SERIAL CH340',
        transport: 'USB',
        vendorId: 0x1a86,
        productId: 0x7523,
      );
      expect(preferredSerialPort([native, receiver]), 'COM4');
      expect(preferredSerialPort([native, receiver], current: 'COM1'), 'COM1');
      expect(preferredSerialPort([], current: 'COM1'), isNull);
      expect(receiver.label, contains('1a86'));
      expect(receiver.label, contains('7523'));
    },
  );

  test(
    'real isolate waits for listener, delivers split JSON, then closes cleanly',
    () async {
      final connection = await openSerialWorker('TEST', 115200, _worker);
      final diagnostic = connection as SerialDiagnosticConnection;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(diagnostic.diagnostics['acknowledgements'], 0);
      final messages = <SerialMessage>[];
      final rejected = <String>[];
      final decoder = SerialJsonDecoder(
        onMessage: messages.add,
        onRejected: (reason, _) => rejected.add(reason),
      );
      final chunks = await connection.bytes
          .take(3)
          .toList()
          .timeout(const Duration(seconds: 2));
      for (final chunk in chunks) {
        decoder.add(chunk);
      }
      await connection.close();
      expect(messages.map((m) => m.json['t']), ['f', 's']);
      expect(rejected, isEmpty);
      expect(decoder.completedLines, 2);
      expect(diagnostic.diagnostics['closed'], true);
      expect(diagnostic.diagnostics['acknowledgements'], 3);
    },
  );

  test(
    'pause withholds ACK; resume restarts without deadlock or duplicate chunks',
    () async {
      final connection = await openSerialWorker('TEST', 115200, _worker);
      final received = <List<int>>[];
      final first = Completer<void>(), all = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = connection.bytes.listen((bytes) {
        received.add(bytes);
        if (received.length == 1) {
          subscription.pause();
          first.complete();
        }
        if (received.length == 3) all.complete();
      });
      await first.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(received, hasLength(1));
      subscription.resume();
      await all.future.timeout(const Duration(seconds: 2));
      await subscription.cancel();
      await connection.close();
      expect(received, hasLength(3));
    },
  );

  test(
    'reader errors are delivered and diagnostic maps are not parsed as errors',
    () async {
      final connection = await openSerialWorker('ERROR', 115200, _worker);
      final error = Completer<Object>();
      final sub = connection.bytes.listen(
        (_) {},
        onError: (Object value) => error.complete(value),
      );
      expect(
        (await error.future.timeout(const Duration(seconds: 2))).toString(),
        contains('simulated read error'),
      );
      expect(
        (connection as SerialDiagnosticConnection).diagnostics['readErrors'],
        1,
      );
      await sub.cancel();
      await connection.close();
    },
  );
}

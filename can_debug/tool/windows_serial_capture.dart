import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:can_debug/domain/source/serial_connection.dart';
import 'package:can_debug/domain/source/serial_json_decoder.dart';

/// Bounded physical transport check. Close Serial Monitor and CAN Debug Pro first.
Future<void> main(List<String> arguments) async {
  try {
    await capture(arguments);
  } catch (error) {
    stderr.writeln('Serial capture failed: $error');
    exitCode = 1;
  }
}

Future<void> capture(List<String> arguments) async {
  String option(String name, String fallback) {
    final index = arguments.indexOf(name);
    return index >= 0 && index + 1 < arguments.length
        ? arguments[index + 1]
        : fallback;
  }

  final port = option('--port', '');
  if (port.isEmpty) {
    throw ArgumentError('Specify --port COMx for the verified RECEIVER port');
  }
  final baud = int.parse(option('--baud', '115200'));
  final seconds = int.parse(option('--seconds', '8'));
  if (seconds < 1 || seconds > 60) {
    throw ArgumentError('--seconds must be 1–60');
  }
  var bytesRead = 0, readOperations = 0, readErrors = 0;
  var completedLines = 0, decodedFrames = 0, decodedStats = 0, rejected = 0;
  final samples = <String>[];
  final decoder = SerialJsonDecoder(
    onMessage: (message) {
      if (message.frame != null) decodedFrames++;
      if (message.stats != null) decodedStats++;
      if ((message.frame != null && decodedFrames <= 3) ||
          (message.stats != null && decodedStats <= 2)) {
        samples.add(message.raw);
        stdout.writeln('SAMPLE ${message.raw}');
      }
    },
    onRejected: (reason, raw) {
      rejected++;
      if (rejected <= 3) {
        stderr.writeln(
          'REJECTED $reason: ${raw == null ? '' : raw.substring(0, raw.length.clamp(0, 160))}',
        );
      }
    },
  );
  final ports = await listSerialPorts();
  for (final info in ports.where((info) => info.name == port)) {
    stdout.writeln('Selected: ${info.label}');
  }
  final connection = await openSerialConnection(port, baud);
  Map<String, dynamic> report() => {
    'port': port,
    'baudRate': baud,
    'seconds': seconds,
    'bytesRead': bytesRead,
    'readOperations': readOperations,
    'readErrors': readErrors,
    'completedLines': completedLines,
    'decodedFrames': decodedFrames,
    'decodedStats': decodedStats,
    'rejected': rejected,
    'incompleteLineBytes': decoder.bufferedBytes,
    'samples': samples,
    'transport': connection is SerialDiagnosticConnection
        ? connection.diagnostics
        : null,
  };
  stdout.writeln('Port open: $port @ $baud; listening for $seconds seconds.');
  final ended = Completer<void>();
  final subscription = connection.bytes.listen(
    (bytes) {
      bytesRead += bytes.length;
      readOperations++;
      completedLines += bytes.where((byte) => byte == 10).length;
      decoder.add(bytes);
    },
    onError: (Object error) {
      readErrors++;
      stderr.writeln('READ ERROR $error');
      if (!ended.isCompleted) ended.complete();
    },
    onDone: () {
      if (!ended.isCompleted) ended.complete();
    },
  );
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    final transport = connection is SerialDiagnosticConnection
        ? connection.diagnostics
        : const <String, dynamic>{};
    stdout.writeln(
      'RX bytes=$bytesRead reads=$readOperations lines=$completedLines frames=$decodedFrames stats=$decodedStats rejected=$rejected '
      'reader=${transport['readerStarted']} polls=${transport['polls']} ACKs=${transport['acknowledgements']} waitingACK=${transport['awaitingAck']} queued=${transport['bytesWaiting']}',
    );
  });
  try {
    await Future.any([
      Future<void>.delayed(Duration(seconds: seconds)),
      ended.future,
    ]);
  } finally {
    timer.cancel();
    await subscription.cancel();
    stdout.writeln('Closing port...');
    await connection.close();
    stdout.writeln('Port closed.');
  }
  stdout.writeln('RESULT ${jsonEncode(report())}');
  final output = option('--report', '');
  if (output.isNotEmpty) {
    final file = File(output);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report()),
      flush: true,
    );
  }
  if (bytesRead == 0 ||
      decodedFrames == 0 ||
      decodedStats == 0 ||
      readErrors > 0) {
    exitCode = 2;
  }
}

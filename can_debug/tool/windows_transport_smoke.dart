import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:can_debug/domain/source/serial_connection.dart';

/// Enumeration, missing-port failure and SQLite check. No existing port is opened.
Future<void> main() async {
  if (!Platform.isWindows) throw UnsupportedError('Windows smoke test');
  final ports = await listSerialPorts();
  stdout.writeln(
    'Native libserialport loaded; available ports: ${ports.map((p) => p.name).join(', ')}',
  );
  var missingRejected = false;
  try {
    final unexpected = await openSerialConnection(
      'COM_CAN_DEBUG_MISSING',
      115200,
    );
    await unexpected.close();
  } catch (_) {
    missingRejected = true;
  }
  if (!missingRejected) throw StateError('Missing port was not rejected');
  stdout.writeln('Native missing-port failure and worker cleanup passed.');
  sqfliteFfiInit();
  final directory = await Directory.systemTemp.createTemp('can_windows_smoke_');
  final db = await databaseFactoryFfi.openDatabase(
    '${directory.path}/smoke.db',
  );
  try {
    await db.execute('CREATE TABLE smoke (value INTEGER)');
    await db.insert('smoke', {'value': 42});
    final rows = await db.query('smoke');
    if (rows.single['value'] != 42) {
      throw StateError('SQLite round trip failed');
    }
    stdout.writeln('Windows SQLite FFI round trip passed.');
  } finally {
    await db.close();
    await directory.delete(recursive: true);
  }
}

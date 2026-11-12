import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class SessionFileSaver {
  static const channel = MethodChannel('can_debug/session_export');
  static bool get isAndroidExportActive => _active;
  static bool _active = false;

  static Future<String?> save(String name, String mime, Uint8List bytes) async {
    if (bytes.isEmpty) throw StateError('Cannot export an empty payload');
    if (!Platform.isAndroid) {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      if (await file.length() != bytes.length)
        throw StateError('Incomplete export');
      return '${file.path} (${bytes.length} bytes)';
    }
    final directory = await getApplicationSupportDirectory();
    return saveAndroid(
      name,
      mime,
      bytes,
      Directory('${directory.path}/pending_exports'),
    );
  }

  /// Staged files survive process death. Native code owns their cleanup after
  /// cancellation or a verified copy; failed payloads remain available to retry.
  static Future<String?> saveAndroid(
    String name,
    String mime,
    Uint8List bytes,
    Directory staging, {
    Duration pollInterval = const Duration(seconds: 1),
  }) async {
    if (_active) throw StateError('Another export is in progress');
    if (bytes.isEmpty) throw StateError('Cannot export an empty payload');
    _active = true;
    try {
      await staging.create(recursive: true);
      final file = File(
        '${staging.path}/export_${DateTime.now().microsecondsSinceEpoch}.pending',
      );
      await file.writeAsBytes(bytes, flush: true);
      if (await file.length() != bytes.length)
        throw StateError('Incomplete staged export');
      final hash = sha256.convert(bytes).toString();
      final started = await channel
          .invokeMapMethod<String, dynamic>('saveDocument', {
            'name': name,
            'mime': mime,
            'sourcePath': file.path,
            'bytes': bytes.length,
            'sha256': hash,
          });
      if (started?['id'] == null)
        throw StateError('Android did not register this export');
      // No Activity-local MethodChannel result is held while the picker is open.
      // A recreated Flutter engine obtains the same durable receipt via recovery.
      while (true) {
        final receipt = await status();
        if (receipt == null || receipt['id'] != started!['id']) {
          throw StateError(
            'Android export state is missing; staged payload retained',
          );
        }
        final state = receipt['state'];
        if (state == 'saved' || state == 'cancelled' || state == 'error') {
          if (state == 'saved' &&
              (receipt['bytes'] != bytes.length || receipt['sha256'] != hash)) {
            throw StateError(
              'Android export verification did not match the payload',
            );
          }
          await acknowledge(receipt);
          return describe(receipt);
        }
        await Future<void>.delayed(pollInterval);
      }
    } finally {
      _active = false;
    }
  }

  static Future<Map<String, dynamic>?> status() =>
      channel.invokeMapMethod<String, dynamic>('exportStatus');
  static Future<void> acknowledge(Map<String, dynamic> receipt) =>
      channel.invokeMethod<void>('acknowledgeExport', {'id': receipt['id']});
  static Future<void> resume() => channel.invokeMethod<void>('resumeExport');

  static String? describe(Map<String, dynamic> receipt) {
    switch (receipt['state']) {
      case 'cancelled':
        return null;
      case 'saved':
        if (receipt['bytes'] is! int ||
            (receipt['bytes'] as int) <= 0 ||
            receipt['sha256'] is! String ||
            receipt['uri'] is! String) {
          throw StateError('Android returned an invalid export receipt');
        }
        return '${receipt['name']} (${receipt['bytes']} bytes, SHA-256 verified) — ${receipt['uri']}';
      case 'error':
        throw StateError(receipt['message']?.toString() ?? 'Export failed');
      default:
        throw StateError('Export is not complete');
    }
  }
}

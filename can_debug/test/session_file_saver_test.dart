import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/core/session_file_saver.dart';
import 'package:can_debug/domain/models/can_session.dart';
import 'package:can_debug/domain/services/session_export.dart';
import 'package:can_debug/domain/services/session_pdf_report.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory staging;
  setUp(() async {
    staging = await Directory.systemTemp.createTemp('can_export_test_');
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SessionFileSaver.channel, null);
    final root = Directory.systemTemp.resolveSymbolicLinksSync();
    final target = staging.resolveSymbolicLinksSync();
    expect(
      target.toLowerCase().startsWith(
        '${root.toLowerCase()}${Platform.pathSeparator}',
      ),
      isTrue,
    );
    await staging.delete(recursive: true);
  });

  for (final extension in ['json', 'csv', 'pdf']) {
    test(
      '$extension payload is nonempty and success requires matching verified bytes and hash',
      () async {
        final session = CanSession.create(
          'Synthetic export control',
        ).complete();
        final bytes = extension == 'pdf'
            ? await SessionPdfReport.build(session)
            : utf8.encode(
                extension == 'csv'
                    ? SessionExport.csv(session)
                    : SessionExport.json(session),
              );
        expect(bytes, isNotEmpty);
        if (extension == 'pdf')
          expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
        var id = '';
        var polls = 0;
        var acknowledged = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SessionFileSaver.channel, (call) async {
              switch (call.method) {
                case 'saveDocument':
                  final args = Map<String, dynamic>.from(call.arguments as Map);
                  final file = File(args['sourcePath'] as String);
                  expect(await file.readAsBytes(), bytes);
                  expect(args['bytes'], bytes.length);
                  expect(args['sha256'], sha256.convert(bytes).toString());
                  id = file.uri.pathSegments.last;
                  return {'id': id, 'state': 'awaiting_destination'};
                case 'exportStatus':
                  polls++;
                  if (polls == 1) return {'id': id, 'state': 'writing'};
                  return {
                    'id': id,
                    'state': 'saved',
                    'name': 'test.$extension',
                    'bytes': bytes.length,
                    'sha256': sha256.convert(bytes).toString(),
                    'uri': 'content://verified/test',
                  };
                case 'acknowledgeExport':
                  acknowledged = true;
                  return null;
              }
              throw StateError('Unexpected method ${call.method}');
            });
        final result = await SessionFileSaver.saveAndroid(
          'test.$extension',
          'application/octet-stream',
          bytes,
          staging,
          pollInterval: Duration.zero,
        );
        expect(result, contains('${bytes.length} bytes'));
        expect(result, contains('SHA-256 verified'));
        expect(acknowledged, isTrue);
        expect(SessionFileSaver.isAndroidExportActive, isFalse);
      },
    );
  }

  test('zero-byte or corrupt native receipts never report success', () async {
    final bytes = utf8.encode('{"frames":[]}');
    var id = '';
    var acknowledgements = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SessionFileSaver.channel, (call) async {
          if (call.method == 'saveDocument') {
            id = File(
              (call.arguments as Map)['sourcePath'] as String,
            ).uri.pathSegments.last;
            return {'id': id};
          }
          if (call.method == 'acknowledgeExport') {
            acknowledgements++;
            return null;
          }
          return {
            'id': id,
            'state': 'saved',
            'bytes': 0,
            'sha256': 'wrong',
            'uri': 'content://empty',
          };
        });
    await expectLater(
      SessionFileSaver.saveAndroid(
        'test.json',
        'application/json',
        bytes,
        staging,
      ),
      throwsStateError,
    );
    expect(acknowledgements, 0);
    expect(
      (await staging.list().toList()),
      hasLength(1),
    ); // Durable recovery source retained.
    expect(SessionFileSaver.isAndroidExportActive, isFalse);
  });

  test(
    'empty payload rejected before opening Android document picker',
    () async {
      var called = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SessionFileSaver.channel, (call) async {
            called = true;
            return null;
          });
      await expectLater(
        SessionFileSaver.saveAndroid(
          'test.csv',
          'text/csv',
          Uint8List(0),
          staging,
        ),
        throwsStateError,
      );
      expect(called, isFalse);
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:can_debug/domain/models/can_session.dart';
import 'package:can_debug/domain/services/can_session_service.dart';
import 'package:can_debug/domain/services/session_summary_builder.dart';
import 'package:can_debug/domain/source/serial_can_source.dart';
import 'package:can_debug/domain/source/serial_connection.dart';
import 'package:can_debug/presentation/screens/monitor_screen.dart';

class _Connection implements SerialConnection {
  final controller = StreamController<List<int>>.broadcast(sync: true);
  @override
  Stream<List<int>> get bytes => controller.stream;
  @override
  Future<void> close() => controller.close();
  void send(Map<String, dynamic> json) =>
      controller.add(utf8.encode('${jsonEncode(json)}\n'));
}

void main() {
  for (final size in [const Size(1280, 720), const Size(400, 600)]) {
    testWidgets(
      'USB monitor resizes, logs >100 frames and saves connection metadata at $size',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await CanSessionService.instance.initialize();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync('can_monitor_');
        final connection = _Connection();
        final source = SerialCanSource(
          portName: 'COM_TEST',
          journalDirectory: directory,
          connector: (_, _) async => connection,
        );
        await tester.runAsync(source.start);
        await tester.pumpWidget(
          MaterialApp(home: MonitorScreen(source: source)),
        );
        await tester.pump();
        connection.send({
          't': 's',
          'rx': 0,
          'txe': 0,
          'rxe': 0,
          'state': 'RUNNING',
          'missed': 0,
          'buserr': 0,
        });
        for (var i = 1; i <= 150; i++) {
          connection.send({
            't': 'f',
            'id': 192,
            'dlc': 2,
            'data': [1, 2],
            'ts': i,
            'seq': i,
          });
        }
        connection.send({
          't': 's',
          'rx': 150,
          'txe': 0,
          'rxe': 0,
          'state': 'RUNNING',
          'missed': 0,
          'buserr': 0,
        });
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
        expect(find.textContaining('USB RX 150'), findsOneWidget);
        await tester.tap(find.byTooltip('Disconnect & Save'));
        for (var attempt = 0; attempt < 30; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        final session = CanSessionService.instance.savedSessions.first;
        expect(session.frames, hasLength(100));
        expect(session.totalFrames, 150);
        expect(SessionSummaryBuilder().build(session).totalFrames, 150);
        expect(SessionSummaryBuilder().build(session).monitorMode, 'hardware');
        expect(
          session.events.any((event) => event.data['port'] == 'COM_TEST'),
          isTrue,
        );
        await tester.runAsync(() async {
          expect(
            await File(source.journal!.jsonlPath).readAsLines(),
            hasLength(152),
          );
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
        await tester.runAsync(() async {
          await directory.delete(recursive: true);
        });
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'USB session retains aggregate metrics and reopens with backward-compatible JSON',
    () {
      final session = CanSession.create('USB test').updateWith(
        sourceName: 'USB Serial — COM4 @ 115200',
        totalFrames: 2000,
        errorFrames: 20,
        errorRate: 1,
      );
      final reopened = CanSession.fromJson(session.toJson());
      final summary = SessionSummaryBuilder().build(reopened);
      expect(summary.totalFrames, 2000);
      expect(summary.errorFrames, 20);
      expect(summary.errorRate, 1);
      expect(summary.monitorMode, 'hardware');
    },
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/models/can_stats.dart';
import 'package:can_debug/domain/services/can_session_service.dart';
import 'package:can_debug/domain/source/can_frame_source.dart';
import 'package:can_debug/domain/simulator/can_frame_simulator.dart';
import 'package:can_debug/presentation/screens/monitor_screen.dart';

class LogicalHardwareSource implements CanFrameSource {
  final frames = StreamController<CanFrame>.broadcast(sync: true);
  final stats = StreamController<CanStats>.broadcast(sync: true);
  final states = StreamController<SourceState>.broadcast(sync: true);
  @override
  String get name => 'BLE — logical hardware test (not a physical experiment)';
  @override
  Stream<CanFrame> get frameStream => frames.stream;
  @override
  Stream<CanStats> get statsStream => stats.stream;
  @override
  Stream<SourceState> get stateStream => states.stream;
  @override
  Future<void> start() async {
    states.add(SourceState.connecting);
    states.add(SourceState.connected);
    states.add(SourceState.streaming);
  }

  @override
  Future<void> stop() async {
    if (!states.isClosed) states.add(SourceState.idle);
  }

  @override
  void dispose() {
    frames.close();
    stats.close();
    states.close();
  }
}

void main() {
  for (final size in [const Size(400, 600), const Size(1280, 720)]) {
    testWidgets(
      'hardware diagnostics updates without frames and survives loss/recovery at $size',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await CanSessionService.instance.initialize();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = LogicalHardwareSource();
        var now = DateTime.now().toUtc();
        final base = now;
        await tester.pumpWidget(
          MaterialApp(
            home: MonitorScreen(source: source, diagnosticsClock: () => now),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        void telemetry({int rec = 0, int buserr = 0}) => source.stats.add(
          CanStats.fromStoredJson({
            ...CanStats.fromJson({
              'rx': 1,
              'txe': 0,
              'rxe': rec,
              'buserr': buserr,
              'missed': 0,
              'state': 'RUNNING',
              'node': 'receiver',
              'uptime': now.difference(base).inMilliseconds + 1000,
            }).toJson(),
            'timestamp': now.toIso8601String(),
          }),
        );
        final good = CanFrame.create(
          id: 0x18ff0001,
          dlc: 2,
          data: [1, 3],
          isExtended: true,
          timestamp: now,
        );
        source.frames.add(good);
        telemetry();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('CAN Bus Diagnostics'), findsOneWidget);
        expect(find.text('Traffic: Active'), findsOneWidget);
        for (var i = 0; i < 5; i++) {
          now = now.add(const Duration(seconds: 1));
          telemetry();
          await tester.pump(const Duration(seconds: 1));
        }
        expect(find.text('Traffic: Silent'), findsOneWidget);
        expect(find.text('Transport: Active — data arriving'), findsOneWidget);
        expect(find.textContaining('CAN traffic lost'), findsWidgets);
        expect(find.text('75/100'), findsOneWidget);
        final session = CanSessionService.instance.currentSession!;
        final starts = session.events.where(
          (e) =>
              e.data['eventCode'] == 'can_traffic' &&
              e.data['phase'] == 'started',
        );
        expect(starts, hasLength(1));
        expect(
          session.frames.every((f) => !f.isCorrupted && f.errors.isEmpty),
          isTrue,
        );
        expect(good.isCorrupted, isFalse);
        expect(good.errors, isEmpty);
        expect(find.text('N/A'), findsWidgets);
        source.frames.add(
          CanFrame.create(
            id: good.id,
            dlc: 2,
            data: [2, 6],
            isExtended: true,
            timestamp: now,
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Traffic: Active'), findsOneWidget);
        expect(find.text('100/100'), findsOneWidget);
        expect(
          CanSessionService.instance.currentSession!.events.where(
            (e) => e.data['phase'] == 'recovered',
          ),
          hasLength(1),
        );
        now = now.add(const Duration(seconds: 1));
        telemetry(rec: 140, buserr: 4);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('80/100'), findsOneWidget);
        source.states.add(SourceState.disconnected);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Traffic: Unknown'), findsOneWidget);
        expect(find.text('Transport: Disconnected'), findsOneWidget);
        expect(find.text('TWAI').evaluate(), isNotEmpty);
        expect(find.text('80/100'), findsNothing);
        source.states.add(SourceState.reconnecting);
        source.states.add(SourceState.streaming);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Traffic: Unknown'), findsOneWidget);
        // Old TEC/REC are not current evidence after reconnect.
        expect(find.text('140'), findsNothing);
        now = now.add(const Duration(seconds: 1));
        telemetry();
        source.frames.add(good);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Traffic: Active'), findsOneWidget);
        await tester.tap(find.byTooltip('Disconnect & Save'));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final saved = CanSessionService.instance.savedSessions.first;
        expect(
          saved.events.any(
            (e) =>
                e.data['eventCode'] == 'can_traffic' &&
                e.data['phase'] == 'started',
          ),
          isTrue,
        );
        expect(
          saved.statsSnapshots.any((s) => s.rxErrorCounter == 140),
          isTrue,
        );
        expect(
          saved.frames.every((f) => !f.isCorrupted && f.errors.isEmpty),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'simulation retains frame handling and has no hardware evidence panel',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final simulator = CanFrameSimulator();
      await tester.pumpWidget(
        MaterialApp(home: MonitorScreen(source: simulator)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('CAN Bus Diagnostics'), findsNothing);
      simulator.generateCustomFrame(
        id: 192,
        dlc: 1,
        data: [5],
        isCorrupted: true,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Disconnect & Save'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        CanSessionService.instance.savedSessions.first.frames.any(
          (f) => f.isCorrupted,
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/domain/detection/can_error_checker.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/models/can_session.dart';
import 'package:can_debug/domain/models/can_session_event.dart';
import 'package:can_debug/domain/models/can_stats.dart';
import 'package:can_debug/domain/services/session_analytics.dart';
import 'package:can_debug/domain/services/session_summary_builder.dart';
import 'package:can_debug/domain/services/telemetry_diagnostics.dart';
import 'package:can_debug/domain/source/ble_message_decoder.dart';

CanStats stats({
  int uptime = 1000,
  int rx = 36,
  int buserr = 0,
  int tec = 0,
  int rec = 0,
  int arb = 0,
  bool noack = false,
  bool demo = false,
}) => CanStats.fromStoredJson({
  'rx': rx,
  'txe': tec,
  'rxe': rec,
  'state': 'RUNNING',
  'missed': 0,
  'buserr': buserr,
  'arb': arb,
  'txfail': 0,
  'ovr': 0,
  'noack': noack ? 1 : 0,
  'sdemo': demo ? 1 : 0,
  'uptime': uptime,
  'timestamp': DateTime.utc(
    2026,
    1,
    1,
  ).add(Duration(milliseconds: uptime)).toIso8601String(),
});

void main() {
  test(
    'legacy hardware subtype needs wire evidence; original attribution remains inspectable',
    () {
      final legacy = CanErrorInfo(
        type: CanErrorType.ackError,
        description: 'Legacy buserr guess',
        severity: 3,
        origin: CanErrorOrigin.hardware,
      );
      final restored = CanErrorInfo.fromJson(legacy.toJson());
      expect(restored.origin, CanErrorOrigin.inferred);
      expect(restored.details['originalOrigin'], 'hardware');
      expect(restored.details['evidenceVerified'], isFalse);
      final verified = CanErrorInfo.fromJson({
        ...legacy.toJson(),
        'details': {'evidenceSource': 'wire_error_capture'},
      });
      expect(verified.origin, CanErrorOrigin.hardware);
    },
  );
  const frameWire =
      '{"t":"f","id":419385573,"dlc":2,"data":[0,255],"rtr":0,"extd":1,"seq":9,"ts":123}';
  test(
    'FF11 validates every possible notification split and preserves wire fields',
    () {
      final bytes = utf8.encode(frameWire);
      for (var split = 1; split < bytes.length; split++) {
        final received = <CanFrame>[];
        final decoder = BleMessageDecoder(
          type: 'f',
          onMessage: (m) => received.add(m.frame!),
        );
        decoder.add(bytes.sublist(0, split));
        expect(received, isEmpty);
        decoder.add(bytes.sublist(split));
        expect(received, hasLength(1), reason: 'split $split');
        final restored = CanFrame.fromJson(received.single.toJson());
        expect(restored.sequence, 9);
        expect(restored.receiverTimestampMs, 123);
        expect(restored.isExtended, isTrue);
        expect(restored.rawWire, jsonDecode(frameWire));
        expect(restored.data, [0, 255]);
      }
    },
  );

  test(
    'FF12 reassembles long telemetry, preserves TEC/REC, rejects wrong channel',
    () {
      final received = <CanStats>[];
      final decoder = BleMessageDecoder(
        type: 's',
        onMessage: (m) => received.add(m.stats!),
      );
      final bytes = utf8.encode(
        jsonEncode({
          ...stats(tec: 17, rec: 12).toJson(),
          't': 's',
          'fw': 'x' * 300,
        }),
      );
      for (var offset = 0; offset < bytes.length; offset += 20) {
        decoder.add(
          bytes.sublist(offset, (offset + 20).clamp(0, bytes.length)),
        );
      }
      expect(received.single.txErrorCounter, 17);
      expect(received.single.rxErrorCounter, 12);
      decoder.add(utf8.encode(frameWire));
      expect(decoder.rejected, 1);
      expect(received, hasLength(1));
    },
  );

  test(
    'malformed, abandoned, timeout, overflow and disconnect fragments are counted',
    () {
      final frames = <CanFrame>[];
      final decoder = BleMessageDecoder(
        type: 'f',
        onMessage: (m) => frames.add(m.frame!),
      );
      decoder.add(utf8.encode('{"t":"f","id":-1}'));
      decoder.add(utf8.encode('{"t":"f",'));
      decoder.add(utf8.encode(frameWire)); // new root resynchronizes
      decoder.add(utf8.encode('{"t":"f","data":"${'x' * 2100}"}'));
      decoder.add(utf8.encode('{"t":"f",'), now: DateTime.utc(2026));
      decoder.add(
        utf8.encode(frameWire),
        now: DateTime.utc(2026).add(const Duration(seconds: 3)),
      );
      decoder.add(utf8.encode('{"t":'));
      decoder.reset(); // no fragments can cross reconnect boundaries
      decoder.add(utf8.encode(frameWire));
      expect(frames, hasLength(3));
      expect(decoder.rejected, 2);
      expect(decoder.incomplete, greaterThanOrEqualTo(3));
      expect(decoder.bufferedBytes, 0);
    },
  );

  test(
    'sequence tracking handles gaps, duplicates, out-of-order, wrap and restart',
    () {
      final tracker = BleSequenceTracker();
      tracker.accept(0xfffffffe, 100);
      tracker.accept(0xffffffff, 101);
      tracker.accept(0, 102);
      tracker.accept(3, 103);
      tracker.accept(3, 103);
      tracker.accept(2, 104);
      tracker.observeTelemetry(100000, 5000);
      tracker.observeTelemetry(1000, 10);
      tracker.observeTelemetry(2000, 20);
      tracker.accept(1, 1);
      tracker.accept(null, 2);
      expect(tracker.gaps, 2);
      expect(tracker.duplicates, 1);
      expect(tracker.outOfOrder, 1);
      expect(tracker.resets, 1);
      expect(tracker.missingSequence, 1);
    },
  );

  test(
    'buserr and demo flags never become CRC/ACK/Stuffing/Form or CAN ID',
    () {
      final diagnostics = TelemetryDiagnostics();
      expect(
        diagnostics.accept(stats(buserr: 20)),
        isEmpty,
      ); // lifetime baseline
      final current = stats(
        uptime: 2000,
        rx: 72,
        buserr: 25,
        rec: 10,
        arb: 1,
        noack: true,
        demo: true,
      );
      final events = diagnostics.accept(current);
      expect(events, hasLength(1));
      expect(events.single.data['busErrorDelta'], 5);
      expect(events.single.evidence, DiagnosticEvidence.telemetry);
      expect(events.single.data.containsKey('frameId'), isFalse);
      expect(events.single.data.containsKey('errorTypes'), isFalse);
      expect(diagnostics.accept(current), isEmpty);
      expect(
        diagnostics.accept(
          stats(
            uptime: 3000,
            rx: 108,
            buserr: 25,
            rec: 10,
            arb: 1,
            noack: true,
            demo: true,
          ),
        ),
        isEmpty,
      );
      expect(
        diagnostics.accept(stats(uptime: 1, rx: 1)).single.type,
        CanSessionEventType.note,
      );
    },
  );

  test(
    'healthy hardware analytics stays zero on repeated open and JSON roundtrip',
    () {
      final frames = List.generate(
        1000,
        (i) => CanFrame.create(
          id: 0x100,
          dlc: 1,
          data: [i % 256],
          timestamp: DateTime.utc(2026).add(Duration(milliseconds: i)),
        ),
      );
      final session = CanSession.create('Synthetic healthy control').updateWith(
        sourceName: 'BLE control',
        frames: frames,
        totalFrames: frames.length,
        statsSnapshots: [stats()],
      );
      final before = jsonEncode(session.toJson());
      for (var i = 0; i < 3; i++) {
        final restored = CanSession.fromJson(
          jsonDecode(before) as Map<String, dynamic>,
        );
        final data = SessionAnalyticsBuilder().build(restored);
        expect(data.errorStats.values.every((v) => v == 0), isTrue);
        expect(data.errorsPerId.single.errorFrames, 0);
        expect(data.errorsOverTime.every((p) => p.count == 0), isTrue);
        expect(SessionSummaryBuilder().build(restored).errorFrames, 0);
      }
      expect(jsonEncode(session.toJson()), before);
    },
  );

  test(
    'typed evidence aggregates occurrences and affected frames independently',
    () {
      final frame = CanFrame.create(
        id: 0x100,
        dlc: 1,
        data: [1],
        errors: [
          CanErrorInfo(
            type: CanErrorType.ackError,
            description: 'synthetic',
            severity: 2,
            origin: CanErrorOrigin.simulated,
          ),
          CanErrorInfo(
            type: CanErrorType.formatError,
            description: 'inferred',
            severity: 2,
          ),
        ],
      );
      final session = CanSession.create(
        'Synthetic control',
      ).updateWith(frames: [frame], totalFrames: 1);
      final data = SessionAnalyticsBuilder().build(session);
      expect(data.errorStats[CanErrorType.ackError], 1);
      expect(data.errorStats[CanErrorType.formatError], 1);
      expect(data.errorsPerId.single.errorFrames, 1);
      expect(data.bitErrorRatioOverTime.single.ratio, 1);
      expect(SessionSummaryBuilder().build(session).errorFrames, 1);
    },
  );
}

import 'dart:convert';
import 'dart:math';

import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/source/ble_message_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

String wire(int seq, {List<int> data = const [1, 255]}) => jsonEncode({
  't': 'f',
  'id': 0x123,
  'dlc': data.length,
  'data': data,
  'seq': seq,
  'ts': seq * 10,
});

void main() {
  test('consecutive frames and forward gap have separate baselines', () {
    final consecutive = BleSequenceTracker();
    for (final seq in [100, 101, 102]) {
      consecutive.accept(seq, seq * 10);
    }
    expect(consecutive.gaps, 0);
    expect(consecutive.duplicates, 0);
    expect(consecutive.resets, 0);
    expect(consecutive.outOfOrder, 0);
    final gap = BleSequenceTracker();
    gap.accept(100, 1000);
    gap.accept(102, 1020);
    expect(gap.gaps, 1);
  });

  test('adjacent duplicates remain counted', () {
    final tracker = BleSequenceTracker();
    for (final seq in [100, 101, 101, 102]) {
      tracker.accept(seq, seq * 10);
    }
    expect(tracker.duplicates, 1);
    expect(tracker.gaps, 0);
  });

  test('older sequence and capture timestamp do not prove receiver reset', () {
    final tracker = BleSequenceTracker();
    for (final seq in [100, 103, 101, 102, 104]) {
      tracker.accept(seq, seq * 10);
    }
    expect(tracker.resets, 0);
    expect(tracker.outOfOrder, 2);
    expect(tracker.gaps, 2); // Gross skips, even when late frames fill them.
    expect(tracker.duplicates, 0);
  });

  test('nonadjacent replay is counted without moving high water backwards', () {
    final tracker = BleSequenceTracker();
    for (final seq in [1037, 1076, 1037, 1077]) {
      tracker.accept(seq, seq * 10);
    }
    expect(tracker.duplicates, 1);
    expect(tracker.resets, 0);
    expect(tracker.outOfOrder, 1);
    expect(tracker.gaps, 38);
  });

  test('1076 -> 1037 -> 1077 replay cannot invent 39 missing sequences', () {
    final tracker = BleSequenceTracker();
    for (var seq = 1037; seq <= 1076; seq++) {
      tracker.accept(seq, seq * 10);
    }
    tracker.accept(1037, 10370);
    tracker.accept(1077, 10770);
    expect(tracker.gaps, 0);
    expect(tracker.duplicates, 1);
    expect(tracker.outOfOrder, 1);
    expect(tracker.resets, 0);
  });

  test(
    'smaller sequence without timestamps or telemetry remains out of order',
    () {
      final tracker = BleSequenceTracker();
      tracker.accept(3817, null);
      tracker.accept(3763, null);
      tracker.accept(3818, null);
      tracker.accept(null, 100);
      expect(tracker.resets, 0);
      expect(tracker.outOfOrder, 1);
      expect(tracker.gaps, 0);
      expect(tracker.missingSequence, 1);
      expect(tracker.toJson()['sequenceTrackingVersion'], 2);
    },
  );

  test(
    'reboot needs progressing FF12 rollback evidence; totals survive it',
    () {
      final tracker = BleSequenceTracker();
      tracker.observeTelemetry(100000, 5000);
      tracker.accept(4998, 99900);
      tracker.accept(5000, 99980); // One observed skip before reboot.
      tracker.accept(5000, 99980);
      tracker.accept(1, 100); // Cannot confirm a reboot from this alone.
      expect(tracker.resets, 0);
      tracker.observeTelemetry(1000, 10);
      tracker.observeTelemetry(1000, 10); // Duplicate stats do not confirm.
      expect(tracker.resets, 0);
      tracker.observeTelemetry(2000, 20);
      tracker.accept(21, 2010);
      tracker.accept(22, 2020);
      tracker.observeTelemetry(3000, 30);
      expect(tracker.resets, 1);
      expect(tracker.outOfOrder, 1);
      expect(tracker.gaps, 1);
      expect(tracker.duplicates, 1);
    },
  );

  test(
    'one old FF12 snapshot followed by current telemetry is not a reset',
    () {
      final tracker = BleSequenceTracker();
      tracker.observeTelemetry(100000, 5000);
      tracker.accept(5000, 99990);
      tracker.observeTelemetry(1000, 10);
      tracker.observeTelemetry(101000, 5036);
      tracker.accept(5001, 100010);
      expect(tracker.resets, 0);
      expect(tracker.gaps, 0);
    },
  );

  test('uptime regression alone and legacy telemetry cannot confirm reset', () {
    final tracker = BleSequenceTracker();
    tracker.observeTelemetry(100000, 5000);
    tracker.observeTelemetry(1000, 5001);
    tracker.observeTelemetry(2000, 5002);
    tracker.observeTelemetry(null, 1);
    tracker.accept(5000, 99900);
    tracker.accept(1, 100);
    expect(tracker.resets, 0);
    expect(tracker.outOfOrder, 1);
  });

  test(
    'uint32 sequence/uptime/RX wrap and late pre-wrap replay stay distinct',
    () {
      final tracker = BleSequenceTracker();
      tracker.observeTelemetry(0xfffffff0, 0xfffffffe);
      tracker.accept(0xfffffffe, 0xfffffff0);
      tracker.accept(0xffffffff, 0xfffffff1);
      tracker.accept(0, 5);
      tracker.accept(0xfffffffe, 0xfffffff0);
      tracker.observeTelemetry(1000, 30);
      tracker.observeTelemetry(2000, 60);
      tracker.accept(1, 2001);
      expect(tracker.resets, 0);
      expect(tracker.gaps, 0);
      expect(tracker.duplicates, 1);
      expect(tracker.outOfOrder, 1);
    },
  );

  test(
    'range-based duplicate evidence agrees with an independent Set oracle',
    () {
      final tracker = BleSequenceTracker();
      final random = Random(47);
      final seen = <int>{};
      int? high;
      var gaps = 0, duplicates = 0, outOfOrder = 0;
      for (var i = 0; i < 10000; i++) {
        final seq = 1000 + random.nextInt(7000);
        if (!seen.add(seq)) duplicates++;
        if (high != null && seq < high) outOfOrder++;
        if (high == null || seq > high) {
          if (high != null) gaps += seq - high - 1;
          high = seq;
        }
        tracker.accept(seq, seq * 10);
      }
      expect(tracker.gaps, gaps);
      expect(tracker.duplicates, duplicates);
      expect(tracker.outOfOrder, outOfOrder);
      expect(tracker.resets, 0);
    },
  );

  test(
    'sequential notifications, all split points and concatenation preserve order',
    () {
      final received = <CanFrame>[];
      final decoder = BleMessageDecoder(
        type: 'f',
        onMessage: (m) => received.add(m.frame!),
      );
      final expected = <int>[];
      for (var split = 1; split < utf8.encode(wire(100)).length; split++) {
        final bytes = utf8.encode(wire(100));
        decoder.add(bytes.sublist(0, split));
        decoder.add(bytes.sublist(split));
        expected.add(100);
      }
      decoder.add(utf8.encode('${wire(103)}${wire(101)}'));
      decoder.add(utf8.encode(wire(102)));
      expected.addAll([103, 101, 102]);
      expect(received.map((f) => f.sequence), expected);
      for (final frame in received) {
        expect(frame.data, frame.rawWire!['data']);
        expect(frame.sequence, frame.rawWire!['seq']);
        expect(frame.receiverTimestampMs, frame.rawWire!['ts']);
        expect(frame.id, frame.rawWire!['id']);
        expect(frame.dlc, frame.rawWire!['dlc']);
      }
      received.first.data[0] = 77;
      expect(received[1].data, [1, 255]); // No reused mutable frame payload.
      expect(received.first.rawWire!['data'], [1, 255]);
    },
  );

  test(
    'duplicate full notification is retained and counted, never filtered',
    () {
      final received = <CanFrame>[];
      final tracker = BleSequenceTracker();
      final decoder = BleMessageDecoder(
        type: 'f',
        onMessage: (m) {
          received.add(m.frame!);
          tracker.accept(m.frame!.sequence, m.frame!.receiverTimestampMs);
        },
      );
      decoder.add(utf8.encode(wire(100)));
      decoder.add(utf8.encode(wire(101)));
      decoder.add(utf8.encode(wire(100)));
      expect(received.map((f) => f.sequence), [100, 101, 100]);
      expect(tracker.duplicates, 1);
      expect(tracker.outOfOrder, 1);
      expect(tracker.resets, 0);
    },
  );

  test('duplicate prefix abandons partial; malformed middle is rejected', () {
    final received = <CanFrame>[];
    final decoder = BleMessageDecoder(
      type: 'f',
      onMessage: (m) => received.add(m.frame!),
    );
    final bytes = utf8.encode(wire(100));
    decoder.add(bytes.sublist(0, 12));
    decoder.add(bytes.sublist(0, 12));
    decoder.add(bytes.sublist(12));
    expect(received.map((f) => f.sequence), [100]);
    expect(decoder.incomplete, 1);
    decoder.add(utf8.encode('{"t":"f","id":'));
    decoder.add(utf8.encode('oops,"data":[1],"dlc":1,"seq":101,"ts":1010}'));
    expect(decoder.rejected, 1);
    decoder.add(utf8.encode('{"t":"f",'));
    decoder.reset(); // Disconnect: next session must not join the old tail.
    decoder.add(utf8.encode(wire(102)));
    expect(received.map((f) => f.sequence), [100, 102]);
    expect(decoder.incomplete, 2);
  });

  test(
    'protocol cannot detect a repeated numeric fragment that stays valid JSON',
    () {
      final received = <CanFrame>[];
      final decoder = BleMessageDecoder(
        type: 'f',
        onMessage: (m) => received.add(m.frame!),
      );
      decoder.add(utf8.encode('{"t":"f","id":1,"dlc":1,"data":['));
      decoder.add(utf8.encode('1'));
      decoder.add(
        utf8.encode('1'),
      ); // Repeated fragment: still a valid byte 11.
      decoder.add(utf8.encode('],"seq":100,"ts":1000}'));
      expect(received.single.data, [11]);
      expect(received.single.rawWire!['data'], [11]);
      // No fragment ID/checksum exists on FF11. This is a protocol limitation,
      // not evidence that this happened in Schema 2. Never guess a byte to drop.
    },
  );

  test('malformed CAN fields never reach BLE consumers', () {
    final received = <CanFrame>[];
    final decoder = BleMessageDecoder(
      type: 'f',
      onMessage: (m) => received.add(m.frame!),
    );
    final valid = jsonDecode(wire(100)) as Map<String, dynamic>;
    for (final invalid in [
      {...valid, 'id': 0x800},
      {...valid, 'dlc': 9},
      {
        ...valid,
        'data': [1],
      },
      {
        ...valid,
        'data': [1, 256],
      },
      {...valid, 'seq': -1},
      {...valid, 'seq': 0x100000000},
      {...valid, 'ts': -1},
      {...valid, 'ts': 1.5},
      {...valid, 'rtr': 1},
      {...valid, 'extd': 2},
    ]) {
      decoder.add(utf8.encode(jsonEncode(invalid)));
    }
    expect(received, isEmpty);
    expect(decoder.rejected, 10);
    decoder.add(
      utf8.encode(jsonEncode({...valid, 'id': 0x1fffffff, 'extd': 1})),
    );
    decoder.add(utf8.encode(jsonEncode({...valid, 'data': [], 'rtr': 1})));
    expect(received, hasLength(2));
    expect(received.first.isExtended, isTrue);
    expect(received.last.isRtr, isTrue);
    expect(received.last.data, isEmpty);
  });
}

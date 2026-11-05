import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/domain/source/serial_json_decoder.dart';

Map<String, dynamic> frame({int id = 192, int seq = 1}) => {
  't': 'f',
  'id': id,
  'dlc': 2,
  'data': [0, 255],
  'ts': 123,
  'seq': seq,
};
Map<String, dynamic> stats() => {
  't': 's',
  'rx': 2,
  'txe': 0,
  'rxe': 0,
  'state': 'running',
  'missed': 0,
  'buserr': 0,
};

void main() {
  late List<SerialMessage> messages;
  late List<String> rejected;
  late SerialJsonDecoder decoder;
  setUp(() {
    messages = [];
    rejected = [];
    decoder = SerialJsonDecoder(
      onMessage: messages.add,
      onRejected: (reason, _) => rejected.add(reason),
    );
  });

  test(
    'every byte boundary, concatenation, CRLF and split UTF-8 preserve messages',
    () {
      final wire = utf8.encode(
        '${jsonEncode({...frame(), 'note': 'Привіт'})}\r\n${jsonEncode(stats())}\n',
      );
      for (final byte in wire) {
        decoder.add([byte]);
      }
      expect(messages, hasLength(2));
      expect(rejected, isEmpty);
      expect(messages.first.frame!.data, [0, 255]);
      expect(messages.last.stats!.isRunning, isTrue);
      expect(messages.first.json['ts'], 123);
      expect(messages.first.frame!.isCorrupted, isFalse);
      expect(messages.first.frame!.errors, isEmpty);
      expect(decoder.bufferedBytes, 0);
      decoder.add(
        utf8.encode('${jsonEncode(frame())}\n${jsonEncode(frame())}\n'),
      );
      expect(messages, hasLength(4));
    },
  );

  test('RTR and maximum extended IDs retain their flags', () {
    decoder.add(
      utf8.encode(
        '${jsonEncode({...frame(), 'id': 0x1fffffff, 'extd': 1, 'rtr': 1, 'dlc': 8, 'data': []})}\n',
      ),
    );
    expect(messages.single.frame!.isExtended, isTrue);
    expect(messages.single.frame!.isRtr, isTrue);
    expect(messages.single.frame!.dlc, 8);
  });

  test(
    'bad UTF-8, JSON, type, required fields and numeric ranges are rejected independently',
    () {
      decoder.add([0xff, 10]);
      final invalid = <Object>[
        'boot log',
        [],
        {'t': 'x'},
        {...frame(), 'id': 2048},
        {...frame(), 'dlc': 9},
        {
          ...frame(),
          'data': [256, 0],
        },
        {
          ...frame(),
          'data': [1],
        },
        {...frame(), 'ts': -1},
        {...frame(), 'rtr': 1.0},
        {...stats(), 'rx': '2'},
        {...stats(), 'state': 'whatever'},
        {'t': 'f'},
      ];
      for (final item in invalid) {
        decoder.add(utf8.encode('${jsonEncode(item)}\n'));
      }
      decoder.add(utf8.encode('${jsonEncode(frame())}\n'));
      expect(rejected.length, invalid.length + 1);
      expect(messages, hasLength(1));
    },
  );

  test(
    'oversized line discards through newline and resets for the next line',
    () {
      final bounded = SerialJsonDecoder(
        maxMessageBytes: 100,
        onMessage: messages.add,
        onRejected: (reason, _) => rejected.add(reason),
      );
      bounded.add(List.filled(10000, 65));
      expect(bounded.bufferedBytes, 0);
      expect(rejected, hasLength(1));
      bounded.add(utf8.encode('\n${jsonEncode(frame())}\n'));
      expect(messages, hasLength(1));
      bounded.add(utf8.encode('{"t":'));
      bounded.reset();
      bounded.add(utf8.encode('${jsonEncode(frame())}\n'));
      expect(messages, hasLength(2));
    },
  );
}

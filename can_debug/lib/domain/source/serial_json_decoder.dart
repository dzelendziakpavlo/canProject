import 'dart:convert';

import '../models/can_frame.dart';
import '../models/can_stats.dart';

/// One validated wire message. ESP uptime is deliberately separate from UTC.
class SerialMessage {
  const SerialMessage(
    this.json,
    this.raw,
    this.hostReceivedAt, {
    this.frame,
    this.stats,
  });
  final Map<String, dynamic> json;
  final String raw;
  final DateTime hostReceivedAt;
  final CanFrame? frame;
  final CanStats? stats;
}

/// Bounded byte framing; UTF-8 is decoded only after a complete line arrives.
class SerialJsonDecoder {
  SerialJsonDecoder({
    required this.onMessage,
    required this.onRejected,
    this.maxMessageBytes = 2048,
  }) {
    if (maxMessageBytes < 1) throw ArgumentError.value(maxMessageBytes);
  }
  final void Function(SerialMessage) onMessage;
  final void Function(String reason, String? raw) onRejected;
  final int maxMessageBytes;
  final List<int> _buffer = [];
  bool _discarding = false;
  int completedLines = 0;
  int get bufferedBytes => _buffer.length;

  void reset() {
    _buffer.clear();
    _discarding = false;
  }

  void add(List<int> bytes) {
    for (final byte in bytes) {
      if (byte == 10) {
        completedLines++;
        if (!_discarding && _buffer.isNotEmpty) _decode();
        reset();
      } else if (!_discarding) {
        if (_buffer.length >= maxMessageBytes) {
          _buffer.clear();
          _discarding = true;
          onRejected('Message exceeds $maxMessageBytes bytes', null);
        } else {
          _buffer.add(byte);
        }
      }
    }
  }

  void _decode() {
    String? raw;
    SerialMessage message;
    try {
      raw = utf8.decode(_buffer).trim();
      if (raw.isEmpty) return;
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Expected JSON object');
      }
      final host = DateTime.now().toUtc();
      _integer(value, 'seq', optional: true);
      switch (value['t']) {
        case 'f':
          final extended = _flag(value, 'extd');
          final rtr = _flag(value, 'rtr');
          final id = _integer(value, 'id')!;
          final dlc = _integer(value, 'dlc')!;
          _integer(value, 'ts');
          if (id > (extended ? 0x1fffffff : 0x7ff) || dlc > 8) {
            throw const FormatException('Invalid CAN ID or DLC');
          }
          final data = value['data'];
          if (data is! List ||
              data.any((b) => b is! int || b < 0 || b > 255) ||
              (rtr ? data.isNotEmpty : data.length != dlc)) {
            throw const FormatException('Invalid CAN payload');
          }
          message = SerialMessage(
            value,
            raw,
            host,
            frame: CanFrame.create(
              id: id,
              dlc: dlc,
              data: List<int>.from(data),
              timestamp: host,
              isRtr: rtr,
              isExtended: extended,
            ),
          );
        case 's':
          for (final key in ['rx', 'txe', 'rxe', 'missed', 'buserr']) {
            _integer(value, key);
          }
          for (final key in [
            'arb',
            'txfail',
            'ovr',
            'v',
            'uptime',
            'bitrate',
            'serialdrop',
            'bledrop',
            'queuedrop',
            'toolong',
            'serialstatdrop',
            'blestatdrop',
            'statdrop',
          ]) {
            _integer(value, key, optional: true);
          }
          _flag(value, 'noack');
          _flag(value, 'sdemo');
          final state = value['state'];
          if (state is! String ||
              ![
                'RUNNING',
                'STOPPED',
                'BUS_OFF',
                'RECOVERING',
                'UNKNOWN',
              ].contains(state.toUpperCase())) {
            throw const FormatException('Invalid TWAI state');
          }
          for (final key in ['node', 'fw', 'reason']) {
            if (value[key] != null && value[key] is! String) {
              throw FormatException('Invalid $key');
            }
          }
          final normalized = {
            ...value,
            'state': state.toUpperCase(),
            'timestamp': host.toIso8601String(),
          };
          // Use the existing wire factory, then its storage factory to set exact receipt time.
          final stats = CanStats.fromJson(normalized);
          message = SerialMessage(
            value,
            raw,
            host,
            stats: CanStats.fromStoredJson({
              ...stats.toJson(),
              'timestamp': host.toIso8601String(),
            }),
          );
        default:
          throw FormatException('Unknown message type: ${value['t']}');
      }
    } on FormatException catch (e) {
      onRejected(e.message, raw);
      return;
    } on TypeError catch (e) {
      onRejected(e.toString(), raw);
      return;
    }
    // Consumer failures (e.g. disk full) are not protocol errors.
    onMessage(message);
  }

  static int? _integer(
    Map<String, dynamic> json,
    String key, {
    bool optional = false,
  }) {
    final value = json[key];
    if (optional && value == null) return null;
    if (value is! int || value < 0 || value > 0xffffffff) {
      throw FormatException('Invalid $key');
    }
    return value;
  }

  static bool _flag(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return false;
    if (value is! int) throw FormatException('Invalid $key flag');
    if (value == 0) return false;
    if (value == 1) return true;
    throw FormatException('Invalid $key flag');
  }
}

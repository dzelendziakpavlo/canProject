import 'dart:collection';

import 'serial_json_decoder.dart';

/// Independent, bounded FF11/FF12 JSON object reassembly. GATT notifications
/// are not assumed to be complete messages. Firmware may still truncate them;
/// reassembly cannot reconstruct bytes that were never transmitted.
class BleMessageDecoder {
  BleMessageDecoder({required this.type, required this.onMessage});
  final String type;
  final void Function(SerialMessage) onMessage;
  final List<int> _buffer = [];
  int _depth = 0;
  bool _inString = false;
  bool _escaped = false;
  DateTime? _lastChunk;
  int notifications = 0, accepted = 0, rejected = 0, incomplete = 0;
  int discardedBytes = 0;
  int get bufferedBytes => _buffer.length;

  void startSession() {
    reset();
    notifications = 0;
    accepted = 0;
    rejected = 0;
    incomplete = 0;
    discardedBytes = 0;
  }

  void reset() {
    if (_buffer.isNotEmpty) incomplete++;
    _buffer.clear();
    _depth = 0;
    _inString = false;
    _escaped = false;
    _lastChunk = null;
  }

  void add(List<int> bytes, {DateTime? now}) {
    notifications++;
    final clock = now ?? DateTime.now();
    if (_lastChunk != null &&
        clock.difference(_lastChunk!) > const Duration(seconds: 2)) {
      reset();
    }
    // Each protocol object begins with {"t":. A new root at a notification
    // boundary replaces an abandoned partial object, rather than joining sessions.
    if (_buffer.isNotEmpty &&
        bytes.length >= 5 &&
        String.fromCharCodes(bytes.take(5)) == '{"t":') {
      reset();
    }
    _lastChunk = clock;
    for (final byte in bytes) {
      if (_buffer.isEmpty && byte != 123) {
        if (![9, 10, 13, 32].contains(byte)) discardedBytes++;
        continue;
      }
      if (_buffer.length >= 2048) {
        rejected++;
        reset();
      }
      if (_buffer.isEmpty && byte != 123) {
        discardedBytes++;
        continue;
      }
      _buffer.add(byte);
      if (_inString) {
        if (_escaped) {
          _escaped = false;
        } else if (byte == 92) {
          _escaped = true;
        } else if (byte == 34) {
          _inString = false;
        }
      } else if (byte == 34) {
        _inString = true;
      } else if (byte == 123) {
        _depth++;
      } else if (byte == 125) {
        _depth--;
        if (_depth == 0) {
          final complete = List<int>.from(_buffer);
          _buffer.clear();
          final decoder = SerialJsonDecoder(
            onMessage: (message) {
              if (message.json['t'] != type) {
                rejected++;
                return;
              }
              accepted++;
              onMessage(message);
            },
            onRejected: (_, _) => rejected++,
          );
          decoder.add([...complete, 10]);
        }
      }
    }
  }
}

/// Arrival-order observations, never a frame filter. Gaps count gross skips of
/// the forward high-water mark, not final missing IDs. Late arrivals never move
/// that mark backwards. Sequence arithmetic assumes steps smaller than 2^31.
class BleSequenceTracker {
  int? _last;
  int _position = 0;
  // Disjoint inclusive ranges of observed, unwrapped sequence positions. A
  // contiguous run costs one entry; this retains nonadjacent replay evidence
  // without retaining frames or a Set entry for every frame in a long capture.
  final _seen = SplayTreeMap<int, int>();
  int? _uptime, _rx, _restartUptime, _restartRx;
  int gaps = 0, duplicates = 0, resets = 0, missingSequence = 0, outOfOrder = 0;

  /// FF11 ts is the original capture uptime: an old/replayed frame also has an
  /// old ts. It cannot prove reboot. Require FF12 uptime AND total RX rollback,
  /// followed by another progressing snapshot below the previous baseline.
  /// One stale snapshot and uint32 uptime/RX wraps do not confirm a reset.
  /// Without a boot ID, even this corroboration is not absolute proof against
  /// replay of an entire old telemetry segment. Counters are never cleared.
  void observeTelemetry(int? uptime, int rx) {
    if (uptime == null) return;
    final previousUptime = _uptime;
    final previousRx = _rx;
    if (previousUptime != null &&
        previousRx != null &&
        _backwards(uptime, previousUptime) &&
        _backwards(rx, previousRx)) {
      if (_restartUptime != null &&
          _forward(uptime, _restartUptime!) &&
          (rx == _restartRx || _forward(rx, _restartRx!))) {
        resets++;
        _last = null;
        _seen.clear();
      } else {
        _restartUptime = uptime;
        _restartRx = rx;
        return;
      }
    } else if (previousUptime != null && _backwards(uptime, previousUptime)) {
      // Inconsistent/late telemetry must not replace the known baseline.
      _restartUptime = _restartRx = null;
      return;
    }
    _uptime = uptime;
    _rx = rx;
    _restartUptime = _restartRx = null;
  }

  static bool _backwards(int value, int previous) =>
      ((value - previous) & 0xffffffff) >= 0x80000000;
  static bool _forward(int value, int previous) {
    final delta = (value - previous) & 0xffffffff;
    return delta > 0 && delta < 0x80000000;
  }

  // ts stays in the API for callers, but is deliberately not reset evidence.
  void accept(int? seq, int? ts) {
    if (seq == null) {
      missingSequence++;
      return;
    }
    if (_last == null) {
      _last = seq;
      _position = seq;
      _remember(_position);
      return;
    }
    final delta = (seq - _last!) & 0xffffffff;
    final signedDelta = delta >= 0x80000000 ? delta - 0x100000000 : delta;
    final position = _position + signedDelta;
    if (!_remember(position)) duplicates++;
    if (signedDelta < 0) outOfOrder++;
    if (signedDelta <= 0) return;
    if (delta > 1) gaps += delta - 1;
    _last = seq;
    _position = position;
  }

  bool _remember(int position) {
    final left = _seen.containsKey(position)
        ? position
        : _seen.lastKeyBefore(position);
    if (left != null && _seen[left]! >= position) return false;
    final right = _seen.firstKeyAfter(position);
    var start = position;
    var end = position;
    if (left != null && _seen[left] == position - 1) {
      start = left;
      _seen.remove(left);
    }
    if (right == position + 1) {
      end = _seen.remove(right)!;
    }
    _seen[start] = end;
    return true;
  }

  Map<String, dynamic> toJson() => {
    'sequenceTrackingVersion': 2,
    'sequenceGapSemantics': 'cumulative_forward_high_water_skips',
    'duplicateSequenceScope': 'observed_receiver_epoch',
    'receiverResetEvidence': 'two_progressing_FF12_uptime_and_rx_rollbacks',
    'sequenceGaps': gaps,
    'duplicateSequences': duplicates,
    'receiverResets': resets,
    'missingSequence': missingSequence,
    'outOfOrder': outOfOrder,
  };
}

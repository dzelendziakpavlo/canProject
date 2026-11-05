import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/can_frame.dart';
import '../models/can_stats.dart';
import '../services/experiment_journal.dart';
import 'can_frame_source.dart';
import 'serial_connection.dart';
import 'serial_json_decoder.dart';

class SerialCanSource implements CanFrameSource {
  SerialCanSource({
    required this.portName,
    this.baudRate = 115200,
    this.journalDirectory,
    SerialConnector? connector,
    this.maxMessageBytes = 2048,
  }) : _connector = connector ?? openSerialConnection {
    if (baudRate < 1) throw ArgumentError.value(baudRate);
    _decoder = SerialJsonDecoder(
      onMessage: _onMessage,
      onRejected: _onRejected,
      maxMessageBytes: maxMessageBytes,
    );
  }
  final String portName;
  final int baudRate;
  final int maxMessageBytes;
  final Directory? journalDirectory;
  final SerialConnector _connector;
  late final SerialJsonDecoder _decoder;
  final _frames = StreamController<CanFrame>.broadcast(sync: true);
  final _stats = StreamController<CanStats>.broadcast(sync: true);
  final _states = StreamController<SourceState>.broadcast();
  SerialConnection? _connection;
  StreamSubscription<List<int>>? _subscription;
  ExperimentJournal? journal;
  SourceState state = SourceState.idle;
  String? lastError;
  String? lastParseError;
  int receivedFrames = 0,
      receivedStats = 0,
      serialParseErrors = 0,
      serialErrors = 0;
  int sequenceGaps = 0;
  final Map<String, int> firmwareCounters = {};
  int? _lastSequence, _lastEspTime;
  bool _running = false, _disposed = false;
  int _generation = 0;
  Future<void>? _starting, _closing;
  DateTime? lastMessageAt;
  int bytesRead = 0, readOperations = 0, readErrors = 0;
  int get completedLines => _decoder.completedLines;
  Map<String, dynamic> _lastTransportDiagnostics = {};
  Map<String, dynamic> get transportDiagnostics {
    final connection = _connection;
    return connection is SerialDiagnosticConnection
        ? connection.diagnostics
        : Map.unmodifiable(_lastTransportDiagnostics);
  }

  Map<String, dynamic> get connectionMetadata => {
    'transport': 'usbSerial',
    'port': portName,
    'baudRate': baudRate,
    'dataBits': 8,
    'parity': 'none',
    'stopBits': 1,
    'flowControl': 'none',
    'csvPath': journal?.csvPath,
    'jsonlPath': journal?.jsonlPath,
  };
  @override
  String get name => 'USB Serial — $portName @ $baudRate';
  @override
  Stream<CanFrame> get frameStream => _frames.stream;
  @override
  Stream<CanStats> get statsStream => _stats.stream;
  @override
  Stream<SourceState> get stateStream => _states.stream;

  void _emit(SourceState next) {
    state = next;
    if (!_disposed && !_states.isClosed) _states.add(next);
  }

  @override
  Future<void> start() {
    if (_disposed || _running) return _starting ?? Future.value();
    return _starting ??= _start().whenComplete(() {
      _starting = null;
    });
  }

  Future<void> _start() async {
    final generation = ++_generation;
    _running = true;
    lastError = null;
    _emit(SourceState.connecting);
    try {
      await _closing;
      receivedFrames = 0;
      bytesRead = 0;
      readOperations = 0;
      readErrors = 0;
      _decoder.completedLines = 0;
      _lastTransportDiagnostics = {};
      receivedStats = 0;
      serialParseErrors = 0;
      serialErrors = 0;
      sequenceGaps = 0;
      lastMessageAt = null;
      lastParseError = null;
      firmwareCounters.clear();
      journal = null;
      if (portName.trim().isEmpty) throw ArgumentError('Select a COM port');
      _decoder.reset();
      _lastSequence = null;
      _lastEspTime = null;
      final base =
          journalDirectory ??
          Directory(
            '${(await getApplicationDocumentsDirectory()).path}/CAN_Debug_Pro/experiments',
          );
      final openedJournal = await ExperimentJournal.open(
        base,
        metadata: {
          ...connectionMetadata,
          'source': name,
          'startedAt': DateTime.now().toUtc().toIso8601String(),
        },
        onFailure: (error) => _fail(
          'Experimental recording failed: $error',
          connectionError: false,
        ),
      );
      if (!_running || _disposed || generation != _generation) {
        await openedJournal.close();
        return;
      }
      journal = openedJournal;
      final opened = await _connector(portName, baudRate);
      if (!_running || _disposed || generation != _generation) {
        await opened.close();
        return;
      }
      _connection = opened;
      _emit(SourceState.connected);
      _subscription = opened.bytes.listen(
        (bytes) {
          if (!_running || _disposed) return;
          bytesRead += bytes.length;
          if (bytes.isNotEmpty) readOperations++;
          try {
            _decoder.add(bytes);
          } catch (error) {
            _fail(error.toString(), connectionError: journal?.failure == null);
          }
        },
        onError: (Object error) {
          readErrors++;
          _fail(error.toString());
        },
        onDone: () {
          if (_running && !_disposed) {
            _fail('USB Serial disconnected', disconnected: true);
          }
        },
      );
    } catch (error) {
      if (generation == _generation && !_disposed) {
        serialErrors++;
        lastError = error.toString();
        _running = false;
        _emit(SourceState.error);
      }
      await _cleanup();
    }
  }

  void _onMessage(SerialMessage message) {
    if (!_running || _disposed) return;
    final json = message.json;
    final seq = json['seq'] as int?;
    final esp = (json['ts'] ?? json['uptime']) as int?;
    // Decrease can mean reset or uint32 rollover; start a new sequence baseline.
    if (seq != null &&
        esp != null &&
        _lastEspTime != null &&
        esp < _lastEspTime!) {
      _lastSequence = null;
    }
    if (seq != null && _lastSequence != null && seq > _lastSequence! + 1) {
      sequenceGaps += seq - _lastSequence! - 1;
    }
    if (seq != null) _lastSequence = seq;
    if (seq != null && esp != null) _lastEspTime = esp;
    lastMessageAt = message.hostReceivedAt;
    if (message.frame != null) {
      receivedFrames++;
    } else {
      receivedStats++;
      for (final key in [
        'serialdrop',
        'bledrop',
        'queuedrop',
        'toolong',
        'serialstatdrop',
        'blestatdrop',
        'statdrop',
      ]) {
        if (json[key] is int) firmwareCounters[key] = json[key] as int;
      }
    }
    journal!.append({
      ...json,
      'hostReceivedAt': message.hostReceivedAt.toIso8601String(),
      'espTimestamp': esp,
      'source': name,
      'type': json['t'],
      if (message.frame != null) 'frameId': message.frame!.id,
      if (message.stats != null) ...{
        'txErrorCounter': message.stats!.txErrorCounter,
        'rxErrorCounter': message.stats!.rxErrorCounter,
        'busState': message.stats!.busState,
        'busErrorCount': message.stats!.busErrorCount,
        'rxTotal': message.stats!.rxTotal,
        'rxMissed': message.stats!.rxMissed,
        'rxOverrunCount': message.stats!.rxOverrunCount,
      },
      'serialParseErrors': serialParseErrors,
      'serialErrors': serialErrors,
      'sequenceGaps': sequenceGaps,
      'rawJson': message.raw,
    });
    if (!_running) return;
    if (state != SourceState.streaming) _emit(SourceState.streaming);
    if (message.frame != null) _frames.add(message.frame!);
    if (message.stats != null) _stats.add(message.stats!);
  }

  void _onRejected(String reason, String? raw) {
    if (!_running) return;
    serialParseErrors++;
    lastParseError = reason;
    journal!.append({
      'hostReceivedAt': DateTime.now().toUtc().toIso8601String(),
      'source': name,
      'type': 'rejected',
      'serialParseErrors': serialParseErrors,
      'serialErrors': serialErrors,
      'sequenceGaps': sequenceGaps,
      'rawJson': raw,
      'error': reason,
    });
  }

  void _fail(
    String error, {
    bool disconnected = false,
    bool connectionError = true,
  }) {
    if (!_running || _disposed) return;
    _running = false;
    if (connectionError) serialErrors++;
    lastError = error;
    _emit(disconnected ? SourceState.disconnected : SourceState.error);
    unawaited(_cleanup());
  }

  Future<void> _cleanup() => _closing ??= _closeResources().whenComplete(() {
    _closing = null;
  });
  Future<void> _closeResources() async {
    final subscription = _subscription;
    _subscription = null;
    final connection = _connection;
    if (connection is SerialDiagnosticConnection) {
      _lastTransportDiagnostics = connection.diagnostics;
    }
    _connection = null;
    await subscription?.cancel();
    try {
      await connection?.close();
      if (connection is SerialDiagnosticConnection) {
        _lastTransportDiagnostics = connection.diagnostics;
      }
    } catch (error) {
      lastError = 'Closing COM port failed: $error';
    }
    _decoder.reset();
    try {
      journal?.metadata.addAll({
        'stoppedAt': DateTime.now().toUtc().toIso8601String(),
        'receivedFrames': receivedFrames,
        'receivedStats': receivedStats,
        'bytesRead': bytesRead,
        'readOperations': readOperations,
        'readErrors': readErrors,
        'completedLines': completedLines,
        'transportDiagnostics': _lastTransportDiagnostics,
        'serialParseErrors': serialParseErrors,
        'serialErrors': serialErrors,
        'sequenceGaps': sequenceGaps,
        'lastError': lastError,
      });
      await journal?.close();
    } catch (error) {
      lastError = 'Closing experimental journal failed: $error';
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    ++_generation;
    await _starting;
    await _cleanup();
    _emit(SourceState.idle);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(
      stop().whenComplete(() {
        _frames.close();
        _stats.close();
        _states.close();
      }),
    );
  }
}

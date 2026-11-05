import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

abstract class SerialConnection {
  Stream<List<int>> get bytes;
  Future<void> close();
}

/// Optional transport facts. These counters never represent CAN bus errors.
abstract class SerialDiagnosticConnection implements SerialConnection {
  Map<String, dynamic> get diagnostics;
}

typedef SerialConnector =
    Future<SerialConnection> Function(String port, int baudRate);

class SerialPortInfo {
  const SerialPortInfo(
    this.name,
    this.description, {
    this.transport = 'unknown',
    this.vendorId,
    this.productId,
    this.serialNumber,
  });
  final String name;
  final String description;
  final String transport;
  final int? vendorId, productId;
  final String? serialNumber;

  String get label =>
      '$name — $description [$transport${vendorId == null ? '' : ' VID:${_hex(vendorId)} PID:${_hex(productId)}'}]';
  static String _hex(int? value) =>
      value?.toRadixString(16).padLeft(4, '0') ?? '????';
}

/// Prefer USB on first selection, but preserve an explicit existing choice.
String? preferredSerialPort(List<SerialPortInfo> ports, {String? current}) {
  if (ports.any((port) => port.name == current)) return current;
  for (final port in ports) {
    if (port.transport == 'USB') return port.name;
  }
  return ports.isEmpty ? null : ports.first.name;
}

String _nativeError(String operation) {
  final error = SerialPort.lastError;
  return error == null || error.errorCode == 0
      ? '$operation failed; the driver did not preserve a Windows error code. Check whether Serial Monitor or another program owns the port.'
      : '$operation failed: $error';
}

/// Native APIs are only touched inside Windows workers, never at import time.
Future<List<SerialPortInfo>> listSerialPorts() async {
  if (!Platform.isWindows) return const [];
  return Isolate.run(() {
    return SerialPort.availablePorts.map((name) {
      final port = SerialPort(name);
      try {
        final usb = port.transport == SerialPortTransport.usb;
        return SerialPortInfo(
          name,
          port.description ?? name,
          transport: usb
              ? 'USB'
              : port.transport == SerialPortTransport.bluetooth
              ? 'Bluetooth'
              : 'native / RS232',
          vendorId: usb ? port.vendorId : null,
          productId: usb ? port.productId : null,
          serialNumber: usb ? port.serialNumber : null,
        );
      } finally {
        port.dispose();
      }
    }).toList()..sort((a, b) => a.name.compareTo(b.name));
  });
}

Future<SerialConnection> openSerialConnection(String name, int baudRate) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('USB Serial is available on Windows');
  }
  return openSerialWorker(name, baudRate, _serialWorker);
}

/// Shared isolate protocol, also exercised by deterministic worker tests.
/// Production callers should use [openSerialConnection].
Future<SerialConnection> openSerialWorker(
  String name,
  int baudRate,
  void Function(List<dynamic>) entryPoint,
) async {
  final connection = _NativeSerialConnection();
  try {
    connection._worker = await Isolate.spawn(
      entryPoint,
      [connection._receive.sendPort, name, baudRate],
      onExit: connection._receive.sendPort,
      onError: connection._receive.sendPort,
    );
    await connection._ready.future.timeout(const Duration(seconds: 10));
    return connection;
  } catch (_) {
    await connection.close();
    rethrow;
  }
}

class _NativeSerialConnection implements SerialDiagnosticConnection {
  _NativeSerialConnection() {
    _controller = StreamController<List<int>>(
      sync: true,
      onListen: _grantRead,
      onResume: _grantRead,
    );
    _receive.listen(_onEvent);
  }
  final _receive = ReceivePort();
  late final StreamController<List<int>> _controller;
  final _ready = Completer<void>();
  final _done = Completer<void>();
  Isolate? _worker;
  SendPort? _commands;
  Future<void>? _closing;
  final Map<String, dynamic> _diagnostics = {};
  bool _readGranted = false;
  @override
  Map<String, dynamic> get diagnostics => Map.unmodifiable(_diagnostics);

  void _grantRead() {
    if (_controller.hasListener &&
        !_controller.isPaused &&
        !_readGranted &&
        _commands != null) {
      _readGranted = true;
      _commands!.send('ack');
    }
  }

  @override
  Stream<List<int>> get bytes => _controller.stream;

  void _onEvent(dynamic event) {
    if (event is SendPort) {
      _commands = event;
      _grantRead();
    } else if (event is Map && event['kind'] == 'diagnostics') {
      _diagnostics.addAll(Map<String, dynamic>.from(event['values'] as Map));
    } else if (event == 'ready') {
      if (!_ready.isCompleted) _ready.complete();
    } else if (event is Uint8List) {
      _readGranted = false;
      if (!_controller.isClosed) _controller.add(event);
      // At most one chunk is in flight; UI stalls cannot grow an isolate mailbox.
      _grantRead();
    } else if (event == null) {
      if (!_ready.isCompleted) {
        _ready.completeError(
          StateError('Serial worker exited during connection'),
        );
      }
      if (!_done.isCompleted) _done.complete();
      if (!_controller.isClosed) unawaited(_controller.close());
      _receive.close();
    } else {
      final error = StateError(
        'Cannot use COM port: $event. Close Serial Monitor and check the USB cable.',
      );
      if (!_ready.isCompleted) {
        _ready.completeError(error);
      } else if (!_controller.isClosed) {
        _controller.addError(error);
      }
    }
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _commands?.send('close');
    if (_worker != null) {
      try {
        await _done.future.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        _worker?.kill(priority: Isolate.immediate);
      }
    }
    _receive.close();
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}

void _serialWorker(List<dynamic> args) {
  final output = args[0] as SendPort;
  final name = args[1] as String;
  final baud = args[2] as int;
  final commands = ReceivePort();
  SerialPort? port;
  Timer? timer;
  var awaitingAck =
      true; // Start only after the main isolate attaches a listener.
  var closing = false;
  var pollCount = 0;
  var bytesRead = 0, readOperations = 0, readErrors = 0, acks = 0;
  var available = 0, lastReportMs = 0;
  var readerStarted = false;
  final clock = Stopwatch()..start();
  void report({String? error}) {
    output.send({
      'kind': 'diagnostics',
      'values': {
        'port': name,
        'baudRate': baud,
        'dataBits': 8,
        'parity': 'none',
        'stopBits': 1,
        'flowControl': 'none',
        'rts': 'off',
        'dtr': 'off',
        'readerStarted': readerStarted,
        'polls': pollCount,
        'awaitingAck': awaitingAck,
        'acknowledgements': acks,
        'bytesWaiting': available,
        'bytesRead': bytesRead,
        'readOperations': readOperations,
        'readErrors': readErrors,
        if (error != null) 'lastNativeError': error,
      },
    });
  }

  void finish() {
    if (closing) return;
    closing = true;
    timer?.cancel();
    commands.close();
    readerStarted = false;
    try {
      if (port?.isOpen ?? false) port!.close();
    } catch (_) {}
    report();
    port?.dispose();
    Isolate.exit();
  }

  try {
    output.send(commands.sendPort);
    if (!SerialPort.availablePorts.contains(name)) {
      throw StateError('$name is not present');
    }
    port = SerialPort(name);
    if (!port.openReadWrite()) throw StateError(_nativeError('Opening $name'));
    // libserialport 0.3.0+1 caches/owns port.config and disposes it with
    // port.dispose(). Do not free that config a second time in this worker.
    final config = port.config;
    config.baudRate = baud;
    config.bits = 8;
    config.parity = SerialPortParity.none;
    config.stopBits = 1;
    config.setFlowControl(SerialPortFlowControl.none);
    config.rts = SerialPortRts.off;
    config.dtr = SerialPortDtr.off;
    port.config = config;
    commands.listen((command) {
      if (command == 'ack') {
        acks++;
        awaitingAck = false;
      }
      if (command == 'close') finish();
    });
    timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      try {
        // Detect removal even on drivers that keep returning zero readable bytes.
        if (++pollCount % 200 == 0 &&
            !SerialPort.availablePorts.contains(name)) {
          throw StateError('$name disconnected');
        }
        available = port!.bytesAvailable;
        if (available < 0) throw StateError(_nativeError('Reading $name'));
        if (clock.elapsedMilliseconds - lastReportMs >= 1000) {
          lastReportMs = clock.elapsedMilliseconds;
          report();
        }
        if (awaitingAck) return;
        if (available > 0) {
          final bytes = port.read(available.clamp(1, 4096)); // nonblocking
          if (bytes.isNotEmpty) {
            bytesRead += bytes.length;
            readOperations++;
            awaitingAck = true;
            output.send(bytes);
          }
        }
      } catch (error) {
        readErrors++;
        report(error: error.toString());
        output.send(error.toString());
        finish();
      }
    });
    readerStarted = true;
    report();
    output.send('ready');
  } catch (error) {
    report(error: error.toString());
    output.send(error.toString());
    finish();
  }
}

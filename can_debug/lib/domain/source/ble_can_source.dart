  import 'dart:async';
  import 'dart:convert';
  import 'dart:io';

  import 'package:flutter/foundation.dart';

  import 'package:flutter_blue_plus/flutter_blue_plus.dart';

  import '../models/can_frame.dart';
  import '../models/can_stats.dart';
  import 'can_frame_source.dart';

  /// BLE source that connects to the ESP32 CAN-Monitor stand and streams
  /// CAN frames and TWAI stats via GATT notifications.
  ///
  /// GATT layout (must match receiver_ble.ino):
  ///   Service  0000FF10-0000-1000-8000-00805F9B34FB
  ///   Char     0000FF11-...  NOTIFY  → CAN frames  {"t":"f",...}
  ///   Char     0000FF12-...  NOTIFY  → TWAI stats  {"t":"s",...}
  class BleCanSource implements CanFrameSource {
    static const _svcUuid    = '0000ff10-0000-1000-8000-00805f9b34fb';
    static const _framesUuid = '0000ff11-0000-1000-8000-00805f9b34fb';
    static const _statsUuid  = '0000ff12-0000-1000-8000-00805f9b34fb';

    /// If set, connect to this specific device ID instead of scanning by name.
    final String? targetDeviceId;

    final _frameCtrl = StreamController<CanFrame>.broadcast();
    final _stateCtrl = StreamController<SourceState>.broadcast();
    final _statsCtrl = StreamController<CanStats>.broadcast();

    BluetoothDevice? _device;
    StreamSubscription? _scanSub;
    StreamSubscription? _connSub;
    StreamSubscription? _framesSub;
    StreamSubscription? _statsSub;

    bool _disposed = false;
    bool _running  = false;
    bool _connectInProgress = false;
    int  _reconnectAttempts = 0;
    Timer? _reconnectTimer;

    /// [initialDevice]: already-found device from BleConnectScreen scan — skips internal scan.
    /// [targetDeviceId]: fallback — scans and connects to this specific device ID.
    BleCanSource({this.targetDeviceId, BluetoothDevice? initialDevice})
        : _device = initialDevice;

    // ── CanFrameSource API ────────────────────────────────────────────────────

    @override
    String get name => 'BLE — ESP32 CAN Stand';

    @override
    Stream<CanFrame> get frameStream => _frameCtrl.stream;

    @override
    Stream<SourceState> get stateStream => _stateCtrl.stream;

    @override
    Stream<CanStats> get statsStream => _statsCtrl.stream;

    @override
    Future<void> start() async {
      if (!Platform.isAndroid) { _emit(SourceState.error); return; }
      if (_running || _disposed) return;
      _running = true;
      _reconnectAttempts = 0;
      // Skip scan if device was already found by the UI (BleConnectScreen)
      if (_device != null) {
        await _connect();
      } else {
        _emit(SourceState.scanning);
        await _scan();
      }
    }

    @override
    Future<void> stop() async {
      _running = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      await _tearDown();
      _emit(SourceState.idle);
    }

    @override
    void dispose() {
      _disposed = true;
      _running  = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _tearDown();
      _frameCtrl.close();
      _stateCtrl.close();
      _statsCtrl.close();
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    void _emit(SourceState s) {
      if (!_stateCtrl.isClosed) _stateCtrl.add(s);
    }

    /// Scan for the first device advertising Service UUID FF10
    /// (or the specific [targetDeviceId] if provided).
    Future<void> _scan() async {
      await _scanSub?.cancel();

      _scanSub = FlutterBluePlus.scanResults.listen((results) async {
        for (final r in results) {
          final match = targetDeviceId != null
              ? r.device.remoteId.str == targetDeviceId
              : r.advertisementData.serviceUuids
                  .any((u) => u.toString().toLowerCase() == _svcUuid);

          if (match) {
            await FlutterBluePlus.stopScan();
            await _scanSub?.cancel();
            _scanSub = null;
            _device = r.device;
            await _connect();
            return;
          }
        }
      });

      await FlutterBluePlus.startScan(
        withServices: [Guid(_svcUuid)],
        timeout: const Duration(seconds: 15),
      );
    }

    Future<void> _connect() async {
      if (_device == null || _disposed || !_running || _connectInProgress) return;
      _connectInProgress = true;
      _emit(SourceState.connecting);

      try {
        // Skip connect() if Android BLE stack already holds the connection
        final currentState = await _device!.connectionState.first;
        if (currentState != BluetoothConnectionState.connected) {
          // mtu: null — skip auto MTU request to avoid GATT_ERROR 133 on some devices
          await _device!.connect(
            autoConnect: false,
            timeout: const Duration(seconds: 10),
            mtu: null,
          );
        }
        // Small delay before MTU negotiation to let BLE stack stabilize
        await Future.delayed(const Duration(milliseconds: 300));
        try {
          await _device!.requestMtu(247);
        } catch (_) {
          // MTU negotiation may fail on some Android/ESP32 combos — continue anyway
        }
        _emit(SourceState.connected);

        // Watch for unexpected disconnects
        await _connSub?.cancel();
        _connSub = _device!.connectionState.listen((state) {
          if (state == BluetoothConnectionState.disconnected && !_disposed) {
            _emit(SourceState.disconnected);
            _scheduleReconnect();
          }
        });

        await _subscribe();
        _emit(SourceState.streaming);
        _reconnectAttempts = 0;

      } catch (e) {
        _emit(SourceState.error);
        _scheduleReconnect();
      } finally {
        _connectInProgress = false;
      }
    }

    Future<void> _subscribe() async {
      await _framesSub?.cancel();
      await _statsSub?.cancel();
      final services = await _device!.discoverServices();

      // Log all discovered services/chars to diagnose UUID format issues
      for (final s in services) {
        debugPrint('[BLE] service: ${s.serviceUuid}');
        for (final c in s.characteristics) {
          debugPrint('[BLE]   char: ${c.characteristicUuid}');
        }
      }

      BluetoothService? svc;
      for (final s in services) {
        final uuid = s.serviceUuid.toString().toLowerCase();
        if (uuid == _svcUuid || uuid == 'ff10' || uuid.contains('ff10')) {
          svc = s;
          break;
        }
      }
      if (svc == null) {
        throw StateError(
          'FF10 service not found. Found: ${services.map((s) => s.serviceUuid).join(", ")}',
        );
      }

      BluetoothCharacteristic? framesChar;
      BluetoothCharacteristic? statsChar;
      for (final c in svc.characteristics) {
        final uuid = c.characteristicUuid.toString().toLowerCase();
        debugPrint('[BLE] checking char: $uuid');
        if (uuid == _framesUuid || uuid == 'ff11' || uuid.contains('ff11')) {
          framesChar = c;
        } else if (uuid == _statsUuid || uuid == 'ff12' || uuid.contains('ff12')) {
          statsChar = c;
        }
      }
      if (framesChar == null) throw StateError('FF11 (frames) characteristic not found');
      if (statsChar == null) throw StateError('FF12 (stats) characteristic not found');

      await framesChar.setNotifyValue(true);
      _framesSub = framesChar.onValueReceived.listen(_onFrameBytes);

      await statsChar.setNotifyValue(true);
      _statsSub = statsChar.onValueReceived.listen(_onStatsBytes);
    }

    void _onFrameBytes(List<int> bytes) {
      try {
        final json = jsonDecode(String.fromCharCodes(bytes)) as Map<String, dynamic>;
        if (json['t'] != 'f') return;
        final frame = CanFrame.create(
          id:        json['id']  as int,
          dlc:       json['dlc'] as int,
          data:      List<int>.from(json['data'] as List),
          timestamp: DateTime.now(),
          isRtr:      (json['rtr']  as int?) == 1,
          isExtended: (json['extd'] as int?) == 1,
        );
        if (!_frameCtrl.isClosed) _frameCtrl.add(frame);
      } catch (_) {
      }
    }

    void _onStatsBytes(List<int> bytes) {
      try {
        final json = jsonDecode(String.fromCharCodes(bytes)) as Map<String, dynamic>;
        if (json['t'] != 's') return;

        final stats = CanStats.fromJson(json);
        if (!_statsCtrl.isClosed) _statsCtrl.add(stats);
      } catch (_) {

      }
    }

    /// Exponential backoff: 4 s, 8 s, 16 s, 32 s, 32 s (capped)
    void _scheduleReconnect() {
      if (_disposed || !_running || _reconnectTimer != null) return;
      _reconnectAttempts++;
      final seconds = 1 << _reconnectAttempts.clamp(2, 5); // 4,8,16,32,32
      _emit(SourceState.reconnecting);
      _reconnectTimer = Timer(Duration(seconds: seconds), () {
        _reconnectTimer = null;
        if (!_disposed && _running) _connect();
      });
    }

    Future<void> _tearDown() async {
      if (!Platform.isAndroid) return;
      await _framesSub?.cancel();
      await _statsSub?.cancel();
      await _connSub?.cancel();
      await _scanSub?.cancel();
      try { await FlutterBluePlus.stopScan(); } catch (_) {}
      try { await _device?.disconnect(); } catch (_) {}
      _framesSub = _statsSub = _connSub = _scanSub = null;
      _device = null;
    }
  }

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/theme.dart';
import '../../domain/source/ble_can_source.dart';
import 'monitor_screen.dart';

/// BLE device scan and connection screen.
/// Scans for ESP32 CAN-Monitor (service UUID FF10), shows RSSI list,
/// connects on tap and navigates to MonitorScreen with BleCanSource.
class BleConnectScreen extends StatefulWidget {
  const BleConnectScreen({super.key});

  @override
  State<BleConnectScreen> createState() => _BleConnectScreenState();
}

enum _ScanPhase { idle, scanning, connecting }

enum _CheckStatus { pass, warning, fail }

class _PreflightCheck {
  const _PreflightCheck(this.label, this.status, this.details);

  final String label;
  final _CheckStatus status;
  final String details;
}

class _BleConnectScreenState extends State<BleConnectScreen> {
  _ScanPhase _phase = _ScanPhase.idle;
  final List<ScanResult> _results = [];
  String? _connectingId;
  String? _errorMessage;

  StreamSubscription<List<ScanResult>>? _resultsSub;
  StreamSubscription<bool>? _isScanSub;

  @override
  void initState() {
    super.initState();

    _resultsSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          final idx = _results.indexWhere(
            (e) => e.device.remoteId == r.device.remoteId,
          );
          if (idx >= 0) {
            _results[idx] = r;
          } else {
            _results.add(r);
          }
        }
        // Sort strongest signal first
        _results.sort((a, b) => b.rssi.compareTo(a.rssi));
      });
    });

    _isScanSub = FlutterBluePlus.isScanning.listen((scanning) {
      if (!mounted) return;
      if (!scanning && _phase == _ScanPhase.scanning) {
        setState(() => _phase = _ScanPhase.idle);
      }
    });
  }

  @override
  void dispose() {
    _resultsSub?.cancel();
    _isScanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  /// Requests all BLE-relevant permissions.
  /// On Android ≤ 11: needs ACCESS_FINE_LOCATION granted + Location Services on.
  /// On Android 12+: needs BLUETOOTH_SCAN + BLUETOOTH_CONNECT.
  /// On non-Android platforms returns true immediately.
  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid) return true;

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final permanentlyDenied = statuses.values
        .any((s) => s.isPermanentlyDenied);
    final anyDenied = statuses.values
        .any((s) => !s.isGranted && !s.isLimited);

    if (anyDenied) {
      if (mounted) {
        setState(() => _errorMessage = permanentlyDenied
            ? 'BLE permissions permanently denied — open App Settings to grant them.'
            : 'BLE permissions required. Please allow when prompted.');
      }
      if (permanentlyDenied) openAppSettings();
      return false;
    }

    // Android ≤ 11: Location Services toggle must be ON (system setting)
    final locService = await Permission.locationWhenInUse.serviceStatus;
    if (!locService.isEnabled) {
      if (mounted) {
        setState(() => _errorMessage =
            'Enable Location Services in Android Settings → enable GPS/Location.');
      }
      return false;
    }

    return true;
  }

  Future<void> _startScan() async {
    if (!await _requestPermissions()) return;

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      setState(() => _errorMessage = 'Bluetooth is off. Please enable it.');
      return;
    }

    setState(() {
      _phase = _ScanPhase.scanning;
      _results.clear();
      _errorMessage = null;
    });

    try {
      // No withServices filter — ESP32 puts UUID in scan response, not primary adv.
      // We show all devices and highlight CAN-Monitor by name.
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _ScanPhase.idle;
          _errorMessage = 'Scan failed: $e';
        });
      }
    }
  }

  Future<void> _stopScan() async {
    await FlutterBluePlus.stopScan();
    if (mounted) setState(() => _phase = _ScanPhase.idle);
  }

  Future<void> _connectTo(ScanResult result) async {
    await FlutterBluePlus.stopScan();
    setState(() {
      _phase = _ScanPhase.connecting;
      _connectingId = result.device.remoteId.str;
    });

    final checks = await _runPreflight(result.device);
    if (!mounted) return;
    final shouldContinue = await _showPreflightResult(checks);
    if (!shouldContinue) {
      setState(() {
        _phase = _ScanPhase.idle;
        _connectingId = null;
      });
      return;
    }

    final source = BleCanSource(
      targetDeviceId: result.device.remoteId.str,
      initialDevice: result.device,
    );

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MonitorScreen(source: source)),
    );

    // Cleanup after returning from MonitorScreen (source disposed there)
    if (mounted) {
      setState(() {
        _phase = _ScanPhase.idle;
        _connectingId = null;
      });
    }
  }

  Future<List<_PreflightCheck>> _runPreflight(BluetoothDevice device) async {
    final checks = <_PreflightCheck>[
      const _PreflightCheck('Bluetooth adapter', _CheckStatus.pass, 'Adapter is enabled'),
    ];

    try {
      await device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 10),
        mtu: null,
      );
      checks.add(const _PreflightCheck('ESP32 connection', _CheckStatus.pass, 'Device connected'));

      final services = await device.discoverServices();
      BluetoothService? service;
      for (final candidate in services) {
        if (candidate.serviceUuid.toString().toLowerCase().contains('ff10')) {
          service = candidate;
          break;
        }
      }
      if (service == null) {
        checks.add(const _PreflightCheck('GATT service FF10', _CheckStatus.fail, 'Service was not found'));
      } else {
        checks.add(const _PreflightCheck('GATT service FF10', _CheckStatus.pass, 'Service found'));
        final characteristicUuids = service.characteristics.map((item) => item.characteristicUuid.toString().toLowerCase()).toList();
        final hasFrames = characteristicUuids.any((uuid) => uuid.contains('ff11'));
        final hasStats = characteristicUuids.any((uuid) => uuid.contains('ff12'));
        checks.add(_PreflightCheck(
          'Frames characteristic FF11',
          hasFrames ? _CheckStatus.pass : _CheckStatus.fail,
          hasFrames ? 'Notification characteristic found' : 'Characteristic was not found',
        ));
        checks.add(_PreflightCheck(
          'Stats characteristic FF12',
          hasStats ? _CheckStatus.pass : _CheckStatus.warning,
          hasStats ? 'Notification characteristic found' : 'Stats are unavailable; frames can still be monitored',
        ));
      }
    } catch (error) {
      checks.add(_PreflightCheck('ESP32 connection', _CheckStatus.fail, 'Connection failed: $error'));
    } finally {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    return checks;
  }

  Future<bool> _showPreflightResult(List<_PreflightCheck> checks) async {
    final hasFailure = checks.any((check) => check.status == _CheckStatus.fail);
    final hasWarning = checks.any((check) => check.status == _CheckStatus.warning);
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: AppTheme.darkSurface,
            title: const Text('Stand preflight check'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final check in checks) _PreflightRow(check: check),
                const SizedBox(height: 8),
                Text(
                  hasFailure
                      ? 'The stand is not ready for monitoring.'
                      : hasWarning
                          ? 'The stand is usable with limited telemetry.'
                          : 'The stand is ready.',
                  style: TextStyle(color: hasFailure ? AppTheme.accentRed : AppTheme.textSecondary),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
              if (!hasFailure)
                ElevatedButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Open monitor')),
            ],
          ),
        ) ??
        false;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBackground,
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.bluetooth, size: 20),
            SizedBox(width: 12),
            Text('Real Stand — ESP32'),
          ],
        ),
        backgroundColor: AppTheme.darkSurface,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        actions: [
          if (_phase == _ScanPhase.scanning)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.primaryOrange,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              _StatusBanner(phase: _phase, errorMessage: _errorMessage),
              _ScanButton(
                phase: _phase,
                onScan: _startScan,
                onStop: _stopScan,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _results.isEmpty
                    ? _EmptyState(phase: _phase)
                    : _DeviceList(
                        results: _results,
                        connectingId: _connectingId,
                        onConnect: _connectTo,
                      ),
              ),
              _InfoFooter(),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.phase, required this.errorMessage});

  final _ScanPhase phase;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    if (errorMessage != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: AppTheme.accentRed.withValues(alpha: 0.15),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: AppTheme.accentRed, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                errorMessage!,
                style: const TextStyle(color: AppTheme.accentRed, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    final (label, color) = switch (phase) {
      _ScanPhase.scanning   => ('Scanning for CAN-Monitor…', AppTheme.primaryAmber),
      _ScanPhase.connecting => ('Connecting…', AppTheme.primaryOrange),
      _ScanPhase.idle       => ('Ready to scan', AppTheme.textMuted),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppTheme.darkSurface,
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 13),
      ),
    );
  }
}

class _PreflightRow extends StatelessWidget {
  const _PreflightRow({required this.check});

  final _PreflightCheck check;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (check.status) {
      _CheckStatus.pass => (Icons.check_circle, AppTheme.accentGreen),
      _CheckStatus.warning => (Icons.warning_amber, AppTheme.primaryAmber),
      _CheckStatus.fail => (Icons.cancel, AppTheme.accentRed),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(check.label, style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
                Text(check.details, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanButton extends StatelessWidget {
  const _ScanButton({
    required this.phase,
    required this.onScan,
    required this.onStop,
  });

  final _ScanPhase phase;
  final VoidCallback onScan;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: SizedBox(
        width: double.infinity,
        child: phase == _ScanPhase.scanning
            ? OutlinedButton.icon(
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop Scan'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.darkBorder),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              )
            : ElevatedButton.icon(
                onPressed: phase == _ScanPhase.connecting ? null : onScan,
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Scan for Devices'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryOrange,
                  foregroundColor: AppTheme.textPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.results,
    required this.connectingId,
    required this.onConnect,
  });

  final List<ScanResult> results;
  final String? connectingId;
  final void Function(ScanResult) onConnect;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: results.length,
      itemBuilder: (ctx, i) {
        final r = results[i];
        return _DeviceTile(
          result: r,
          isConnecting: connectingId == r.device.remoteId.str,
          onConnect: () => onConnect(r),
        ).animate().fadeIn(delay: (i * 60).ms).slideY(begin: 0.1, end: 0);
      },
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.result,
    required this.isConnecting,
    required this.onConnect,
  });

  final ScanResult result;
  final bool isConnecting;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final name = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : 'Unknown Device';
    final id = result.device.remoteId.str;
    final rssi = result.rssi;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.primaryOrange.withValues(alpha: 0.3),
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: _RssiIcon(rssi: rssi),
        title: Text(
          name,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              id,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
            Text(
              '$rssi dBm',
              style: TextStyle(
                color: _rssiColor(rssi),
                fontSize: 11,
              ),
            ),
          ],
        ),
        trailing: isConnecting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.primaryOrange,
                ),
              )
            : ElevatedButton(
                onPressed: onConnect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryOrange,
                  foregroundColor: AppTheme.textPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Connect', style: TextStyle(fontSize: 13)),
              ),
      ),
    );
  }

  Color _rssiColor(int rssi) {
    if (rssi >= -60) return AppTheme.accentGreen;
    if (rssi >= -75) return AppTheme.primaryAmber;
    return AppTheme.accentRed;
  }
}

class _RssiIcon extends StatelessWidget {
  const _RssiIcon({required this.rssi});
  final int rssi;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;

    if (rssi >= -60) {
      icon = Icons.signal_wifi_4_bar;
      color = AppTheme.accentGreen;
    } else if (rssi >= -75) {
      icon = Icons.network_wifi_2_bar;
      color = AppTheme.primaryAmber;
    } else {
      icon = Icons.network_wifi_1_bar;
      color = AppTheme.accentRed;
    }

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.12),
      ),
      child: Icon(icon, color: color, size: 22),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.phase});
  final _ScanPhase phase;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              phase == _ScanPhase.scanning
                  ? Icons.bluetooth_searching
                  : Icons.bluetooth_disabled,
              size: 72,
              color: phase == _ScanPhase.scanning
                  ? AppTheme.primaryOrange
                  : AppTheme.darkBorder,
            )
                .animate(
                  onPlay: phase == _ScanPhase.scanning
                      ? (c) => c.repeat()
                      : null,
                )
                .then()
                .shimmer(
                  duration: 1800.ms,
                  color: AppTheme.primaryAmber.withValues(alpha: 0.4),
                ),
            const SizedBox(height: 20),
            Text(
              phase == _ScanPhase.scanning
                  ? 'Looking for CAN-Monitor…'
                  : 'No devices found',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (phase != _ScanPhase.scanning) ...[
              const SizedBox(height: 8),
              const Text(
                'Make sure the ESP32 CAN stand is powered on\nand advertising service UUID FF10.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoFooter extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 14, color: AppTheme.textMuted),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              'Service UUID: 0000FF10-0000-1000-8000-00805F9B34FB',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

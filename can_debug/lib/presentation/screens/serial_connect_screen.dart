import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../domain/source/can_frame_source.dart';
import '../../domain/source/serial_can_source.dart';
import '../../domain/source/serial_connection.dart';
import 'monitor_screen.dart';

class SerialConnectScreen extends StatefulWidget {
  const SerialConnectScreen({super.key});
  @override
  State<SerialConnectScreen> createState() => _SerialConnectScreenState();
}

class _SerialConnectScreenState extends State<SerialConnectScreen> {
  List<SerialPortInfo> _ports = const [];
  String? _selected, _error;
  int _baud = 115200;
  bool _loading = false, _connecting = false;
  SerialCanSource? _source;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!Platform.isWindows) {
      setState(() => _error = 'USB Serial is supported on Windows.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ports = await listSerialPorts();
      if (!mounted) return;
      setState(() {
        _ports = ports;
        _selected = preferredSerialPort(ports, current: _selected);
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'Cannot list COM ports: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _connect() async {
    if (_selected == null || _connecting) return;
    final source = SerialCanSource(portName: _selected!, baudRate: _baud);
    _source = source;
    setState(() {
      _connecting = true;
      _error = null;
    });
    await source.start();
    if (!mounted || _source != source) {
      source.dispose();
      return;
    }
    if (source.state == SourceState.error) {
      setState(() {
        _error = source.lastError;
        _connecting = false;
      });
      source.dispose();
      _source = null;
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => MonitorScreen(source: source)),
    );
    _source = null;
    if (mounted) {
      setState(() => _connecting = false);
      await _refresh();
    }
  }

  Future<void> _disconnect() async {
    final source = _source;
    _source = null;
    await source?.stop();
    source?.dispose();
    if (mounted) setState(() => _connecting = false);
  }

  @override
  void dispose() {
    _source?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppTheme.darkBackground,
    appBar: AppBar(title: const Text('USB Serial — ESP32 RECEIVER')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(Icons.usb, size: 52, color: AppTheme.primaryOrange),
            const SizedBox(height: 16),
            const Text(
              'Connect the RECEIVER with a USB data cable. Close Arduino Serial Monitor before connecting.',
            ),
            const SizedBox(height: 24),
            DropdownButtonFormField<String>(
              initialValue: _selected,
              key: ValueKey(_selected),
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'COM port'),
              items: _ports
                  .map(
                    (port) => DropdownMenuItem(
                      value: port.name,
                      child: Text(port.label, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: _connecting
                  ? null
                  : (value) => setState(() => _selected = value),
            ),
            const SizedBox(height: 16),
            if (_ports.any(
              (port) =>
                  port.name == _selected && port.transport == 'native / RS232',
            ))
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  'Selected port is native / RS232. Check the RECEIVER port by unplugging and reconnecting its USB cable; USB adapters are marked USB in this list.',
                  style: TextStyle(color: AppTheme.primaryAmber),
                ),
              ),
            DropdownButtonFormField<int>(
              initialValue: _baud,
              decoration: const InputDecoration(
                labelText: 'UART baud rate (8N1, no flow control)',
              ),
              items: [115200, 230400, 460800, 921600]
                  .map(
                    (rate) =>
                        DropdownMenuItem(value: rate, child: Text('$rate')),
                  )
                  .toList(),
              onChanged: _connecting
                  ? null
                  : (value) => setState(() => _baud = value!),
            ),
            const SizedBox(height: 16),
            const Text(
              'CAN bitrate stays at 500 kbit/s. UART baud must match SERIAL_BAUD in RECEIVER firmware.',
            ),
            const SizedBox(height: 16),
            Text(
              _connecting
                  ? 'Connecting / monitor open'
                  : _ports.isEmpty
                  ? 'No COM ports found'
                  : 'Disconnected — ready to connect',
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(
                  _error!,
                  style: const TextStyle(color: AppTheme.accentRed),
                ),
              ),
            if (_loading) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _connecting || _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh ports'),
                ),
                FilledButton.icon(
                  onPressed:
                      _connecting || _selected == null || !Platform.isWindows
                      ? null
                      : _connect,
                  icon: const Icon(Icons.usb),
                  label: const Text('Connect'),
                ),
                OutlinedButton.icon(
                  onPressed: _source == null ? null : _disconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              'Every received frame and telemetry packet is recorded to CSV and JSON Lines in Documents/CAN_Debug_Pro/experiments. The monitor shows the recording path and disk errors.',
            ),
          ],
        ),
      ),
    ),
  );
}

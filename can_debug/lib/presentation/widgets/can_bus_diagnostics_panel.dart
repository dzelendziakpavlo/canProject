import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/models/can_session_event.dart';
import '../../domain/services/telemetry_diagnostics.dart';

/// Presentation only: all evidence and transitions come from TelemetryDiagnostics.
class CanBusDiagnosticsPanel extends StatelessWidget {
  const CanBusDiagnosticsPanel({
    super.key,
    required this.snapshot,
    required this.events,
  });

  final CanBusDiagnosticsSnapshot snapshot;
  final List<CanSessionEvent> events;

  @override
  Widget build(BuildContext context) {
    final silent = snapshot.traffic == CanTrafficState.silent;
    final color = silent
        ? AppTheme.accentRed
        : snapshot.traffic == CanTrafficState.active
        ? AppTheme.accentGreen
        : AppTheme.textMuted;
    final transport = switch (snapshot.transport) {
      CanTransportState.active => 'Active — data arriving',
      CanTransportState.connected => 'Connected — awaiting data',
      CanTransportState.connecting => 'Connecting / reconnecting',
      CanTransportState.stale => 'Stale — no recent data',
      CanTransportState.disconnected => 'Disconnected',
      CanTransportState.stopped => 'Stopped',
    };
    final traffic = switch (snapshot.traffic) {
      CanTrafficState.active => 'Active',
      CanTrafficState.silent => 'Silent',
      CanTrafficState.unknown => 'Unknown',
    };
    final newest = events.reversed.take(3).toList();
    return Container(
      key: const ValueKey('can-bus-diagnostics'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.65)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'CAN Bus Diagnostics',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              Text(
                'Traffic: $traffic',
                key: const ValueKey('can-traffic-state'),
                style: TextStyle(color: color),
              ),
              Text(
                'Transport: $transport',
                key: const ValueKey('can-transport-state'),
              ),
              Text(
                'Node: ${snapshot.node} · Direction: Unknown',
                style: const TextStyle(color: AppTheme.textSecondary),
              ),
            ],
          ),
          if (silent)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'CAN traffic lost — no frames received',
                style: TextStyle(
                  color: AppTheme.accentRed,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (silent)
            const Text(
              'Transport is active; diagnostic telemetry continues. Physical cause unknown.',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            ),
          if (snapshot.transport == CanTransportState.stale ||
              snapshot.transport == CanTransportState.disconnected)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'CAN state is unknown while transport data is unavailable.',
                style: TextStyle(color: AppTheme.primaryAmber),
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metric('TWAI', snapshot.stats?.busState ?? 'Unknown'),
              _metric('TEC', _number('txe')),
              _metric('REC', _number('rxe')),
              _metric(
                'Bus errors',
                _number('buserr'),
                detail: snapshot.busErrorDelta == null
                    ? 'Δ N/A'
                    : 'Δ +${snapshot.busErrorDelta}',
              ),
              _metric('RX missed', _number('missed')),
              _metric('RX overrun', _number('ovr')),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Protocol error types',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final entry in snapshot.typedErrors.entries)
                _metric(
                  entry.key,
                  entry.value?.toString() ?? 'N/A',
                  detail: entry.value == null ? 'Not reported' : 'Hardware',
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Counters: hardware telemetry, current controller epoch. N/A means unavailable, not zero. '
            'ACK observations at SENDER are not provided by RECEIVER telemetry.',
            style: TextStyle(fontSize: 10, color: AppTheme.textSecondary),
          ),
          if (snapshot.lastTelemetryAt != null)
            Text(
              'Last telemetry received (host UTC): ${snapshot.lastTelemetryAt!.toIso8601String()}',
              style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
            ),
          const SizedBox(height: 8),
          if (newest.isEmpty)
            const Text(
              'No diagnostic transitions recorded',
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
            )
          else ...[
            const Text(
              'Recent diagnostic events',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            for (final event in newest) _event(event),
            if (events.length > 3)
              TextButton(
                onPressed: () => _showEvents(context),
                child: Text('View recent events (${events.length})'),
              ),
          ],
        ],
      ),
    );
  }

  String _number(String key) => snapshot.counter(key)?.toString() ?? 'N/A';

  Widget _metric(String label, String value, {String? detail}) => Container(
    constraints: const BoxConstraints(minWidth: 62),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: AppTheme.darkContainer,
      borderRadius: BorderRadius.circular(7),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
        ),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        if (detail != null)
          Text(
            detail,
            style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
          ),
      ],
    ),
  );

  Widget _event(CanSessionEvent event) {
    final hardware = event.evidence == DiagnosticEvidence.telemetry;
    final color = event.diagnosticSeverity == DiagnosticSeverity.info
        ? AppTheme.accentGreen
        : AppTheme.primaryOrange;
    final node = event.data['node'] ?? 'Unknown';
    final direction = event.data['direction'] ?? 'Unknown';
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(event.message, style: TextStyle(fontSize: 11, color: color)),
          Text(
            '${event.timestamp.toUtc().toIso8601String()} · $node · $direction · '
            '${hardware ? 'hardware (telemetry)' : event.evidence.name} · '
            '${event.data['timestampSource'] ?? 'Unknown clock'}',
            style: const TextStyle(fontSize: 9, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }

  void _showEvents(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('CAN diagnostic events'),
      content: SizedBox(
        width: 560,
        height: 400,
        child: ListView(children: events.reversed.map(_event).toList()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

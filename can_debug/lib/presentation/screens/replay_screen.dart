import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/models/can_frame.dart';
import '../../domain/models/can_session.dart';
import '../../domain/models/can_session_event.dart';
import '../../domain/source/can_frame_source.dart';
import '../../domain/source/replay_can_source.dart';

class ReplayScreen extends StatefulWidget {
  const ReplayScreen({super.key, required this.session});

  final CanSession session;

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen> {
  late final ReplayCanSource _source;
  StreamSubscription<CanFrame>? _frameSubscription;
  StreamSubscription<SourceState>? _stateSubscription;
  final List<CanFrame> _frames = [];
  double _progress = 0;
  double _speed = 1.0;
  bool _isPlaying = false;
  CanSessionEvent? _activeDiagnostic;
  DiagnosticSeverity? _eventFilter;

  @override
  void initState() {
    super.initState();
    _source = ReplayCanSource(widget.session);
    _frameSubscription = _source.frameStream.listen((frame) {
      if (!mounted) return;
      setState(() {
        _frames.insert(0, frame);
        if (_frames.length > 100) _frames.removeLast();
        _progress = _source.progress;
        _activeDiagnostic = _diagnosticAt(frame.timestamp);
      });
    });
    _stateSubscription = _source.stateStream.listen((state) {
      if (!mounted) return;
      setState(() => _isPlaying = state == SourceState.streaming && _source.isPlaying);
    });
  }

  @override
  void dispose() {
    _frameSubscription?.cancel();
    _stateSubscription?.cancel();
    _source.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _source.pause();
    } else {
      await _source.start();
    }
    if (mounted) setState(() => _isPlaying = _source.isPlaying);
  }

  void _setSpeed(double speed) {
    _source.setSpeed(speed);
    setState(() => _speed = speed);
  }

  void _seek(double value) {
    final position = Duration(milliseconds: (value * _source.duration.inMilliseconds).round());
    _source.seekTo(position);
    setState(() {
      _progress = value;
      _frames.clear();
      _activeDiagnostic = null;
    });
  }

  void _jumpToEvent(CanSessionEvent event) {
    _source.seekToEvent(event);
    final offset = _source.eventOffset(event);
    final durationMs = _source.duration.inMilliseconds;
    setState(() {
      _progress = durationMs == 0 ? 0 : (offset.inMilliseconds / durationMs).clamp(0.0, 1.0);
      _frames.clear();
      _activeDiagnostic = event;
    });
  }

  CanSessionEvent? _diagnosticAt(DateTime timestamp) {
    CanSessionEvent? result;
    for (final event in _source.diagnosticEvents) {
      if (!event.timestamp.isAfter(timestamp)) result = event;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBackground,
      appBar: AppBar(
        backgroundColor: AppTheme.darkSurface,
        foregroundColor: AppTheme.textPrimary,
        title: Text('Replay: ${widget.session.name}'),
      ),
      body: Column(
        children: [
          _buildControls(),
          if (_activeDiagnostic != null) _buildDiagnosticBanner(_activeDiagnostic!),
          _buildDiagnosticMarkers(),
          Expanded(child: _buildFrameList()),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final durationMs = _source.duration.inMilliseconds.toDouble();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      color: AppTheme.darkSurface,
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: _isPlaying ? 'Pause' : 'Play',
                onPressed: _togglePlayback,
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                color: AppTheme.primaryAmber,
              ),
              IconButton(
                tooltip: 'Restart',
                onPressed: () => _seek(0),
                icon: const Icon(Icons.restart_alt),
                color: AppTheme.textSecondary,
              ),
              const SizedBox(width: 8),
              const Text('Speed', style: TextStyle(color: AppTheme.textSecondary)),
              const SizedBox(width: 8),
              DropdownButton<double>(
                value: _speed,
                dropdownColor: AppTheme.darkContainer,
                items: const [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]
                    .map((value) => DropdownMenuItem(value: value, child: Text('${value}x')))
                    .toList(),
                onChanged: (value) {
                  if (value != null) _setSpeed(value);
                },
              ),
              const Spacer(),
              Text('${_frames.length} shown', style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
            ],
          ),
          Slider(
            value: _progress.clamp(0.0, 1.0),
            onChanged: durationMs == 0 ? null : _seek,
            activeColor: AppTheme.primaryOrange,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(_source.elapsed), style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
              Text(_formatDuration(_source.duration), style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosticBanner(CanSessionEvent event) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppTheme.primaryAmber.withValues(alpha: 0.12),
      child: Text(
        '${event.message}: ${event.explanation ?? ''} ${event.recommendation ?? ''}',
        style: const TextStyle(color: AppTheme.primaryAmber, fontSize: 12),
      ),
    );
  }

  Widget _buildDiagnosticMarkers() {
    final events = _source.diagnosticEvents
        .where((event) => _eventFilter == null || event.diagnosticSeverity == _eventFilter)
        .toList();
    if (_source.diagnosticEvents.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      color: AppTheme.darkBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.flag, color: AppTheme.primaryAmber, size: 16),
              const SizedBox(width: 6),
              const Text('Diagnostic markers', style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
              const Spacer(),
              DropdownButton<DiagnosticSeverity?>(
                value: _eventFilter,
                isDense: true,
                dropdownColor: AppTheme.darkContainer,
                hint: const Text('All', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                items: [
                  const DropdownMenuItem<DiagnosticSeverity?>(value: null, child: Text('All')),
                  ...DiagnosticSeverity.values.map(
                    (severity) => DropdownMenuItem(value: severity, child: Text(severity.name)),
                  ),
                ],
                onChanged: (value) => setState(() => _eventFilter = value),
              ),
            ],
          ),
          Expanded(
            child: events.isEmpty
                ? const Center(child: Text('No markers for this filter', style: TextStyle(color: AppTheme.textMuted, fontSize: 12)))
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: events.length,
                    itemBuilder: (context, index) {
                      final event = events[index];
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          avatar: Icon(Icons.flag, size: 15, color: _diagnosticColor(event.diagnosticSeverity)),
                          label: Text(event.message),
                          onPressed: () => _jumpToEvent(event),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Color _diagnosticColor(DiagnosticSeverity severity) {
    switch (severity) {
      case DiagnosticSeverity.info:
        return AppTheme.accentGreen;
      case DiagnosticSeverity.warning:
        return AppTheme.primaryAmber;
      case DiagnosticSeverity.error:
        return AppTheme.primaryOrange;
      case DiagnosticSeverity.critical:
        return AppTheme.accentRed;
    }
  }

  Widget _buildFrameList() {
    if (_frames.isEmpty) {
      return const Center(
        child: Text('Press Play to start replay', style: TextStyle(color: AppTheme.textMuted)),
      );
    }
    return ListView.builder(
      reverse: false,
      padding: const EdgeInsets.all(12),
      itemCount: _frames.length,
      itemBuilder: (context, index) {
        final frame = _frames[index];
        return ListTile(
          dense: true,
          leading: Icon(frame.isCorrupted ? Icons.error : Icons.memory, color: frame.isCorrupted ? AppTheme.accentRed : AppTheme.accentGreen),
          title: Text('${frame.idHex}  DLC ${frame.dlc}', style: const TextStyle(color: AppTheme.textPrimary, fontFamily: 'monospace')),
          subtitle: Text(frame.dataHex.isEmpty ? '-' : frame.dataHex, style: const TextStyle(color: AppTheme.textSecondary, fontFamily: 'monospace')),
          trailing: Text(frame.status, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final seconds = duration.inSeconds;
    final minutes = seconds ~/ 60;
    return '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

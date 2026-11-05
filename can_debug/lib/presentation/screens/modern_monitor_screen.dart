import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../bloc/can_frame_bloc.dart';
import '../bloc/can_frame_event.dart';
import '../bloc/can_frame_state.dart';
import '../widgets/professional_charts.dart';
import '../widgets/can_network_topology.dart';
import '../../domain/models/can_frame.dart';
import '../../domain/detection/can_error_checker.dart';

/// Модернізований Monitor Screen з BLoC архітектурою та професійними charts
class ModernMonitorScreen extends StatelessWidget {
  const ModernMonitorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => GetIt.instance<CanFrameBloc>(),
      child: const _MonitorScreenView(),
    );
  }
}

class _MonitorScreenView extends StatefulWidget {
  const _MonitorScreenView();

  @override
  State<_MonitorScreenView> createState() => _MonitorScreenViewState();
}

class _MonitorScreenViewState extends State<_MonitorScreenView>
    with TickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CAN Bus Monitor'),
        elevation: 0,
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
        actions: [
          BlocBuilder<CanFrameBloc, CanFrameState>(
            builder: (context, state) {
              final isRunning = state is CanFrameMonitoring && state.isRunning;
              return IconButton(
                onPressed: () {
                  if (isRunning) {
                    context.read<CanFrameBloc>().add(const StopMonitoring());
                  } else {
                    context.read<CanFrameBloc>().add(const StartMonitoring());
                  }
                },
                icon: Icon(isRunning ? Icons.stop : Icons.play_arrow),
                tooltip: isRunning ? 'Stop Monitoring' : 'Start Monitoring',
              );
            },
          ),
          IconButton(
            onPressed: () {
              context.read<CanFrameBloc>().add(const ResetMonitoring());
            },
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'export_json':
                  context.read<CanFrameBloc>().add(const ExportStatistics('json'));
                  break;
                case 'export_csv':
                  context.read<CanFrameBloc>().add(const ExportStatistics('csv'));
                  break;
                case 'settings':
                  _showSettingsDialog(context);
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'export_json',
                child: Row(
                  children: [
                    Icon(Icons.download),
                    SizedBox(width: 8),
                    Text('Export JSON'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'export_csv',
                child: Row(
                  children: [
                    Icon(Icons.table_chart),
                    SizedBox(width: 8),
                    Text('Export CSV'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings),
                    SizedBox(width: 8),
                    Text('Settings'),
                  ],
                ),
              ),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.monitor), text: 'Live Monitor'),
            Tab(icon: Icon(Icons.analytics), text: 'Analytics'),
            Tab(icon: Icon(Icons.hub), text: 'Network'),
          ],
        ),
      ),
      body: BlocListener<CanFrameBloc, CanFrameState>(
        listener: (context, state) {
          if (state is CanFrameError) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: Colors.red,
              ),
            );
          } else if (state is CanFrameExported) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Exported ${state.recordsExported} records to ${state.format.toUpperCase()}',
                ),
                backgroundColor: Colors.green,
              ),
            );
          }
        },
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildLiveMonitorTab(),
            _buildAnalyticsTab(),
            _buildNetworkTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveMonitorTab() {
    return BlocBuilder<CanFrameBloc, CanFrameState>(
      builder: (context, state) {
        // Determine chart data depending on state (live vs snapshot)
        final CanFrameMonitoring? monitoring = state is CanFrameMonitoring ? state : null;
        final CanFrameStopped? stopped = state is CanFrameStopped ? state : null;
        final isMonitoring = monitoring != null;
        final isStopped = stopped != null;
        final errorRateHistory = monitoring?.errorRateHistory ?? stopped?.errorRateHistory ?? <double>[];
        final errorStats = monitoring?.errorStats ?? stopped?.errorStats ?? {for (var t in CanErrorType.values) t: 0};
        final currentErrorRate = monitoring?.currentErrorRate ?? stopped?.currentErrorRate ?? 0.0;
        final isRunning = monitoring?.isRunning ?? false;

        return Column(
          children: [
            // Statistics Panel
            _buildStatisticsPanel(state),
            
            const Divider(height: 1),
            
            // Live/Snapshot Error Rate Chart
            if (isMonitoring || isStopped) ...[
              Container(
                height: 220,
                padding: const EdgeInsets.all(16.0),
                child: ProfessionalErrorRateChart(
                  errorRateHistory: errorRateHistory,
                  errorStats: errorStats,
                  currentErrorRate: currentErrorRate,
                  isRunning: isRunning,
                ),
              ),
              
              const Divider(height: 1),
            ],
            
            // Frame List Header
            _buildFrameListHeader(),
            
            // Frame List
            Expanded(child: _buildFrameList(state)),
          ],
        );
      },
    );
  }

  Widget _buildAnalyticsTab() {
    return BlocBuilder<CanFrameBloc, CanFrameState>(
      builder: (context, state) {
        final monitoringState = state is CanFrameMonitoring ? state : null;
        final stoppedState = state is CanFrameStopped ? state : null;
        final hasData = monitoringState != null || stoppedState != null;
        final errorStats = monitoringState?.errorStats ?? stoppedState?.errorStats ?? {for (var t in CanErrorType.values) t: 0};
        final framesPerSecond = monitoringState?.framesPerSecond ?? 0;
        final errorRatePercentage = monitoringState?.errorRatePercentage ?? _calculateStoppedErrorRate(stoppedState);
        final lastFrameTime = monitoringState?.lastFrameTime;

        if (!hasData) {
          return const Center(
            child: Text(
              'No analytics available. Start monitoring to gather data.',
              style: TextStyle(color: Colors.grey),
            ),
          );
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Header banner indicating live vs snapshot
              _buildSnapshotBanner(monitoringState != null),
              const SizedBox(height: 12),
              ErrorTypeDistributionChart(errorStats: errorStats),
              const SizedBox(height: 16),
              _buildSnapshotPerformanceMetrics(
                isLive: monitoringState != null,
                fps: framesPerSecond,
                errorRate: errorRatePercentage,
                lastFrame: lastFrameTime,
                totalFrames: monitoringState?.totalFrames ?? stoppedState?.totalFrames ?? 0,
                errorFrames: monitoringState?.errorFrames ?? stoppedState?.errorFrames ?? 0,
              ),
              const SizedBox(height: 16),
              _buildSnapshotDetailedStatistics(errorStats),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNetworkTab() {
    return BlocBuilder<CanFrameBloc, CanFrameState>(
      builder: (context, state) {
        final frames = state is CanFrameMonitoring
            ? state.frames
            : state is CanFrameStopped
                ? state.frames
                : <CanFrame>[];
        final isRunning = state is CanFrameMonitoring && state.isRunning;
        return Column(
          children: [
            _buildNetworkInfoBar(isRunning, frames.length),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: CanNetworkTopologyView(
                  frames: frames,
                  isRunning: isRunning,
                ),
              ),
            ),
            _buildNetworkFooterExplanation(),
          ],
        );
      },
    );
  }

  Widget _buildNetworkInfoBar(bool isRunning, int frameCount) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade800,
        border: const Border(bottom: BorderSide(color: Colors.black12)),
      ),
      child: Row(
        children: [
          Icon(Icons.hub, color: Colors.blue.shade200, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Live CAN topology: dynamic ECU/activity discovery based on recent frames',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          _buildMiniBadge(isRunning ? 'RUNNING' : 'IDLE', isRunning ? Colors.green : Colors.red),
          const SizedBox(width: 8),
          _buildMiniBadge('$frameCount frames', Colors.blueGrey.shade300),
        ],
      ),
    );
  }

  Widget _buildMiniBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildNetworkFooterExplanation() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade900,
        border: const Border(top: BorderSide(color: Colors.black26)),
      ),
      child: const Text(
        'Network tab demo: visualizes a simplified CAN bus topology.\n'
        '• Central "CAN Bus" hub connects predefined ECUs (Engine, ABS, Airbag, BCM, Cluster).\n'
        '• Active nodes pulse green based on IDs in the latest frames (last 50).\n'
        '• New CAN IDs appear as dynamic NODE_xx tiles auto-linked to the bus.\n'
        '• Layout menu lets you test hierarchical vs force vs circular graph algorithms.\n'
        'Use this demo to reason about activity distribution & bus participation — not a full physical wiring map.',
        style: TextStyle(color: Colors.white60, fontSize: 11, height: 1.35),
      ),
    );
  }

  Widget _buildStatisticsPanel(CanFrameState state) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: Theme.of(context).primaryColor.withOpacity(0.1),
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: BlocBuilder<CanFrameBloc, CanFrameState>(
        builder: (context, state) {
          if (state is CanFrameMonitoring) {
            return Row(
              children: [
                Expanded(child: _buildStatCard('Total Frames', '${state.totalFrames}')),
                Expanded(child: _buildStatCard('Error Frames', '${state.errorFrames}')),
                Expanded(child: _buildStatCard('Error Rate', '${state.errorRatePercentage.toStringAsFixed(1)}%')),
                Expanded(child: _buildStatCard('FPS', '${state.framesPerSecond.toStringAsFixed(1)}')),
              ],
            );
          } else if (state is CanFrameStopped) {
            final total = state.totalFrames;
            final errors = state.errorFrames;
            final rate = state.currentErrorRate;
            final fps = state.framesPerSecond;

            return Row(
              children: [
                Expanded(child: _buildStatCard('Total Frames', '$total')),
                Expanded(child: _buildStatCard('Error Frames', '$errors')),
                Expanded(child: _buildStatCard('Error Rate', '${rate.toStringAsFixed(1)}%')),
                Expanded(child: _buildStatCard('FPS', fps > 0 ? fps.toStringAsFixed(1) : '0.0')),
              ],
            );
          }
          
          return const Row(
            children: [
              Expanded(child: _StatCard(title: 'Total Frames', value: '0')),
              Expanded(child: _StatCard(title: 'Error Frames', value: '0')),
              Expanded(child: _StatCard(title: 'Error Rate', value: '0.0%')),
              Expanded(child: _StatCard(title: 'FPS', value: '0.0')),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatCard(String title, String value) {
    return _StatCard(title: title, value: value);
  }

  Widget _buildFrameListHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: const Row(
        children: [
          Expanded(flex: 2, child: Text('ID', style: TextStyle(fontWeight: FontWeight.bold))),
          Expanded(flex: 1, child: Text('DLC', style: TextStyle(fontWeight: FontWeight.bold))),
          Expanded(flex: 3, child: Text('Data', style: TextStyle(fontWeight: FontWeight.bold))),
          Expanded(flex: 2, child: Text('Time', style: TextStyle(fontWeight: FontWeight.bold))),
          Expanded(flex: 1, child: Text('Status', style: TextStyle(fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }

  Widget _buildFrameList(CanFrameState state) {
    if (state is CanFrameInitial) {
      return const Center(
        child: Text(
          'Start monitoring to see CAN frames',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final recentFrames = state is CanFrameMonitoring
        ? state.recentFrames
        : state is CanFrameStopped
            ? state.frames.take(50).toList()
            : <CanFrame>[];

    if (recentFrames.isEmpty) {
      return const Center(
        child: Text(
          'No frames received yet',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      itemCount: recentFrames.length,
      itemBuilder: (context, index) {
        final frame = recentFrames[recentFrames.length - 1 - index];
        return _buildFrameListItem(context, frame);
      },
    );
  }

  Widget _buildFrameListItem(BuildContext context, CanFrame frame) {
    final hasErrors = frame.isCorrupted || frame.errors.isNotEmpty;
    
    return InkWell(
      onTap: () => _showFrameDetails(context, frame),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: hasErrors ? Colors.red.shade50 : null,
          border: Border(
            bottom: BorderSide(color: Colors.grey.shade200),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                '0x${frame.id.toRadixString(16).toUpperCase()}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: hasErrors ? Colors.red.shade700 : null,
                ),
              ),
            ),
            Expanded(
              flex: 1,
              child: Text('${frame.dlc}'),
            ),
            Expanded(
              flex: 3,
              child: Text(
                frame.dataHex,
                style: const TextStyle(fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                frame.timeFormatted,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            Expanded(
              flex: 1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: hasErrors ? Colors.red : Colors.green,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  frame.status,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Legacy live-only performance metrics kept for reference; replaced by snapshot aware version.
  // (Can remove if not needed later.)

  Widget _buildSnapshotPerformanceMetrics({
    required bool isLive,
    required double fps,
    required double errorRate,
    required DateTime? lastFrame,
    required int totalFrames,
    required int errorFrames,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isLive ? 'Live Performance Metrics' : 'Snapshot Metrics (Paused)',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _buildMetricItem('Frames', '$totalFrames', Icons.list)),
                Expanded(child: _buildMetricItem('Errors', '$errorFrames', Icons.error)),
                Expanded(child: _buildMetricItem('Err Rate', '${errorRate.toStringAsFixed(2)}%', Icons.percent)),
                Expanded(child: _buildMetricItem(isLive ? 'FPS' : 'FPS (stopped)', isLive ? fps.toStringAsFixed(1) : '0.0', Icons.speed)),
              ],
            ),
            if (lastFrame != null) ...[
              const SizedBox(height: 12),
              Text('Last Frame: ${lastFrame.toIso8601String()}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSnapshotDetailedStatistics(Map<CanErrorType, int> errorStats) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Detailed Statistics', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ...errorStats.entries.where((e) => e.value > 0).map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_getErrorTypeName(e.key)),
                      Text('${e.value}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                )),
            if (errorStats.values.every((v) => v == 0)) const Text('No errors detected', style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildSnapshotBanner(bool isLive) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isLive ? Colors.green.shade50 : Colors.amber.shade50,
        border: Border.all(color: isLive ? Colors.green.shade200 : Colors.amber.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(isLive ? Icons.play_circle_fill : Icons.pause_circle_filled,
              color: isLive ? Colors.green : Colors.amber),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isLive
                  ? 'Live monitoring in progress — analytics updating in real time.'
                  : 'Monitoring paused — showing snapshot analytics at the moment of stop.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  double _calculateStoppedErrorRate(CanFrameStopped? stopped) {
    if (stopped == null || stopped.totalFrames == 0) return 0.0;
    return (stopped.errorFrames / stopped.totalFrames) * 100.0;
  }

  Widget _buildMetricItem(String title, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: Colors.blue, size: 32),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          title,
          style: const TextStyle(
            color: Colors.grey,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  // Legacy detailed statistics removed (replaced by snapshot variant).

  void _showFrameDetails(BuildContext context, CanFrame frame) {
    final errors = frame.errors.whereType<CanErrorInfo>().toList();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Frame Details - ID: 0x${frame.id.toRadixString(16).toUpperCase()}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('DLC: ${frame.dlc}'),
              Text('Data: ${frame.dataHex}'),
              Text('CRC: 0x${frame.crc.toRadixString(16).toUpperCase()}'),
              Text('Timestamp: ${frame.timeFormatted}'),
              const SizedBox(height: 16),
              const Text('Detected Errors:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              
              if (errors.isEmpty)
                const Text('No errors detected', style: TextStyle(color: Colors.green))
              else
                ...errors.map((error) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _getErrorTypeName(error.type),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        error.description,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showSettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Settings'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Settings panel coming soon...'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _getErrorTypeName(CanErrorType type) {
    switch (type) {
      case CanErrorType.crcError:
        return 'CRC Errors';
      case CanErrorType.formatError:
        return 'Format Errors';
      case CanErrorType.stuffingError:
        return 'Bit Stuffing Errors';
      case CanErrorType.ackError:
        return 'ACK Errors';
      case CanErrorType.overloadError:
        return 'Overload Errors';
      case CanErrorType.formError:
        return 'Form Errors';
      default:
        return 'Unknown Errors';
    }
  }

  // Legacy runtime formatter unused after snapshot redesign.
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;

  const _StatCard({
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
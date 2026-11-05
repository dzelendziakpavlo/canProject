import 'package:flutter/material.dart';
import 'package:graphview/GraphView.dart';
import '../../domain/models/can_frame.dart';

/// Layout types for network topology
enum LayoutType { hierarchical, circular, force }

/// CAN Bus Network Topology Visualization
class CanNetworkTopologyView extends StatefulWidget {
  final List<CanFrame> frames;
  final bool isRunning;

  const CanNetworkTopologyView({
    super.key,
    required this.frames,
    required this.isRunning,
  });

  @override
  State<CanNetworkTopologyView> createState() => _CanNetworkTopologyViewState();
}

class _CanNetworkTopologyViewState extends State<CanNetworkTopologyView> {
  late Graph graph;
  late BuchheimWalkerConfiguration builder;
  late SugiyamaConfiguration sugiyamaBuilder;

  // Track active CAN IDs (recently seen)
  final Set<int> _activeNodes = {};
  // Map predefined ECU keys to well-known CAN IDs
  final Map<String, int> _ecuMap = const {
    'ENGINE_ECU': 0x7E8,
    'TRANS_ECU': 0x7E9,
    'ABS_ECU': 0x7EA,
    'AIRBAG_ECU': 0x7EB,
    'BCM_ECU': 0x7EC,
    'CLUSTER_ECU': 0x7ED,
  };

  LayoutType _currentLayout = LayoutType.hierarchical;
  bool _rebuildScheduled = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _initializeGraph();
    _computeActiveNodes();
    _scheduleGraphRebuild();
  }

  @override
  void didUpdateWidget(CanNetworkTopologyView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.frames != oldWidget.frames) {
      _computeActiveNodes();
      _scheduleGraphRebuild();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _initializeGraph() {
    graph = Graph();
    
    // Configure hierarchical layout
    builder = BuchheimWalkerConfiguration()
      ..siblingSeparation = 80
      ..levelSeparation = 80
      ..subtreeSeparation = 80
      ..orientation = BuchheimWalkerConfiguration.ORIENTATION_TOP_BOTTOM;

    // Configure Sugiyama layout
    sugiyamaBuilder = SugiyamaConfiguration()
      ..levelSeparation = 80
      ..nodeSeparation = 80
      ..orientation = SugiyamaConfiguration.ORIENTATION_LEFT_RIGHT;
  }

  void _computeActiveNodes() {
    _activeNodes.clear();
    // Consider recent frames only to avoid bloat
    final recentFrames = widget.frames.length > 50
        ? widget.frames.sublist(widget.frames.length - 50)
        : widget.frames;
    for (final f in recentFrames) {
      _activeNodes.add(f.id);
    }
  }

  void _scheduleGraphRebuild() {
    if (_rebuildScheduled || _disposed) return;
    _rebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _rebuildScheduled = false;
      _rebuildGraph();
    });
  }

  void _rebuildGraph() {
    // Build a fresh graph to avoid mutating during layout and duplicate keys
    final newGraph = Graph();
    final bus = Node.Id('CAN_BUS');
    newGraph.addNode(bus);

    // Static ECU nodes connected to bus
    for (final entry in _ecuMap.entries) {
      final ecuNode = Node.Id(entry.key);
      newGraph.addNode(ecuNode);
      newGraph.addEdge(bus, ecuNode);
    }

    // Dynamic nodes for active CAN IDs not mapped to predefined ECUs
    for (final canId in _activeNodes) {
      if (_ecuMap.values.contains(canId)) continue;
      final key = 'NODE_${canId.toRadixString(16).toUpperCase()}';
      final node = Node.Id(key);
      newGraph.addNode(node);
      newGraph.addEdge(bus, node);
    }

    if (!mounted || _disposed) return;
    setState(() {
      graph = newGraph;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildHeader(context),
          const Divider(height: 1),
          Expanded(
            child: _buildNetworkGraph(context),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    Widget title = Text(
      'CAN Bus Network Topology',
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      overflow: TextOverflow.ellipsis,
    );
    Widget trailing = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 6,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: widget.isRunning ? Colors.green : Colors.red,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${_activeNodes.length} Active Nodes',
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        _buildLayoutSelector(),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 420) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: 12),
                trailing,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 16),
              Flexible(child: trailing),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLayoutSelector() {
    return PopupMenuButton<LayoutType>(
      icon: const Icon(Icons.settings, size: 20),
      onSelected: (LayoutType layout) {
        setState(() {
          _currentLayout = layout;
        });
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: LayoutType.hierarchical,
          child: Text('Hierarchical Layout'),
        ),
        const PopupMenuItem(
          value: LayoutType.circular,
          child: Text('Circular Layout'),
        ),
        const PopupMenuItem(
          value: LayoutType.force,
          child: Text('Force Layout'),
        ),
      ],
    );
  }

  Widget _buildNetworkGraph(BuildContext context) {
    if (graph.nodes.isEmpty) {
      return const Center(
        child: Text(
          'No network topology available',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return InteractiveViewer(
      constrained: false,
      boundaryMargin: const EdgeInsets.all(100),
      minScale: 0.1,
      maxScale: 2.0,
      child: GraphView(
        graph: graph,
        algorithm: _getLayoutAlgorithm(),
        paint: Paint()
          ..color = Colors.blue
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
        builder: (Node node) {
          return _buildNodeWidget(node);
        },
      ),
    );
  }

  Algorithm _getLayoutAlgorithm() {
    switch (_currentLayout) {
      case LayoutType.hierarchical:
        return BuchheimWalkerAlgorithm(builder, TreeEdgeRenderer(builder));
      case LayoutType.circular:
        return FruchtermanReingoldAlgorithm(FruchtermanReingoldConfiguration());
      case LayoutType.force:
        return SugiyamaAlgorithm(sugiyamaBuilder);
    }
  }

  Widget _buildNodeWidget(Node node) {
    final nodeId = node.key?.value as String;
    final isMainBus = nodeId == 'CAN_BUS';
    final isActive = _isNodeActive(nodeId);
    
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _getNodeColor(nodeId, isActive),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isMainBus ? Colors.blue : Colors.grey,
          width: isMainBus ? 3 : 1,
        ),
        boxShadow: [
          if (isActive)
            BoxShadow(
              color: Colors.green.withOpacity(0.5),
              blurRadius: 8,
              spreadRadius: 2,
            ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _getNodeIcon(nodeId),
            color: Colors.white,
            size: isMainBus ? 24 : 16,
          ),
          const SizedBox(height: 4),
          Text(
            _getNodeDisplayName(nodeId),
            style: TextStyle(
              color: Colors.white,
              fontSize: isMainBus ? 12 : 10,
              fontWeight: isMainBus ? FontWeight.bold : FontWeight.normal,
            ),
            textAlign: TextAlign.center,
          ),
          if (isActive && !isMainBus) ...[
            const SizedBox(height: 2),
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _getNodeColor(String nodeId, bool isActive) {
    if (nodeId == 'CAN_BUS') return Colors.blue;
    if (isActive) return Colors.green.shade700;
    return Colors.grey.shade600;
  }

  IconData _getNodeIcon(String nodeId) {
    if (nodeId == 'CAN_BUS') return Icons.hub;
    if (nodeId.contains('ENGINE')) return Icons.settings;
    if (nodeId.contains('TRANS')) return Icons.settings;
    if (nodeId.contains('ABS')) return Icons.car_repair;
    if (nodeId.contains('AIRBAG')) return Icons.security;
    if (nodeId.contains('BCM')) return Icons.electrical_services;
    if (nodeId.contains('CLUSTER')) return Icons.dashboard;
    return Icons.memory;
  }

  String _getNodeDisplayName(String nodeId) {
    if (nodeId == 'CAN_BUS') return 'CAN Bus';
    if (nodeId.contains('ENGINE')) return 'Engine\\nECU';
    if (nodeId.contains('TRANS')) return 'Trans\\nECU';
    if (nodeId.contains('ABS')) return 'ABS\\nECU';
    if (nodeId.contains('AIRBAG')) return 'Airbag\\nECU';
    if (nodeId.contains('BCM')) return 'Body\\nControl';
    if (nodeId.contains('CLUSTER')) return 'Cluster\\nECU';
    
    // For dynamic nodes
    final parts = nodeId.split('_');
    if (parts.length > 1) {
      return 'ID\\n0x${parts[1]}';
    }
    
    return nodeId;
  }

  bool _isNodeActive(String nodeId) {
    if (nodeId == 'CAN_BUS') return widget.isRunning;
    // Dynamic nodes pattern: NODE_XXXXXXXX
    final parts = nodeId.split('_');
    if (parts.length > 1) {
      try {
        final canId = int.parse(parts[1], radix: 16);
        return _activeNodes.contains(canId);
      } catch (_) {}
    }
    // Predefined ECU active if its mapped CAN ID is active
    if (_ecuMap.containsKey(nodeId)) {
      final canId = _ecuMap[nodeId];
      return canId != null && _activeNodes.contains(canId);
    }
    return false;
  }
}
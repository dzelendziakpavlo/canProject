import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../domain/models/can_frame.dart';
import '../../domain/simulator/can_frame_simulator.dart';
import '../../domain/detection/can_error_checker.dart';
import '../../domain/services/can_session_service.dart';
import '../../core/theme.dart';
import '../widgets/animated_widgets.dart';

/// Monitor screen that displays live CAN frame data
class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  late CanFrameSimulator _simulator;
  late StreamSubscription<CanFrame> _subscription;
  final CanErrorChecker _errorChecker = CanErrorChecker();
  final CanSessionService _sessionService = CanSessionService.instance;
  
  final List<CanFrame> _frames = [];
  final int _maxFramesToShow = 100; // Limit displayed frames for performance
  
  int _totalFrames = 0;
  int _errorFrames = 0;
  
  // Detailed error statistics
  final Map<CanErrorType, int> _errorStats = {
    for (var type in CanErrorType.values) type: 0
  };
  
  // Error rate history for live chart
  final List<double> _errorRateHistory = [];
  final int _maxHistoryPoints = 50; // Keep last 50 data points
  
  bool _isRunning = false;
  
  @override
  void initState() {
    super.initState();
    _simulator = CanFrameSimulator();
    _setupFrameListener();
    _startSimulation();
  }

  @override
  void dispose() {
    _subscription.cancel();
    _simulator.dispose();
    super.dispose();
  }

  /// Setup listener for incoming CAN frames
  void _setupFrameListener() {
    _subscription = _simulator.frameStream.listen((frame) {
      setState(() {
        _totalFrames++;
        
        // Use stored errors from frame instead of re-analyzing
        final storedErrors = _getStoredErrors(frame);
        bool hasAnyError = frame.isCorrupted || storedErrors.isNotEmpty;
        
        if (hasAnyError) {
          _errorFrames++;
        }
        
        // Update error statistics
        if (frame.isCorrupted) {
          _errorStats[CanErrorType.crcError] = (_errorStats[CanErrorType.crcError] ?? 0) + 1;
        }
        
        // Count additional error types from stored errors
        for (final error in storedErrors) {
          _errorStats[error.type] = (_errorStats[error.type] ?? 0) + 1;
        }
        
        // Add frame to the beginning of the list
        _frames.insert(0, frame);
        
        // Keep only the most recent frames
        if (_frames.length > _maxFramesToShow) {
          _frames.removeRange(_maxFramesToShow, _frames.length);
        }
        
        // Update error rate history for chart
        if (_totalFrames > 0) {
          final currentErrorRate = (_errorFrames / _totalFrames) * 100;
          _errorRateHistory.add(currentErrorRate);
          
          // Keep only recent history points
          if (_errorRateHistory.length > _maxHistoryPoints) {
            _errorRateHistory.removeAt(0);
          }
        }
        
        // Update current session periodically (every 10 frames)
        if (_totalFrames % 10 == 0) {
          _sessionService.updateCurrentSession(
            frames: _frames,
            errorStats: _errorStats,
            totalFrames: _totalFrames,
            errorFrames: _errorFrames,
            errorRate: _errorRate,
          );
        }
      });
    });
  }

  /// Start the CAN frame simulation
  void _startSimulation() async {
    setState(() {
      _isRunning = true;
    });
    
    // Create new session
    await _sessionService.createSession();
    _simulator.start();
  }

  /// Stop the CAN frame simulation
  void _stopSimulation() async {
    setState(() {
      _isRunning = false;
    });
    _simulator.stop();
    
    // Save current session
    _sessionService.updateCurrentSession(
      frames: _frames,
      errorStats: _errorStats,
      totalFrames: _totalFrames,
      errorFrames: _errorFrames,
      errorRate: _errorRate,
    );
    await _sessionService.completeCurrentSession();
  }

  /// Reset all counters and clear frames
  void _resetSimulation() async {
    _simulator.reset();
    
    // Save current session if it exists
    if (_isRunning) {
      _sessionService.updateCurrentSession(
        frames: _frames,
        errorStats: _errorStats,
        totalFrames: _totalFrames,
        errorFrames: _errorFrames,
        errorRate: _errorRate,
      );
      await _sessionService.completeCurrentSession();
    }
    
    setState(() {
      _frames.clear();
      _totalFrames = 0;
      _errorFrames = 0;
      _isRunning = false;
      
      // Reset error statistics
      for (var type in CanErrorType.values) {
        _errorStats[type] = 0;
      }
      
      // Clear error rate history
      _errorRateHistory.clear();
    });
  }

  /// Get error rate as percentage
  double get _errorRate {
    return _totalFrames > 0 ? (_errorFrames / _totalFrames) * 100 : 0.0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBackground,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.monitor,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            const Text('CAN Monitor'),
          ],
        ),
        backgroundColor: AppTheme.darkSurface,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        actions: [
          AnimatedIconButton(
            icon: _isRunning ? Icons.pause_circle_filled : Icons.play_circle_filled,
            onPressed: _isRunning ? _stopSimulation : _startSimulation,
            tooltip: _isRunning ? 'Pause' : 'Start',
            color: _isRunning ? AppTheme.primaryAmber : AppTheme.accentGreen,
          ).animate().scale(duration: 200.ms),
          AnimatedIconButton(
            icon: Icons.analytics,
            onPressed: _showDetailedErrorStats,
            tooltip: 'Error Statistics',
            color: AppTheme.primaryOrange,
          ).animate(delay: 100.ms).scale(duration: 200.ms),
          AnimatedIconButton(
            icon: Icons.refresh,
            onPressed: _resetSimulation,
            tooltip: 'Reset',
            color: AppTheme.primaryAmber,
          ).animate(delay: 200.ms).scale(duration: 200.ms),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Statistics Panel
          _buildStatisticsPanel(),
          
          // Frame List Header
          _buildFrameListHeader(),
          
          // Frame List
          Expanded(
            flex: 2,
            child: _buildFrameList(),
          ),
          
          // Live Error Rate Chart
          Container(
            height: 140,
            margin: const EdgeInsets.all(16.0),
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              gradient: AppTheme.backgroundGradient,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.primaryAmber.withOpacity(0.3)),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryAmber.withOpacity(0.1),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: _buildErrorRateChart(),
          ).animate(delay: 1200.ms).fadeIn().slideY(begin: 0.3, end: 0),
        ],
      ),
    );
  }

  /// Build the statistics panel at the top
  Widget _buildStatisticsPanel() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        gradient: AppTheme.backgroundGradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryOrange.withOpacity(0.1),
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildStatCard(
                'Total Frames',
                _totalFrames.toString(),
                Icons.analytics,
                AppTheme.primaryAmber,
              ).animate(delay: 100.ms).fadeIn().scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                'Error Frames',
                _errorFrames.toString(),
                Icons.error_outline,
                AppTheme.accentRed,
              ).animate(delay: 200.ms).fadeIn().scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                'Error Rate',
                '${_errorRate.toStringAsFixed(1)}%',
                Icons.warning_amber,
                _errorRate > 15 ? AppTheme.accentRed : AppTheme.primaryOrange,
              ).animate(delay: 300.ms).fadeIn().scale(begin: const Offset(0.8, 0.8)),
              const SizedBox(width: 8),
              _buildStatCard(
                'Status',
                _isRunning ? 'Running' : 'Stopped',
                _isRunning ? Icons.play_circle_filled : Icons.pause_circle_filled,
                _isRunning ? AppTheme.accentGreen : AppTheme.textMuted,
              ).animate(delay: 400.ms).fadeIn().scale(begin: const Offset(0.8, 0.8)),
            ],
          ),
        ),
      ),
    );
  }

  /// Build individual statistic card
  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      width: 85, // Fixed width to prevent overflow
      child: AnimatedCard(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
                border: Border.all(color: color.withOpacity(0.3)),
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color,
              ),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                fontSize: 9,
                color: AppTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// Build the frame list header
  Widget _buildFrameListHeader() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.darkContainer, AppTheme.darkSurface],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
        border: Border.all(color: AppTheme.primaryOrange.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              'ID',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.primaryOrange,
              ),
            ),
          ),
          SizedBox(
            width: 25,
            child: Text(
              'DLC',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.primaryAmber,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Data',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          SizedBox(
            width: 35,
            child: Text(
              'CRC',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.primaryAmber,
              ),
            ),
          ),
          SizedBox(
            width: 50,
            child: Text(
              'Time',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              'Status',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 10,
                color: AppTheme.accentGreen,
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 500.ms).slideY(begin: -0.3, end: 0);
  }

  /// Build the scrollable frame list
  Widget _buildFrameList() {
    if (_frames.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16.0),
        decoration: BoxDecoration(
          color: AppTheme.darkSurface,
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
          border: Border.all(color: AppTheme.primaryOrange.withOpacity(0.3)),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: AppTheme.primaryGradient,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isRunning ? Icons.wifi_find : Icons.wifi_off,
                    size: 40,
                    color: AppTheme.textPrimary,
                  ),
                ).animate(delay: 600.ms).scale(duration: 600.ms, curve: Curves.elasticOut),
                const SizedBox(height: 24),
                Text(
                  _isRunning ? 'Waiting for CAN frames...' : 'Simulation stopped',
                  style: const TextStyle(
                    fontSize: 16,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ).animate(delay: 800.ms).fadeIn().slideY(begin: 0.3, end: 0),
                if (!_isRunning) ...[
                  const SizedBox(height: 24),
                  AnimatedButton(
                    onPressed: _startSimulation,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_arrow),
                        SizedBox(width: 8),
                        Text('Start Simulation'),
                      ],
                    ),
                  ).animate(delay: 1000.ms).fadeIn().scale(begin: const Offset(0.8, 0.8)),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0),
      decoration: BoxDecoration(
        color: AppTheme.darkSurface,
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
        border: Border.all(color: AppTheme.primaryOrange.withOpacity(0.3)),
      ),
      child: ListView.builder(
        itemCount: _frames.length,
        itemBuilder: (context, index) {
          final frame = _frames[index];
          return _buildFrameRow(frame, index)
              .animate(delay: (50 * (index % 10)).ms)
              .fadeIn(duration: 300.ms)
              .slideX(begin: index.isEven ? -0.1 : 0.1, duration: 300.ms);
        },
      ),
    );
  }

  /// Get stored errors from frame
  List<CanErrorInfo> _getStoredErrors(CanFrame frame) {
    try {
      return frame.errors.cast<CanErrorInfo>();
    } catch (e) {
      // If casting fails, return empty list
      return <CanErrorInfo>[];
    }
  }

  /// Build individual frame row
  Widget _buildFrameRow(CanFrame frame, int index) {
    final errors = _getStoredErrors(frame);
    final hasAnyError = frame.isCorrupted || errors.isNotEmpty;
    final backgroundColor = hasAnyError 
        ? AppTheme.accentRed.withOpacity(0.1)
        : (index % 2 == 0 ? AppTheme.darkContainer.withOpacity(0.3) : Colors.transparent);
    
    final textColor = hasAnyError ? AppTheme.accentRed : AppTheme.textPrimary;

    return InkWell(
      onTap: hasAnyError ? () => _showFrameErrorDetails(frame, errors) : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(8),
          border: hasAnyError 
              ? Border.all(color: AppTheme.accentRed.withOpacity(0.5), width: 1)
              : Border.all(color: AppTheme.darkBorder.withOpacity(0.3), width: 0.5),
        ),
        child: Row(
        children: [
          // ID
          SizedBox(
            width: 50,
            child: Text(
              '0x${frame.id.toRadixString(16).toUpperCase().padLeft(3, '0')}',
              style: TextStyle(
                fontFamily: 'monospace',
                color: textColor,
                fontSize: 10,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          
          // DLC
          SizedBox(
            width: 25,
            child: Text(
              frame.dlc.toString(),
              style: TextStyle(
                fontFamily: 'monospace',
                color: textColor,
                fontSize: 10,
              ),
            ),
          ),
          
          // Data
          Expanded(
            flex: 2,
            child: Text(
              frame.dataHex.isEmpty ? '-' : frame.dataHex,
              style: TextStyle(
                fontFamily: 'monospace',
                color: textColor,
                fontSize: 8,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          
          // CRC
          SizedBox(
            width: 35,
            child: Text(
              '0x${frame.crc.toRadixString(16).toUpperCase().padLeft(2, '0')}',
              style: TextStyle(
                fontFamily: 'monospace',
                color: textColor,
                fontSize: 10,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          
          // Time
          SizedBox(
            width: 50,
            child: Text(
              frame.timeFormatted.substring(6), // Show only seconds.milliseconds
              style: TextStyle(
                fontFamily: 'monospace',
                color: textColor,
                fontSize: 8,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          
          // Status
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: hasAnyError ? AppTheme.accentRed : AppTheme.accentGreen,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (hasAnyError ? AppTheme.accentRed : AppTheme.accentGreen).withOpacity(0.5),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasAnyError ? 'ERROR' : 'OK',
                    style: TextStyle(
                      color: hasAnyError ? AppTheme.accentRed : AppTheme.accentGreen,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  /// Show frame error details dialog
  void _showFrameErrorDetails(CanFrame frame, List<CanErrorInfo> errors) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppTheme.darkSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppTheme.primaryOrange.withOpacity(0.3)),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.error_outline,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  'Frame 0x${frame.id.toRadixString(16).toUpperCase()} Errors',
                  style: const TextStyle(color: AppTheme.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.darkContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.primaryAmber.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Frame ID: 0x${frame.id.toRadixString(16).toUpperCase()}', style: const TextStyle(color: AppTheme.textPrimary)),
                    Text('DLC: ${frame.dlc}', style: const TextStyle(color: AppTheme.textSecondary)),
                    Text('Data: ${frame.dataHex}', style: const TextStyle(color: AppTheme.textSecondary)),
                    Text('Timestamp: ${frame.timeFormatted}', style: const TextStyle(color: AppTheme.textMuted)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('Detected Errors:', style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryOrange)),
              const SizedBox(height: 8),
              
              // Show all detected errors with proper names
              ...errors.map((error) => _buildErrorDetailRow(
                _getErrorTypeName(error.type),
                error.description,
                _getSeverityColor(error.severity),
              )),
            ],
          ),
          actions: [
            AnimatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  /// Build error detail row
  Widget _buildErrorDetailRow(String type, String description, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  type,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                Text(
                  description,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Show detailed error statistics dialog
  void _showDetailedErrorStats() {
    final recommendations = _errorChecker.getRecommendations(_errorStats, _totalFrames);
    final criticalRate = _errorChecker.isCriticalErrorRate(_errorStats, _totalFrames);
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppTheme.darkSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppTheme.primaryOrange.withOpacity(0.3)),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: criticalRate ? 
                    const LinearGradient(colors: [AppTheme.accentRed, Color(0xFFD32F2F)]) :
                    AppTheme.primaryGradient,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  criticalRate ? Icons.warning : Icons.analytics,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Error Statistics',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Overall statistics
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: criticalRate ? 
                      LinearGradient(colors: [AppTheme.accentRed.withOpacity(0.1), AppTheme.accentRed.withOpacity(0.05)]) :
                      LinearGradient(colors: [AppTheme.primaryOrange.withOpacity(0.1), AppTheme.primaryAmber.withOpacity(0.05)]),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: criticalRate ? AppTheme.accentRed.withOpacity(0.3) : AppTheme.primaryOrange.withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'Overall Status: ${criticalRate ? "CRITICAL" : "NORMAL"}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: criticalRate ? AppTheme.accentRed : AppTheme.primaryOrange,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('Total Frames: $_totalFrames', style: const TextStyle(color: AppTheme.textPrimary)),
                      Text('Total Errors: $_errorFrames', style: const TextStyle(color: AppTheme.textSecondary)),
                      Text('Error Rate: ${_errorRate.toStringAsFixed(1)}%', style: const TextStyle(color: AppTheme.textSecondary)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                // Error breakdown
                const Text(
                  'Error Breakdown:',
                  style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryAmber),
                ),
                const SizedBox(height: 8),
                
                ...CanErrorType.values
                    .where((type) => type != CanErrorType.none && (_errorStats[type] ?? 0) > 0)
                    .map((type) => _buildErrorStatRow(type, _errorStats[type] ?? 0))
                    .toList(),
                
                if (recommendations.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Recommendations:',
                    style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.accentGreen),
                  ),
                  const SizedBox(height: 8),
                  ...recommendations.map((rec) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.lightbulb, size: 16, color: Colors.orange),
                        const SizedBox(width: 8),
                        Expanded(child: Text(rec, style: const TextStyle(fontSize: 12))),
                      ],
                    ),
                  )),
                ],
              ],
            ),
          ),
          actions: [
            AnimatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  /// Build error statistic row
  Widget _buildErrorStatRow(CanErrorType type, int count) {
    final rate = _totalFrames > 0 ? (count / _totalFrames * 100) : 0.0;
    final severity = _getErrorSeverity(type);
    final color = _getSeverityColor(severity);
    
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _getErrorTypeName(type),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Text(
            '$count (${rate.toStringAsFixed(1)}%)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// Get error type display name
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
      case CanErrorType.activeError:
        return 'Active Error Flags';
      case CanErrorType.passiveError:
        return 'Passive Error Flags';
      case CanErrorType.busOffError:
        return 'Bus-Off Errors';
      default:
        return type.toString().split('.').last;
    }
  }

  /// Get error severity level
  int _getErrorSeverity(CanErrorType type) {
    switch (type) {
      case CanErrorType.crcError:
        return 3;
      case CanErrorType.ackError:
      case CanErrorType.overloadError:
      case CanErrorType.busOffError:
        return 4;
      case CanErrorType.formatError:
      case CanErrorType.formError:
      case CanErrorType.stuffingError:
        return 2;
      case CanErrorType.activeError:
      case CanErrorType.passiveError:
        return 3;
      default:
        return 1;
    }
  }

  /// Get color based on severity
  Color _getSeverityColor(int severity) {
    switch (severity) {
      case 1:
        return Colors.green;
      case 2:
        return Colors.orange;
      case 3:
        return Colors.red;
      case 4:
      case 5:
        return Colors.red.shade800;
      default:
        return Colors.grey;
    }
  }

  /// Build live error rate chart
  Widget _buildErrorRateChart() {
    if (_errorRateHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.trending_up,
              color: AppTheme.primaryAmber,
              size: 32,
            ),
            const SizedBox(height: 8),
            const Text(
              'Error Rate Chart',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Text(
              'Waiting for data...',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.trending_up, size: 16, color: Colors.white),
            ),
            const SizedBox(width: 12),
            const Text(
              'Live Error Rate (%)',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
                fontSize: 14,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (_errorRate > 15 ? AppTheme.accentRed : AppTheme.accentGreen).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _errorRate > 15 ? AppTheme.accentRed : AppTheme.accentGreen,
                  width: 1,
                ),
              ),
              child: Text(
                'Current: ${_errorRate.toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 11,
                  color: _errorRate > 15 ? AppTheme.accentRed : AppTheme.accentGreen,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: CustomPaint(
              painter: ErrorRateChartPainter(
                data: _errorRateHistory,
                maxValue: 100.0,
              ),
              child: Container(),
            ),
          ),
        ),
      ],
    );
  }
}

/// Custom painter for error rate chart
class ErrorRateChartPainter extends CustomPainter {
  final List<double> data;
  final double maxValue;

  ErrorRateChartPainter({
    required this.data,
    required this.maxValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..style = PaintingStyle.fill;

    // Draw grid lines
    _drawGrid(canvas, size);

    // Calculate points
    final points = <Offset>[];
    for (int i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - (data[i] / maxValue) * size.height;
      points.add(Offset(x, y));
    }

    // Draw area under curve (gradient fill)
    if (points.length > 1) {
      final path = Path();
      path.moveTo(points.first.dx, size.height);
      path.lineTo(points.first.dx, points.first.dy);
      
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      
      path.lineTo(points.last.dx, size.height);
      path.close();

      // Gradient fill
      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          _getColorForValue(data.last).withOpacity(0.3),
          _getColorForValue(data.last).withOpacity(0.1),
        ],
      );

      fillPaint.shader = gradient.createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      canvas.drawPath(path, fillPaint);
    }

    // Draw line
    if (points.length > 1) {
      paint.color = _getColorForValue(data.last);
      final path = Path();
      path.moveTo(points.first.dx, points.first.dy);
      
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      
      canvas.drawPath(path, paint);
    }

    // Draw points
    for (int i = 0; i < points.length; i++) {
      final pointPaint = Paint()
        ..color = _getColorForValue(data[i])
        ..style = PaintingStyle.fill;
      
      canvas.drawCircle(points[i], 2.0, pointPaint);
    }

    // Draw current value indicator
    if (points.isNotEmpty) {
      final lastPoint = points.last;
      final indicatorPaint = Paint()
        ..color = _getColorForValue(data.last)
        ..style = PaintingStyle.fill;
      
      canvas.drawCircle(lastPoint, 4.0, indicatorPaint);
      
      // Draw value text
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${data.last.toStringAsFixed(1)}%',
          style: TextStyle(
            color: _getColorForValue(data.last),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      
      textPainter.layout();
      final textOffset = Offset(
        lastPoint.dx - textPainter.width / 2,
        lastPoint.dy - textPainter.height - 8,
      );
      textPainter.paint(canvas, textOffset);
    }
  }

  void _drawGrid(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 0.5;

    // Horizontal grid lines (error rate levels)
    for (int i = 0; i <= 4; i++) {
      final y = (i / 4) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      
      // Draw percentage labels
      final percentage = (1 - i / 4) * maxValue;
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${percentage.toInt()}%',
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 8,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(-25, y - textPainter.height / 2));
    }

    // Vertical grid lines (time intervals)
    for (int i = 0; i <= 4; i++) {
      final x = (i / 4) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
  }

  Color _getColorForValue(double value) {
    if (value > 20) return Colors.red.shade700;
    if (value > 15) return Colors.red;
    if (value > 10) return Colors.orange;
    if (value > 5) return Colors.yellow.shade700;
    return Colors.green;
  }

  @override
  bool shouldRepaint(ErrorRateChartPainter oldDelegate) {
    return oldDelegate.data != data;
  }
}
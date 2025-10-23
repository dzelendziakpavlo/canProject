import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../domain/models/can_session.dart';
import '../../domain/services/can_session_service.dart';
import '../../core/theme.dart';
import '../widgets/animated_widgets.dart';

/// Analytics Extension screen для перегляду збережених сесій та розширеної аналітики
class AnalyticsExtensionScreen extends StatefulWidget {
  const AnalyticsExtensionScreen({super.key});

  @override
  State<AnalyticsExtensionScreen> createState() => _AnalyticsExtensionScreenState();
}

class _AnalyticsExtensionScreenState extends State<AnalyticsExtensionScreen> {
  final CanSessionService _sessionService = CanSessionService.instance;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    await _sessionService.initialize();
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
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
                Icons.analytics,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            const Text('Analytics Extension'),
          ],
        ),
        backgroundColor: AppTheme.darkSurface,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        actions: [
          AnimatedIconButton(
            icon: Icons.delete_sweep,
            onPressed: _showClearAllDialog,
            tooltip: 'Clear All Sessions',
            color: AppTheme.accentRed,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? _buildLoadingState()
          : StreamBuilder<List<CanSession>>(
              stream: _sessionService.sessionsStream,
              initialData: _sessionService.savedSessions,
              builder: (context, snapshot) {
                final sessions = snapshot.data ?? [];
                return _buildMainContent(sessions);
              },
            ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.analytics,
              size: 40,
              color: Colors.white,
            ),
          ).animate().scale(duration: 1.seconds, curve: Curves.elasticOut),
          const SizedBox(height: 24),
          const Text(
            'Loading Analytics...',
            style: TextStyle(
              fontSize: 16,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent(List<CanSession> sessions) {
    if (sessions.isEmpty) {
      return _buildEmptyState();
    }

    return CustomScrollView(
      slivers: [
        // Overall Analytics
        SliverToBoxAdapter(
          child: _buildOverallAnalytics(sessions).animate(delay: 100.ms).fadeIn().slideY(begin: -0.3, end: 0),
        ),
        
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
        
        // Sessions Header
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryAmber.withOpacity(0.1),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.primaryAmber.withOpacity(0.3)),
                  ),
                  child: const Icon(
                    Icons.history,
                    color: AppTheme.primaryAmber,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Saved Sessions (${sessions.length})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const Spacer(),
                if (sessions.isNotEmpty)
                  Text(
                    'Latest: ${sessions.first.startTime.day}/${sessions.first.startTime.month}',
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
              ],
            ).animate(delay: 300.ms).fadeIn().slideX(begin: -0.3, end: 0),
          ),
        ),
        
        // Sessions List
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final session = sessions[index];
              return _buildSessionCard(session, index).animate(delay: (400 + index * 100).ms).fadeIn().slideX(begin: 0.3, end: 0);
            },
            childCount: sessions.length,
          ),
        ),
        
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.analytics_outlined,
                size: 60,
                color: Colors.white,
              ),
            ).animate().scale(duration: 800.ms, curve: Curves.elasticOut),
            const SizedBox(height: 32),
            const Text(
              'No Sessions Yet',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
              ),
            ).animate(delay: 400.ms).fadeIn().slideY(begin: 0.3, end: 0),
            const SizedBox(height: 16),
            const Text(
              'Start monitoring CAN frames to create your first session.\nSessions are automatically saved when you stop the monitor.',
              style: TextStyle(
                fontSize: 16,
                color: AppTheme.textSecondary,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ).animate(delay: 600.ms).fadeIn(),
            const SizedBox(height: 32),
            AnimatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.monitor),
                  SizedBox(width: 8),
                  Text('Go to Monitor'),
                ],
              ),
            ).animate(delay: 800.ms).fadeIn().scale(begin: const Offset(0.8, 0.8)),
          ],
        ),
      ),
    );
  }

  Widget _buildOverallAnalytics(List<CanSession> sessions) {
    final analytics = _sessionService.getOverallAnalytics();
    
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppTheme.backgroundGradient,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primaryOrange.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryOrange.withOpacity(0.1),
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: AppTheme.primaryGradient,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.dashboard,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                const Text(
                  'Overall Analytics',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            // Stats Grid
            Row(
              children: [
                Expanded(
                  child: _buildAnalyticsCard(
                    'Total Sessions',
                    analytics.totalSessions.toString(),
                    Icons.folder_outlined,
                    AppTheme.primaryAmber,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildAnalyticsCard(
                    'Total Frames',
                    _formatNumber(analytics.totalFrames),
                    Icons.data_usage,
                    AppTheme.accentGreen,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildAnalyticsCard(
                    'Avg Error Rate',
                    '${analytics.averageErrorRate.toStringAsFixed(1)}%',
                    Icons.error_outline,
                    analytics.averageErrorRate > 15 ? AppTheme.accentRed : AppTheme.primaryOrange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildAnalyticsCard(
                    'Total Duration',
                    analytics.formattedTotalDuration,
                    Icons.schedule,
                    AppTheme.primaryAmber,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalyticsCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.textSecondary,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildSessionCard(CanSession session, int index) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: AnimatedCard(
        onTap: () => _viewSessionDetails(session),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Session Icon & Number
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  gradient: _getSeverityGradient(session.severity),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    (index + 1).toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              
              const SizedBox(width: 16),
              
              // Session Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${session.formattedDuration} • ${_formatNumber(session.totalFrames)} frames',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatDateTime(session.startTime),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              
              // Status & Error Rate
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _getSeverityColor(session.severity).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _getSeverityColor(session.severity).withOpacity(0.3)),
                    ),
                    child: Text(
                      session.severity.displayName,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: _getSeverityColor(session.severity),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${session.errorRate.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: _getSeverityColor(session.severity),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(width: 8),
              const Icon(
                Icons.arrow_forward_ios,
                color: AppTheme.primaryOrange,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _viewSessionDetails(CanSession session) {
    // TODO: Navigate to detailed session view
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Detailed analytics for ${session.name} coming soon!'),
        backgroundColor: AppTheme.primaryOrange,
      ),
    );
  }

  void _showClearAllDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppTheme.accentRed.withOpacity(0.3)),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.accentRed.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.delete_forever,
                color: AppTheme.accentRed,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              'Clear All Sessions',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
          ],
        ),
        content: const Text(
          'Are you sure you want to delete all saved sessions? This action cannot be undone.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          AnimatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _sessionService.clearAllSessions();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('All sessions cleared'),
                    backgroundColor: AppTheme.accentRed,
                  ),
                );
              }
            },
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }

  LinearGradient _getSeverityGradient(SessionSeverity severity) {
    switch (severity) {
      case SessionSeverity.critical:
        return const LinearGradient(colors: [AppTheme.accentRed, Color(0xFFD32F2F)]);
      case SessionSeverity.high:
        return const LinearGradient(colors: [Color(0xFFFF9800), AppTheme.accentRed]);
      case SessionSeverity.medium:
        return const LinearGradient(colors: [AppTheme.primaryOrange, Color(0xFFFF9800)]);
      case SessionSeverity.low:
        return const LinearGradient(colors: [AppTheme.primaryAmber, AppTheme.primaryOrange]);
      case SessionSeverity.normal:
        return const LinearGradient(colors: [AppTheme.accentGreen, Color(0xFF66BB6A)]);
    }
  }

  Color _getSeverityColor(SessionSeverity severity) {
    switch (severity) {
      case SessionSeverity.critical:
        return AppTheme.accentRed;
      case SessionSeverity.high:
        return AppTheme.accentRed;
      case SessionSeverity.medium:
        return AppTheme.primaryOrange;
      case SessionSeverity.low:
        return AppTheme.primaryAmber;
      case SessionSeverity.normal:
        return AppTheme.accentGreen;
    }
  }

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.day}/${dateTime.month}/${dateTime.year} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}
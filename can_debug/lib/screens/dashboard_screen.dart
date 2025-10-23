import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/theme.dart';
import '../presentation/widgets/animated_widgets.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final String username = (ModalRoute.of(context)?.settings.arguments ?? '') as String;
    final theme = Theme.of(context);
    
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Custom App Bar
              Container(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        gradient: AppTheme.primaryGradient,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.dashboard,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Dashboard',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            'Welcome back, $username',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedIconButton(
                      icon: Icons.logout,
                      onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
                      tooltip: 'Logout',
                    ),
                  ],
                ),
              ).animate().fadeIn().slideY(begin: -0.3, end: 0),
              
              // Main Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      // Welcome Section
                      AnimatedCard(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  gradient: AppTheme.primaryGradient,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.verified_user,
                                  size: 48,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'System Ready',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'All automotive systems are operational',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ).animate().fadeIn(delay: 200.ms),
                      
                      const SizedBox(height: 24),
                      
                      // CAN Monitor Section
                      AnimatedCard(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  gradient: AppTheme.primaryGradient,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.monitor_heart,
                                  size: 40,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'CAN Bus Monitor',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Real-time CAN frame monitoring and analysis',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 24),
                              Row(
                                children: [
                                  Expanded(
                                    child: AnimatedButton(
                                      onPressed: () => Navigator.pushNamed(context, '/monitor'),
                                      child: const Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.monitor),
                                          SizedBox(width: 8),
                                          Text('Classic Monitor'),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: AnimatedButton(
                                      onPressed: () => Navigator.pushNamed(context, '/modern_monitor'),
                                      child: const Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.analytics),
                                          SizedBox(width: 8),
                                          Text('Pro Monitor'),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ).animate().fadeIn(delay: 400.ms).slideX(begin: 0.3, end: 0),
                      
                      const SizedBox(height: 24),
                      
                      // Quick Stats
                      Row(
                        children: [
                          Expanded(
                            child: AnimatedCard(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.speed,
                                      size: 32,
                                      color: theme.colorScheme.primary,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Live Data',
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                        color: theme.colorScheme.onSurface.withOpacity(0.7),
                                      ),
                                    ),
                                    Text(
                                      'Active',
                                      style: theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ).animate().fadeIn(delay: 600.ms).slideY(begin: 0.3, end: 0),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: AnimatedCard(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.network_check,
                                      size: 32,
                                      color: theme.colorScheme.primary,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Network',
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                        color: theme.colorScheme.onSurface.withOpacity(0.7),
                                      ),
                                    ),
                                    Text(
                                      'Online',
                                      style: theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ).animate().fadeIn(delay: 800.ms).slideY(begin: 0.3, end: 0),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

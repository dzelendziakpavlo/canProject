import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../presentation/widgets/animated_widgets.dart';
import '../core/theme.dart';

/// Quick launcher screen для тестування різних функцій додатку
class LauncherScreen extends StatelessWidget {
  const LauncherScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 20),
                
                // App Title з анімацією
                Center(
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: AppTheme.primaryGradient,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primaryOrange.withOpacity(0.3),
                              blurRadius: 20,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: const Icon(
                          AutomotiveIcons.canBus,
                          size: 60,
                          color: AppTheme.textPrimary,
                        ),
                      ).animate()
                        .fadeIn(duration: 600.ms)
                        .scale(begin: const Offset(0.5, 0.5), duration: 600.ms, curve: Curves.elasticOut),
                      
                      const SizedBox(height: 24),
                      
                      Text(
                        'CAN Debug Pro',
                        style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          foreground: Paint()
                            ..shader = AppTheme.primaryGradient.createShader(
                              const Rect.fromLTWH(0, 0, 200, 70),
                            ),
                        ),
                      ).animate()
                        .fadeIn(delay: 300.ms, duration: 600.ms)
                        .slideY(begin: 0.3, duration: 600.ms, curve: Curves.easeOutBack),
                      
                      const SizedBox(height: 8),
                      
                      Text(
                        'Professional Automotive CAN Bus Monitor',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ).animate()
                        .fadeIn(delay: 600.ms, duration: 600.ms)
                        .slideY(begin: 0.3, duration: 600.ms),
                    ],
                  ),
                ),
                
                const SizedBox(height: 60),
                
                // Monitor Options
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        // Analytics Extension Card
                      AnimatedCard(
                        onTap: () => Navigator.pushNamed(context, '/analytics'),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                gradient: AppTheme.primaryGradient,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.analytics,
                                color: AppTheme.textPrimary,
                                size: 32,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Analytics Extension',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.primaryOrange,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'View saved monitoring sessions with advanced analytics, statistics and performance insights',
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.arrow_forward_ios,
                              color: AppTheme.primaryOrange,
                              size: 20,
                            ),
                          ],
                        ),
                      ).animate(delay: 900.ms)
                        .fadeIn(duration: 400.ms)
                        .slideX(begin: 0.3, duration: 400.ms),
                      
                      const SizedBox(height: 20),
                      
                      // Classic Monitor Card
                      AnimatedCard(
                        onTap: () => Navigator.pushNamed(context, '/monitor'),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: AppTheme.darkContainer,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: AppTheme.primaryAmber.withOpacity(0.3),
                                ),
                              ),
                              child: const Icon(
                                AutomotiveIcons.liveMonitor,
                                color: AppTheme.primaryAmber,
                                size: 32,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Classic Monitor',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.primaryAmber,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Traditional CAN frame monitor with custom painting and basic error detection',
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.arrow_forward_ios,
                              color: AppTheme.primaryAmber,
                              size: 20,
                            ),
                          ],
                        ),
                      ).animate(delay: 1100.ms)
                        .fadeIn(duration: 400.ms)
                        .slideX(begin: 0.3, duration: 400.ms),
                      
                      const SizedBox(height: 20),
                      
                      // Auth Flow Card
                      AnimatedCard(
                        onTap: () => Navigator.pushNamed(context, '/login'),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: AppTheme.darkContainer,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: AppTheme.accentGreen.withOpacity(0.3),
                                ),
                              ),
                              child: const Icon(
                                Icons.login,
                                color: AppTheme.accentGreen,
                                size: 32,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Authentication System',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.accentGreen,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Login/Register system with user dashboard and access control',
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.arrow_forward_ios,
                              color: AppTheme.accentGreen,
                              size: 20,
                            ),
                          ],
                        ),
                      ).animate(delay: 1300.ms)
                        .fadeIn(duration: 400.ms)
                        .slideX(begin: 0.3, duration: 400.ms),
                        const SizedBox(height: 20),
                        
                        // Footer
                        Center(
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.school,
                                    color: AppTheme.textMuted,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Term Paper Project',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppTheme.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Advanced Automotive CAN Bus Debugging System',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ).animate(delay: 1500.ms)
                          .fadeIn(duration: 600.ms),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
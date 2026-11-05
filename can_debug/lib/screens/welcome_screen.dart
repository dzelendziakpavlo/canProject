import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/theme.dart';
import '../presentation/widgets/animated_widgets.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        gradient: AppTheme.primaryGradient,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primaryOrange.withOpacity(0.3),
                            blurRadius: 24,
                            spreadRadius: 6,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.car_repair,
                        color: Colors.white,
                        size: 56,
                      ),
                    ).animate().fadeIn(duration: 600.ms).scale(begin: const Offset(0.6, 0.6), curve: Curves.elasticOut),
                    const SizedBox(height: 24),
                    Text(
                      'CAN Debug Pro',
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        foreground: Paint()..shader = AppTheme.primaryGradient.createShader(const Rect.fromLTWH(0, 0, 300, 80)),
                      ),
                      textAlign: TextAlign.center,
                    ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.3, end: 0),
                    const SizedBox(height: 12),
                    Text(
                      'Professional automotive CAN bus monitoring, analytics and diagnostics — fast, visual, and insightful.',
                      style: theme.textTheme.bodyLarge?.copyWith(color: AppTheme.textSecondary, height: 1.4),
                      textAlign: TextAlign.center,
                    ).animate().fadeIn(delay: 400.ms),
                    const SizedBox(height: 36),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: AnimatedButton(
                        onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Next'),
                            SizedBox(width: 8),
                            Icon(Icons.arrow_forward),
                          ],
                        ),
                      ),
                    ).animate().fadeIn(delay: 600.ms),
                    
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

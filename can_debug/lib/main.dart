import 'package:flutter/material.dart';

import 'core/dependency_injection.dart';
import 'core/theme.dart';
import 'domain/services/can_session_service.dart';
import 'screens/dashboard_screen.dart';
import 'screens/launcher_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'presentation/screens/monitor_screen.dart';
import 'presentation/screens/modern_monitor_screen.dart';
import 'presentation/screens/analytics_extension_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize dependencies
  await initializeDependencies();
  
  // Initialize session service
  await CanSessionService.instance.initialize();
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CAN Debug Pro',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      initialRoute: '/',
      routes: {
        '/': (_) => const LauncherScreen(),
        '/login': (_) => const LoginScreen(),
        '/register': (_) => const RegisterScreen(),
        '/dashboard': (_) => const DashboardScreen(),
        '/monitor': (_) => const MonitorScreen(),
        '/modern_monitor': (_) => const ModernMonitorScreen(),
        '/analytics': (_) => const AnalyticsExtensionScreen(),
      },
    );
  }
}

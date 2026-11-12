import 'package:flutter/material.dart';

import 'core/dependency_injection.dart';
import 'core/theme.dart';
import 'core/export_recovery_notice.dart';
import 'domain/services/can_session_service.dart';
import 'domain/services/auth_session_service.dart';
import 'screens/dashboard_screen.dart';
import 'screens/welcome_screen.dart';
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
  // Initialize auth session
  await AuthSessionService.instance.initialize();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  static final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CAN Debug Pro',
      scaffoldMessengerKey: _messengerKey,
      builder: (context, child) =>
          ExportRecoveryNotice(messengerKey: _messengerKey, child: child!),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      // A single root route: Back from Dashboard leaves the app instead of
      // revealing a legacy launcher underneath the authentication flow.
      home: AuthSessionService.instance.isLoggedIn
          ? const DashboardScreen()
          : const WelcomeScreen(),
      routes: {
        '/welcome': (_) => const WelcomeScreen(),
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

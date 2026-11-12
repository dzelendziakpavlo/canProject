import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:can_debug/domain/services/auth_session_service.dart';
import 'package:can_debug/main.dart';
import 'package:can_debug/screens/dashboard_screen.dart';
import 'package:can_debug/screens/login_screen.dart';
import 'package:can_debug/screens/welcome_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var exitRequests = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AuthSessionService.instance.logout();
    exitRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemNavigator.pop') exitRequests++;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'system Back after automatic login requests exit from Dashboard',
    (tester) async {
      await AuthSessionService.instance.saveLogin('navigation-test');
      await tester.pumpWidget(const MyApp());
      await tester.pump(const Duration(seconds: 2));

      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(
        Navigator.of(tester.element(find.byType(DashboardScreen))).canPop(),
        isFalse,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(exitRequests, 1);
      expect(find.byType(WelcomeScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'welcome and login replacements leave no screen behind Dashboard',
    (tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(WelcomeScreen), findsOneWidget);

      Navigator.of(
        tester.element(find.byType(WelcomeScreen)),
      ).pushReplacementNamed('/login');
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(LoginScreen), findsOneWidget);
      await AuthSessionService.instance.saveLogin('navigation-test');
      Navigator.of(
        tester.element(find.byType(LoginScreen)),
      ).pushReplacementNamed('/dashboard', arguments: 'navigation-test');
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(find.byType(DashboardScreen), findsOneWidget);
      expect(
        Navigator.of(tester.element(find.byType(DashboardScreen))).canPop(),
        isFalse,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(exitRequests, 1);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

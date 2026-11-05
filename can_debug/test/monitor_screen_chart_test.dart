import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:can_debug/domain/simulator/can_frame_simulator.dart';
import 'package:can_debug/presentation/screens/monitor_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('shows chart and current monitoring controls', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MonitorScreen()));
    await tester.pump();
    expect(find.text('CAN Monitor'), findsOneWidget);
    expect(find.text('Error Rate Chart'), findsOneWidget);
    expect(find.text('Total Frames'), findsOneWidget);
    expect(find.byIcon(Icons.pause_circle_filled), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byIcon(Icons.analytics), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('renders live error rate after deterministic frame delivery', (
    tester,
  ) async {
    final simulator = CanFrameSimulator();
    await tester.pumpWidget(
      MaterialApp(home: MonitorScreen(source: simulator)),
    );
    await tester.pump();
    simulator.generateCustomFrame(id: 0x100, dlc: 1, data: [1]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Live Error Rate (%)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}

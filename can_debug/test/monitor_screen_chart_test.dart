import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/presentation/screens/monitor_screen.dart';

void main() {
  group('MonitorScreen Live Chart Tests', () {
    testWidgets('should display live error rate chart', (WidgetTester tester) async {
      // Build the MonitorScreen widget
      await tester.pumpWidget(
        MaterialApp(
          home: MonitorScreen(),
        ),
      );

      // Verify the initial state
      expect(find.text('CAN Monitor'), findsOneWidget);
      expect(find.text('Error Rate Chart (waiting for data...)'), findsOneWidget);
      
      // Verify statistics panel exists
      expect(find.text('Total Frames'), findsOneWidget);
      expect(find.text('Error Frames'), findsOneWidget);
      
      // Verify control buttons exist
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byIcon(Icons.bar_chart), findsOneWidget);
    });

    testWidgets('should show live error rate text', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MonitorScreen(),
        ),
      );

      // Start simulation to generate some data
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();
      
      // Wait a bit for frames to be generated
      await tester.pump(Duration(milliseconds: 500));
      
      // The chart should still be there (though may still show waiting message initially)
      expect(find.textContaining('Live Error Rate'), findsOneWidget);
    });
  });
}
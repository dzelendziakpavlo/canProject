import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/core/theme.dart';
import 'package:can_debug/domain/detection/can_error_checker.dart';
import 'package:can_debug/domain/models/can_frame.dart';
import 'package:can_debug/domain/models/can_session.dart';
import 'package:can_debug/domain/models/can_session_event.dart';
import 'package:can_debug/presentation/screens/session_analytics_detail_screen.dart';
import 'package:can_debug/presentation/widgets/session_analytics_widgets.dart';
import 'package:can_debug/domain/services/session_analytics.dart';

void main() {
  final frames = List.generate(
    12,
    (i) => CanFrame.create(
      id: 0x1fffffff,
      dlc: 8,
      data: List.filled(8, i),
      isExtended: true,
      timestamp: DateTime.utc(2026).add(Duration(seconds: i)),
      errors: [
        CanErrorInfo(
          type: CanErrorType.values[1 + i % 6],
          description: 'Synthetic UI control',
          severity: 2,
          origin: CanErrorOrigin.simulated,
        ),
      ],
    ),
  );
  final session = CanSession.create('Synthetic narrow layout control')
      .updateWith(
        sourceName: 'BLE synthetic control',
        frames: frames,
        totalFrames: frames.length,
        events: [
          CanSessionEvent.create(
            type: CanSessionEventType.diagnostic,
            message: 'Long diagnostic message',
            evidence: DiagnosticEvidence.inferred,
          ),
        ],
      )
      .complete();

  for (final width in [320.0, 360.0, 393.0, 600.0, 1280.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'Analytics has no overflow at width $width and text scale $scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.darkTheme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: SessionAnalyticsDetailScreen(session: session),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byType(SingleChildScrollView).first,
            const Offset(0, -1000),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('error details sheet wraps long type names on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showErrorTypeDetailsSheet(
                context,
                session,
                CanErrorType.stuffingError,
                builder: SessionAnalyticsBuilder(),
              ),
              child: const Text('Details'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

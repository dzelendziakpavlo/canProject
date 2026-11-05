import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:can_debug/core/windows_capture_guard.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('can_debug/capture_window');
  test(
    'native close waits for capture flush before allowing WM_CLOSE',
    () async {
      final calls = <String>[];
      final flushed = Completer<void>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      final guard = WindowsCaptureGuard(() => flushed.future);
      await guard.enable();
      final codec = const StandardMethodCodec();
      final response = Completer<void>();
      unawaited(
        binding.defaultBinaryMessenger.handlePlatformMessage(
          'can_debug/capture_window',
          codec.encodeMethodCall(const MethodCall('closeRequested')),
          (_) => response.complete(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['setCaptureActive']);
      flushed.complete();
      await response.future;
      expect(calls, ['setCaptureActive', 'closeWindow']);
      guard.dispose();
      await Future<void>.delayed(Duration.zero);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    },
    skip: !Platform.isWindows,
  );
}

import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// The runner defers WM_CLOSE while a hardware monitor flushes its capture.
class WindowsCaptureGuard {
  WindowsCaptureGuard(this.onClose);
  final Future<void> Function() onClose;
  static const _channel = MethodChannel('can_debug/capture_window');
  static WindowsCaptureGuard? _owner;
  bool _disposed = false, _closing = false;

  Future<void> enable() async {
    if (!Platform.isWindows) return;
    _owner = this;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'closeRequested' || _closing || _disposed) return;
      _closing = true;
      try {
        await onClose();
        await _channel.invokeMethod<void>('closeWindow');
      } finally {
        _closing = false;
      }
    });
    try {
      await _channel.invokeMethod<void>('setCaptureActive', true);
      if (_disposed && _owner == null) {
        await _channel.invokeMethod<void>('setCaptureActive', false);
      }
    } on MissingPluginException {
      // Widget tests / runners predating this desktop-only channel.
    }
  }

  void dispose() {
    _disposed = true;
    if (!Platform.isWindows || _owner != this) return;
    _owner = null;
    _channel.setMethodCallHandler(null);
    unawaited(_deactivate());
  }

  Future<void> _deactivate() async {
    try {
      await _channel.invokeMethod<void>('setCaptureActive', false);
    } on MissingPluginException {
      /* No desktop runner in unit tests. */
    }
  }
}

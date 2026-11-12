import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'session_file_saver.dart';

/// Show a completed/retryable export even when Android recreated the app at
/// Dashboard and the original Analytics screen and Dart Future no longer exist.
class ExportRecoveryNotice extends StatefulWidget {
  const ExportRecoveryNotice({
    super.key,
    required this.messengerKey,
    required this.child,
  });
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final Widget child;
  @override
  State<ExportRecoveryNotice> createState() => _ExportRecoveryNoticeState();
}

class _ExportRecoveryNoticeState extends State<ExportRecoveryNotice>
    with WidgetsBindingObserver {
  Timer? _poll;
  String? _shownPending;
  bool _checking = false;
  @override
  void initState() {
    super.initState();
    if (!Platform.isAndroid) return;
    WidgetsBinding.instance.addObserver(this);
    SessionFileSaver.channel.setMethodCallHandler((call) async {
      if (call.method == 'exportResultAvailable') await _check();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    if (!mounted || _checking || SessionFileSaver.isAndroidExportActive) return;
    _checking = true;
    try {
      final status = await SessionFileSaver.status();
      if (status == null || !mounted) return;
      final state = status['state'];
      if (state == 'writing') {
        _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => _check());
        return;
      }
      _poll?.cancel();
      _poll = null;
      if (state == 'awaiting_destination' || state == 'error') {
        final marker = '${status['id']}:$state';
        if (_shownPending == marker) return;
        _shownPending = marker;
        if (state == 'error') await SessionFileSaver.acknowledge(status);
        _show(
          state == 'error'
              ? status['message'].toString()
              : 'Unfinished export: select a destination to continue.',
          retry: true,
        );
        return;
      }
      await SessionFileSaver.acknowledge(status);
      final description = SessionFileSaver.describe(status);
      if (description != null) _show('Export recovered: $description');
    } on MissingPluginException {
      _show(
        'Export requires a full app restart with the updated Android build.',
      );
    } catch (e) {
      _show('Export recovery failed: $e');
    } finally {
      _checking = false;
    }
  }

  void _show(String message, {bool retry = false}) {
    if (!mounted) return;
    widget.messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 12),
        action: retry
            ? SnackBarAction(
                label: 'Resume',
                onPressed: () async {
                  try {
                    await SessionFileSaver.resume();
                    _shownPending = null;
                    await _check();
                  } catch (e) {
                    _show('Export resume failed: $e');
                  }
                },
              )
            : null,
      ),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (Platform.isAndroid) {
      WidgetsBinding.instance.removeObserver(this);
      SessionFileSaver.channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

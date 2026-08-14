import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'sms_reader.dart';

/// One message captured by the Android broadcast receiver, still waiting to be
/// imported. [id] is the queue row, which is what gets acknowledged once the
/// import has committed.
class QueuedSms {
  final int id;
  final RawSms message;

  const QueuedSms(this.id, this.message);
}

/// Dart half of the native SMS capture queue.
///
/// The receiver writes messages to disk natively; this pulls them across and
/// acknowledges them only after they are safely in the ledger. Nothing here
/// parses or stores transactions — that stays in `TransactionImportService`, so
/// a message captured in the background and one read from the inbox go through
/// exactly the same de-duplication.
class NativeSmsQueue {
  NativeSmsQueue({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel(
                'com.example.family_expense_tracker/sms_queue');

  final MethodChannel _channel;

  final StreamController<int> _captured = StreamController<int>.broadcast();

  /// Emits when the receiver captures a message while the app is running.
  /// Nothing depends on it arriving — it only makes the import immediate
  /// instead of waiting for the next launch.
  Stream<int> get onCaptured => _captured.stream;

  bool _listening = false;

  /// Only Android has the receiver. Everywhere else — iOS, and the unit tests —
  /// the queue is permanently empty rather than an error.
  bool get isSupported => !kIsWeb && Platform.isAndroid;

  void startListening() {
    if (_listening || !isSupported) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSmsCaptured') {
        _captured.add((call.arguments as num?)?.toInt() ?? 0);
      }
      return null;
    });
  }

  void dispose() {
    if (_listening) {
      _channel.setMethodCallHandler(null);
      _listening = false;
    }
    _captured.close();
  }

  Future<List<QueuedSms>> pending({int limit = 200}) async {
    if (!isSupported) return const [];
    try {
      final rows = await _channel
          .invokeListMethod<Map<dynamic, dynamic>>('peek', {'limit': limit});
      if (rows == null) return const [];

      return rows
          .map((r) => QueuedSms(
                (r['id'] as num).toInt(),
                RawSms(
                  body: (r['body'] ?? '').toString(),
                  sender: r['sender']?.toString(),
                  receivedAt: DateTime.fromMillisecondsSinceEpoch(
                      (r['receivedAt'] as num?)?.toInt() ?? 0),
                ),
              ))
          .where((q) => q.message.body.trim().isNotEmpty)
          .toList();
    } on MissingPluginException {
      // Running against a build without the native side (or a unit test).
      return const [];
    } on PlatformException catch (e) {
      debugPrint('SMS queue peek failed: ${e.message}');
      return const [];
    }
  }

  Future<void> acknowledge(List<int> ids) async {
    if (!isSupported || ids.isEmpty) return;
    try {
      await _channel.invokeMethod('acknowledge', {'ids': ids});
    } on MissingPluginException {
      // Nothing to acknowledge against.
    } on PlatformException catch (e) {
      // Leaving the messages queued is the safe failure: they are re-imported
      // next time and de-duplicated away.
      debugPrint('SMS queue acknowledge failed: ${e.message}');
    }
  }

  Future<int> count() async {
    if (!isSupported) return 0;
    try {
      return await _channel.invokeMethod<int>('count') ?? 0;
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      return 0;
    }
  }
}

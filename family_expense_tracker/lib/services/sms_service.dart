import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';

import 'sms_reader.dart';

export 'sms_reader.dart' show RawSms, SmsReader;

/// Reads the device inbox via `flutter_sms_inbox`.
class InboxSmsReader implements SmsReader {
  final SmsQuery _query = SmsQuery();

  @override
  Future<bool> hasPermission() async => Permission.sms.status.then((s) => s.isGranted);

  @override
  Future<bool> ensurePermission() async {
    var status = await Permission.sms.status;
    if (!status.isGranted) {
      status = await Permission.sms.request();
    }
    return status.isGranted;
  }

  @override
  Future<List<RawSms>> read({int count = 2000}) async {
    final messages = await _query.querySms(
      kinds: [SmsQueryKind.inbox],
      count: count,
    );

    return messages
        .map((m) => RawSms(
              body: m.body ?? '',
              sender: m.address,
              receivedAt: m.date ?? DateTime.now(),
            ))
        .where((m) => m.body.trim().isNotEmpty)
        .toList();
  }
}

/// Retained for the existing call sites that only need the permission prompt.
/// Transaction extraction now lives in `TransactionImportService`.
class SmsService {
  final SmsReader reader;

  SmsService({SmsReader? reader}) : reader = reader ?? InboxSmsReader();

  Future<bool> requestSmsPermission() => reader.ensurePermission();
}

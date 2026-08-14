/// One inbox message, stripped of any plugin types.
///
/// The importer works against this rather than the plugin's `SmsMessage` so the
/// whole import pipeline can be driven from unit tests with hand-written
/// messages — and so this file stays free of platform channels, which would
/// otherwise make the tests need a device.
class RawSms {
  final String body;
  final String? sender;
  final DateTime receivedAt;

  const RawSms({
    required this.body,
    required this.receivedAt,
    this.sender,
  });
}

abstract class SmsReader {
  /// Whether access is already granted. Distinct from [ensurePermission] so a
  /// background/automatic sync can stay silent instead of throwing a system
  /// dialog at the user every time they open the app.
  Future<bool> hasPermission();

  /// Returns false if the user declined SMS access. May prompt.
  Future<bool> ensurePermission();

  Future<List<RawSms>> read({int count});
}

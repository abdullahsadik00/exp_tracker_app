import '../utils/stable_hash.dart';

/// Builds the identity key used to decide whether two records describe the
/// same real-world transaction.
///
/// The rule is strongest-identifier-first. Amount alone is never enough — two
/// ₹50 auto fares on the same day are two transactions, while the same ₹50
/// payment announced by both the bank and the UPI app is one. Each tier below
/// is a strictly weaker claim than the one above it, and the tier prefix is
/// part of the key so a weak key can never accidentally equal a strong one.
class TransactionFingerprint {
  const TransactionFingerprint._();

  /// Tier 1 — UPI RRN. Globally unique and printed by both the bank and the
  /// payment app, so this is what merges duplicate announcements of one payment.
  /// Direction is included because the two legs of a self-transfer share an RRN.
  static String? _fromUpi(String? upiId, String type, int amountPaise) {
    final v = _clean(upiId);
    if (v == null || v.length < 9) return null;
    return 'u1|$v|$type|$amountPaise';
  }

  /// Tier 2 — bank reference / UTR. Unique within a bank, so the bank is part
  /// of the key.
  static String? _fromRef(
      String? referenceId, String bank, String type, int amountPaise) {
    final v = _clean(referenceId);
    if (v == null || v.length < 4) return null;
    return 'r2|${bank.toUpperCase()}|$v|$type|$amountPaise';
  }

  /// Tier 3 — account + direction + amount + minute. No reference number was
  /// published, so we fall back to "the same account cannot move the same
  /// amount the same way twice within one minute".
  static String? _fromAccount(String? accountTail, String bank, String type,
      int amountPaise, DateTime when) {
    final tail = _clean(accountTail);
    if (tail == null) return null;
    return 'a3|${bank.toUpperCase()}|$tail|$type|$amountPaise|${_minute(when)}';
  }

  /// Tier 4 — hash of the message itself. Catches literally redelivered SMS.
  static String? _fromBody(String? rawText) {
    final normalized = normalizeForHash(rawText ?? '');
    if (normalized.length < 12) return null;
    return 'b4|${stableHash(normalized)}';
  }

  /// Tier 5 — last resort for rows with no message at all (manual entries,
  /// statement rows). Deliberately includes the full timestamp and description
  /// so two genuinely distinct manual entries stay distinct.
  ///
  /// [occurrence] disambiguates statement rows that really are identical in
  /// every field — a statement listing two ₹50 fares on the same day is two
  /// transactions. It is the index of the row *within its own identical group*,
  /// not within the file, so re-importing an overlapping statement produces the
  /// same numbering and stays idempotent.
  static String _fromFields(String bank, String type, int amountPaise,
      DateTime when, String description, int occurrence) {
    return 'f5|${bank.toUpperCase()}|$type|$amountPaise|'
        '${when.toIso8601String()}|'
        '${stableHash(normalizeForHash(description))}|$occurrence';
  }

  /// Resolves the strongest fingerprint available for a transaction.
  ///
  /// Set [allowBodyHash] to false for sources whose "raw text" is just the
  /// user's own description (manual entries, statement rows). Hashing those
  /// would make two separate ₹100 "Tea" entries collide and silently drop one.
  static String build({
    required String bank,
    required String type,
    required int amountPaise,
    required DateTime dateTime,
    String? accountTail,
    String? referenceId,
    String? upiTransactionId,
    String? rawText,
    String description = '',
    bool allowBodyHash = true,
    int occurrence = 0,
  }) {
    return _fromUpi(upiTransactionId, type, amountPaise) ??
        _fromRef(referenceId, bank, type, amountPaise) ??
        _fromAccount(accountTail, bank, type, amountPaise, dateTime) ??
        (allowBodyHash ? _fromBody(rawText) : null) ??
        _fromFields(
            bank, type, amountPaise, dateTime, description, occurrence);
  }

  /// Which tier a fingerprint came from, for the reconciliation UI. Lower is
  /// stronger.
  static int tierOf(String fingerprint) {
    if (fingerprint.startsWith('u1|')) return 1;
    if (fingerprint.startsWith('r2|')) return 2;
    if (fingerprint.startsWith('a3|')) return 3;
    if (fingerprint.startsWith('b4|')) return 4;
    return 5;
  }

  static String tierLabel(String? fingerprint) {
    switch (fingerprint == null ? 5 : tierOf(fingerprint)) {
      case 1:
        return 'UPI reference';
      case 2:
        return 'Bank reference';
      case 3:
        return 'Account + amount + time';
      case 4:
        return 'Message fingerprint';
      default:
        return 'Field fingerprint';
    }
  }

  static String? _clean(String? v) {
    if (v == null) return null;
    final s = v.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (s.isEmpty) return null;
    // Placeholder junk some banks emit in place of a real reference.
    if (RegExp(r'^0+$').hasMatch(s)) return null;
    if (RegExp(r'^(NA|NIL|NONE|NO)$').hasMatch(s)) return null;
    return s;
  }

  static String _minute(DateTime d) {
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(d.year, 4)}${p(d.month)}${p(d.day)}${p(d.hour)}${p(d.minute)}';
  }
}

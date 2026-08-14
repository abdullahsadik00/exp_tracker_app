/// Fixed-precision money helpers.
///
/// Every monetary value in the app is canonically an `int` number of paise
/// (1/100 rupee). Doubles are only used at the display boundary. Summing a few
/// thousand `double` rupee values drifts by fractions of a paisa and makes the
/// balance disagree with itself between two queries; integers never do.
class Money {
  const Money._();

  static const int scale = 100;

  /// Converts a legacy `REAL` rupee value to paise.
  ///
  /// `round()` (not `toInt()`) matters: 42.5 * 100 is 4250.000000000001 and
  /// 8.2 * 100 is 819.9999999999999 — truncating the latter loses a paisa.
  static int fromDouble(double rupees) => (rupees * scale).round();

  static double toDouble(int paise) => paise / scale;

  /// Parses an amount token lifted out of an SMS or a statement row into paise
  /// without ever constructing a double.
  ///
  /// Handles Indian and Western grouping (`1,23,456.78`, `123,456.78`),
  /// trailing separators (`500/-`, `500.`), currency symbols and stray spaces.
  /// Returns null if there is no digit to work with.
  static int? parsePaise(String raw) {
    // Keep only digits, a decimal point and a leading sign.
    var s = raw.replaceAll(RegExp(r'[^0-9.\-]'), '');
    // "500/-" became "500-", "Rs.500." became "500." — drop dangling markers.
    s = s.replaceAll(RegExp(r'\.+$'), '');
    if (s.isEmpty) return null;

    final negative = s.startsWith('-');
    s = s.replaceAll('-', '');
    if (s.isEmpty) return null;

    String intPart;
    String fracPart;
    final dot = s.indexOf('.');
    if (dot < 0) {
      intPart = s;
      fracPart = '';
    } else {
      intPart = s.substring(0, dot);
      // A second dot can only be noise ("1.234.56"); the first one wins.
      fracPart = s.substring(dot + 1).replaceAll('.', '');
    }

    if (intPart.isEmpty) intPart = '0';
    if (fracPart.length > 2) fracPart = fracPart.substring(0, 2);
    fracPart = fracPart.padRight(2, '0');

    final rupees = int.tryParse(intPart);
    final paise = int.tryParse(fracPart);
    if (rupees == null || paise == null) return null;

    final total = rupees * scale + paise;
    return negative ? -total : total;
  }

  /// `123456789` -> `"1,234,567.89"`. Grouping is left to `intl` at the widget
  /// layer; this is the plain form used in logs, fingerprints and diffs.
  static String toPlainString(int paise) {
    final negative = paise < 0;
    final abs = paise.abs();
    final rupees = abs ~/ scale;
    final frac = (abs % scale).toString().padLeft(2, '0');
    return '${negative ? '-' : ''}$rupees.$frac';
  }
}

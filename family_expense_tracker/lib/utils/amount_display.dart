import 'package:intl/intl.dart';

import 'money.dart';

/// Display-side money formatting.
///
/// [Money] handles storage (integer paise); this handles what the user reads,
/// including the masked form used when amounts are hidden. Keeping the mask
/// here rather than at each call site is what makes "hidden" mean the same
/// thing for every figure on screen.

final NumberFormat _rupees2 =
    NumberFormat.currency(symbol: '₹', decimalDigits: 2);
final NumberFormat _rupees0 =
    NumberFormat.currency(symbol: '₹', decimalDigits: 0);

/// The mask is a fixed width rather than one dot per digit, so the number of
/// dots never leaks how large the amount is.
const String maskedAmount = '••••••';

String formatRupees(double amount, {int decimals = 2}) =>
    (decimals == 0 ? _rupees0 : _rupees2).format(amount);

/// A signed amount, with the sign in front of the currency symbol rather than
/// inside it ("-₹500", not "₹-500").
String formatSignedRupees(double amount, {int decimals = 2}) {
  final sign = amount < 0 ? '-' : '';
  return '$sign${formatRupees(amount.abs(), decimals: decimals)}';
}

/// Whole-rupee formatting straight from stored paise. Analytics never shows
/// paise — at the scale of a monthly budget the decimals are noise, and they
/// cost the horizontal room a comparison needs.
String formatPaise(int paise) => formatRupees(Money.toDouble(paise), decimals: 0);

String formatSignedPaise(int paise) =>
    formatSignedRupees(Money.toDouble(paise), decimals: 0);

/// Axis-scale money: "₹48k", "₹1.2L". Indian units, because a family reading
/// this thinks in lakhs and not in hundred-thousands.
String formatCompactRupees(int paise) {
  final rupees = Money.toDouble(paise).abs();
  if (rupees >= 100000) return '₹${(rupees / 100000).toStringAsFixed(1)}L';
  if (rupees >= 1000) return '₹${(rupees / 1000).round()}k';
  return '₹${rupees.round()}';
}

String displayAmount(double amount, {required bool hidden, int decimals = 2}) =>
    hidden ? maskedAmount : formatRupees(amount, decimals: decimals);

String displaySignedAmount(double amount,
        {required bool hidden, int decimals = 2}) =>
    hidden ? maskedAmount : formatSignedRupees(amount, decimals: decimals);

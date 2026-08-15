import 'package:intl/intl.dart';

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

String displayAmount(double amount, {required bool hidden, int decimals = 2}) =>
    hidden ? maskedAmount : formatRupees(amount, decimals: decimals);

String displaySignedAmount(double amount,
        {required bool hidden, int decimals = 2}) =>
    hidden ? maskedAmount : formatSignedRupees(amount, decimals: decimals);

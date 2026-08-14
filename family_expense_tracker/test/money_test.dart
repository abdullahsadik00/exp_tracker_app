import 'package:flutter_test/flutter_test.dart';
import 'package:family_expense_tracker/utils/money.dart';

void main() {
  group('Money.parsePaise', () {
    test('parses plain amounts', () {
      expect(Money.parsePaise('500'), 50000);
      expect(Money.parsePaise('500.00'), 50000);
      expect(Money.parsePaise('0.01'), 1);
      expect(Money.parsePaise('0.1'), 10);
    });

    test('strips Indian and Western thousand separators', () {
      expect(Money.parsePaise('1,234.56'), 123456);
      expect(Money.parsePaise('1,23,456.78'), 12345678);
      expect(Money.parsePaise('123,456,789.00'), 12345678900);
    });

    test('strips currency symbols and trailing markers', () {
      expect(Money.parsePaise('Rs.500'), 50000);
      expect(Money.parsePaise('INR 1,000.50'), 100050);
      expect(Money.parsePaise('₹250.25'), 25025);
      expect(Money.parsePaise('500/-'), 50000);
      expect(Money.parsePaise('500.'), 50000);
    });

    test('truncates beyond paise rather than rounding up a rupee', () {
      expect(Money.parsePaise('10.999'), 1099);
    });

    test('handles negatives and rejects junk', () {
      expect(Money.parsePaise('-42.50'), -4250);
      expect(Money.parsePaise('abc'), isNull);
      expect(Money.parsePaise(''), isNull);
    });
  });

  group('Money.fromDouble', () {
    test('rounds rather than truncates binary float error', () {
      // 8.2 * 100 is 819.9999999999999 in IEEE-754; truncation loses a paisa.
      expect(Money.fromDouble(8.2), 820);
      expect(Money.fromDouble(42.5), 4250);
      expect(Money.fromDouble(0.07), 7);
    });
  });

  test('integer summation does not drift the way doubles do', () {
    // 0.1 added 1000 times as a double lands on 99.9999999999986.
    var paise = 0;
    for (var i = 0; i < 1000; i++) {
      paise += Money.parsePaise('0.10')!;
    }
    expect(paise, 10000);
    expect(Money.toDouble(paise), 100.0);
  });

  test('toPlainString round-trips', () {
    expect(Money.toPlainString(123456), '1234.56');
    expect(Money.toPlainString(5), '0.05');
    expect(Money.toPlainString(-4250), '-42.50');
  });
}

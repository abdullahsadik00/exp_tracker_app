import 'package:flutter_test/flutter_test.dart';
import 'package:family_expense_tracker/services/categorization_service.dart';

void main() {
  group('rule matching', () {
    test('reports only what the rules matched, with no defaults', () {
      final service = CategorizationService(const [
        CategorizationRule(keyword: 'BLINKIT', category: 'Groceries'),
      ]);

      final m = service.match('UPI/DR/123/BLINKIT COMMERCE');
      expect(m.category, 'Groceries');
      // The point of match(): no placeholder person or bank, so a
      // re-categorisation cannot overwrite a real value with a default.
      expect(m.assignedTo, isNull);
      expect(m.bankName, isNull);
    });

    test('nothing matched is reported as empty', () {
      final service = CategorizationService(const [
        CategorizationRule(keyword: 'BLINKIT', category: 'Groceries'),
      ]);
      expect(service.match('SOME OTHER PAYEE').isEmpty, isTrue);
    });

    test('a lower-case keyword still matches', () {
      // Keywords are upper-cased when saved through the rules screen, but a
      // rule restored from an older backup may not be. Before this, such a
      // rule silently never matched anything.
      final service = CategorizationService(const [
        CategorizationRule(keyword: 'swiggy', category: 'Dining'),
      ]);
      expect(service.match('UPI-SWIGGY LIMITED').category, 'Dining');
    });

    test('the first matching rule wins per field', () {
      // getCategorizationRules orders by priority, so the earlier rule in the
      // list is the higher-priority one.
      final service = CategorizationService(const [
        CategorizationRule(keyword: 'AMAZON', category: 'Shopping', priority: 10),
        CategorizationRule(keyword: 'AMAZON', category: 'Utilities', priority: 30),
      ]);
      expect(service.match('AMAZON PAY RECHARGE').category, 'Shopping');
    });

    test('separate rules fill separate fields', () {
      final service = CategorizationService(const [
        CategorizationRule(keyword: 'HEENA', assignedTo: 'Me'),
        CategorizationRule(keyword: 'BLINKIT', category: 'Groceries'),
      ]);
      final m = service.match('HEENA paid BLINKIT');
      expect(m.assignedTo, 'Me');
      expect(m.category, 'Groceries');
    });

    test('a BoB UPI payee is matched by its VPA', () {
      // The rows the parser fix just started importing name the counterparty
      // only by UPI handle, so that is what a rule has to key off.
      final service = CategorizationService(const [
        CategorizationRule(keyword: 'ANGELMFCPUPA', category: 'Education'),
      ]);
      final m = service.match(
        'Rs.1000.00 Dr. from A/C XXXXXX1617 and Cr. to angelmfcpupa@indus. '
        'Ref:100143760671.',
      );
      expect(m.category, 'Education');
    });
  });

  group('import-time analysis still fills defaults', () {
    test('an unmatched transaction gets the placeholder values', () {
      final service = CategorizationService(const []);
      final a = service.analyzeTransaction('SOMETHING UNKNOWN', 'debit');
      expect(a['category'], 'Other');
      expect(a['assignedTo'], 'Unassigned');
      expect(a['bankName'], 'SBI');
    });

    test('a matched category with no person is assumed to be mine', () {
      final service = CategorizationService(const [
        CategorizationRule(keyword: 'BLINKIT', category: 'Groceries'),
      ]);
      final a = service.analyzeTransaction('trf to BLINKIT', 'debit');
      expect(a['category'], 'Groceries');
      expect(a['assignedTo'], 'Me');
    });
  });
}

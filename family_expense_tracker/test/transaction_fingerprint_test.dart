import 'package:flutter_test/flutter_test.dart';
import 'package:family_expense_tracker/services/transaction_fingerprint.dart';
import 'package:family_expense_tracker/utils/stable_hash.dart';

void main() {
  final when = DateTime(2026, 1, 15, 10, 30, 12);

  String fp({
    String bank = 'SBI',
    String type = 'debit',
    int amountPaise = 50000,
    DateTime? dateTime,
    String? tail,
    String? ref,
    String? upi,
    String? rawText,
    String description = '',
    bool allowBodyHash = true,
    int occurrence = 0,
  }) =>
      TransactionFingerprint.build(
        bank: bank,
        type: type,
        amountPaise: amountPaise,
        dateTime: dateTime ?? when,
        accountTail: tail,
        referenceId: ref,
        upiTransactionId: upi,
        rawText: rawText,
        description: description,
        allowBodyHash: allowBodyHash,
        occurrence: occurrence,
      );

  group('tier selection', () {
    test('UPI reference is preferred over everything else', () {
      expect(TransactionFingerprint.tierOf(
          fp(upi: '412345678901', ref: 'ABC123', tail: '8724')), 1);
    });

    test('bank reference is used when there is no UPI id', () {
      expect(TransactionFingerprint.tierOf(fp(ref: 'ABC123', tail: '8724')), 2);
    });

    test('account + time is used when there is no reference', () {
      expect(TransactionFingerprint.tierOf(fp(tail: '8724')), 3);
    });

    test('message hash is the fallback for SMS with no identifiers', () {
      expect(
          TransactionFingerprint.tierOf(
              fp(rawText: 'Some reasonably long bank message body')),
          4);
    });

    test('field fingerprint is the last resort', () {
      expect(TransactionFingerprint.tierOf(fp()), 5);
    });
  });

  group('identity', () {
    test('same UPI reference from two different senders collapses to one', () {
      // The bank and the payment app describe one payment in different words.
      final fromBank = fp(
        upi: '412345678901',
        rawText: 'A/c XX8724 debited by Rs.500 UPI Ref 412345678901',
        bank: 'SBI',
      );
      final fromApp = fp(
        upi: '412345678901',
        rawText: 'You paid Rs.500 to MERCHANT. UPI transaction ID 412345678901',
        bank: 'PhonePe',
      );
      expect(fromBank, fromApp);
    });

    test('the two legs of a self-transfer stay distinct', () {
      expect(fp(upi: '412345678901', type: 'debit'),
          isNot(fp(upi: '412345678901', type: 'credit')));
    });

    test('same reference at a different amount is a different transaction', () {
      expect(fp(ref: 'ABC123', amountPaise: 50000),
          isNot(fp(ref: 'ABC123', amountPaise: 60000)));
    });

    test('same amount seconds apart on the same account is one transaction', () {
      // Tier 3 buckets by minute, so a redelivered SMS with a slightly
      // different timestamp still matches.
      expect(
        fp(tail: '8724', dateTime: DateTime(2026, 1, 15, 10, 30, 5)),
        fp(tail: '8724', dateTime: DateTime(2026, 1, 15, 10, 30, 55)),
      );
    });

    test('same amount in a different minute is two transactions', () {
      expect(
        fp(tail: '8724', dateTime: DateTime(2026, 1, 15, 10, 30)),
        isNot(fp(tail: '8724', dateTime: DateTime(2026, 1, 15, 10, 32))),
      );
    });

    test('cosmetic differences in the message do not change the hash', () {
      expect(
        fp(rawText: 'A/c  XX8724   debited by Rs.500 on 15Jan26'),
        fp(rawText: 'a/c xx8724 debited by rs.500 on 15jan26'),
      );
    });

    test('placeholder references are ignored rather than trusted', () {
      // "Ref: NA" must not make every such transaction identical.
      final a = fp(ref: 'NA', tail: '8724', amountPaise: 100);
      final b = fp(ref: 'NIL', tail: '8724', amountPaise: 100);
      expect(TransactionFingerprint.tierOf(a), 3);
      expect(a, b);
    });
  });

  group('non-SMS sources', () {
    test('two identical manual entries at different times stay distinct', () {
      expect(
        fp(
            rawText: 'Tea',
            description: 'Tea',
            allowBodyHash: false,
            dateTime: DateTime(2026, 1, 15, 9, 0)),
        isNot(fp(
            rawText: 'Tea',
            description: 'Tea',
            allowBodyHash: false,
            dateTime: DateTime(2026, 1, 15, 17, 0))),
      );
    });

    test('two truly identical statement rows are kept apart by occurrence', () {
      expect(
        fp(description: 'AUTO FARE', allowBodyHash: false, occurrence: 0),
        isNot(fp(description: 'AUTO FARE', allowBodyHash: false, occurrence: 1)),
      );
    });

    test('re-importing the same statement produces the same fingerprints', () {
      final first = [0, 1, 2]
          .map((i) => fp(description: 'AUTO FARE', allowBodyHash: false, occurrence: i))
          .toList();
      final second = [0, 1, 2]
          .map((i) => fp(description: 'AUTO FARE', allowBodyHash: false, occurrence: i))
          .toList();
      expect(first, second);
    });
  });

  group('stableHash', () {
    test('is deterministic', () {
      expect(stableHash('hello world'), stableHash('hello world'));
    });

    test('separates similar inputs including anagrams', () {
      expect(stableHash('abc'), isNot(stableHash('acb')));
      expect(stableHash('Rs.500'), isNot(stableHash('Rs.5000')));
    });

    test('normalisation collapses whitespace and case', () {
      expect(normalizeForHash('  A/c   XX1  '), 'A/C XX1');
    });
  });
}

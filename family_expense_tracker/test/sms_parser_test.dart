import 'package:flutter_test/flutter_test.dart';
import 'package:family_expense_tracker/models/transaction_model.dart';
import 'package:family_expense_tracker/services/sms_parser.dart';

void main() {
  const parser = SmsParser();
  final received = DateTime(2026, 1, 15, 10, 30);

  ParsedSms parse(String body, {String? sender, DateTime? at}) =>
      parser.parse(body: body, sender: sender, receivedAt: at ?? received);

  group('expense detection', () {
    test('SBI debit alert', () {
      final r = parse(
        'Dear SBI User, your A/c X8724-debited by Rs.500.00 on 15Jan26 '
        'transfer to MUKESH CHAND Ref No 601512345678. '
        'If not done by you, forward this SMS to 9223008333',
        sender: 'VM-SBIINB',
      );

      expect(r.isTransaction, isTrue);
      expect(r.type, 'debit');
      expect(r.amountPaise, 50000);
      expect(r.bank, 'SBI');
      expect(r.accountTail, '8724');
      expect(r.referenceId, '601512345678');
      expect(r.status, TxnStatus.posted);
      expect(r.needsReview, isFalse);
    });

    test('card purchase', () {
      final r = parse(
        'Rs 1,299.00 spent on your HDFC Bank Card ending 4412 at BIG BAZAAR '
        'on 14-01-26. Avl Bal: Rs 22,110.45',
        sender: 'VK-HDFCBK',
      );

      expect(r.type, 'debit');
      expect(r.amountPaise, 129900);
      expect(r.bank, 'HDFC');
      expect(r.balancePaise, 2211045);
    });

    test('ATM withdrawal is classified as an ATM movement', () {
      final r = parse(
        'Rs.2000 withdrawn from A/c XX8724 at ATM on 15-01-26. '
        'Avl Bal Rs.18,500.00',
      );
      expect(r.type, 'debit');
      expect(r.amountPaise, 200000);
      expect(r.kind, TxnKind.atm);
    });
  });

  group('income detection', () {
    test('salary credit', () {
      final r = parse(
        'Dear Customer, Your A/c XX8724 is credited with Rs.45,000.00 on '
        '01-01-26 by transfer from BEE LOGICA. Avl Bal Rs.63,500.00 -SBI',
        sender: 'AD-SBIINB',
      );

      expect(r.type, 'credit');
      expect(r.amountPaise, 4500000);
      expect(r.balancePaise, 6350000);
    });

    test('UPI credit carries the RRN', () {
      final r = parse(
        'Rs.750 credited to A/c XX1234 on 12Jan26 by UPI Ref 412345678901 '
        'from AMREEN SHAIKH',
      );
      expect(r.type, 'credit');
      expect(r.upiTransactionId, '412345678901');
    });
  });

  group('direction is decided by proximity, not by first match', () {
    test('debit wins when both verbs appear', () {
      // The naive "contains('credited')" check gets this backwards.
      final r = parse(
        'Rs.500.00 debited from A/c XX8724 and credited to beneficiary '
        'MERCHANT UPI Ref:123456789012 -Bank of Baroda',
      );
      expect(r.type, 'debit');
      expect(r.bank, 'BoB');
    });

    test('credit wins when the credit verb is the near one', () {
      final r = parse(
        'Rs.900 credited to A/c XX8724 by debit from the sender account. '
        'Ref 998877665544',
      );
      expect(r.type, 'credit');
    });
  });

  group('amount extraction never picks up the balance', () {
    test('balance figure is excluded even when it comes first', () {
      final r = parse(
        'Avl Bal Rs.10,000.00 in A/c XX8724 after Rs.250.00 was debited '
        'on 15-01-26 Ref 123456',
      );
      expect(r.amountPaise, 25000);
      expect(r.balancePaise, 1000000);
    });

    test('account number is not mistaken for an amount', () {
      final r = parse(
        'A/c 40123456789 debited by Rs.75.50 on 15Jan26 Ref No 555444333',
      );
      expect(r.amountPaise, 7550);
    });

    test('two transaction amounts are flagged rather than guessed', () {
      final r = parse(
        'Rs.500.00 debited on 15-01-26 and a charge of Rs.25.00 was levied. '
        'Ref 123456789',
      );
      expect(r.isTransaction, isTrue);
      expect(r.amountPaise, 50000);
      expect(r.needsReview, isTrue);
      expect(r.extraAmountCount, 1);
    });
  });

  group('refunds and reversals', () {
    test('refund is a credit, not a failure', () {
      final r = parse(
        'Rs.1,200.00 has been refunded to your A/c XX8724 for order '
        '#4471 on 15-01-26. Ref No 778899001122',
      );
      expect(r.type, 'credit');
      expect(r.kind, TxnKind.refund);
      expect(r.status, TxnStatus.posted);
    });

    test('reversal of a failed transaction still moves money back', () {
      final r = parse(
        'Your failed transaction of Rs.300.00 has been reversed and credited '
        'to A/c XX8724 on 15-01-26. Ref 456789012345',
      );
      expect(r.type, 'credit');
      expect(r.kind, TxnKind.reversal);
      // The word "failed" refers to the original txn, not to this movement.
      expect(r.status, TxnStatus.posted);
    });

    test('partial refund parses its own amount', () {
      final r = parse(
        'Partial refund of Rs.450.75 credited to A/c XX8724 Ref 111222333444',
      );
      expect(r.amountPaise, 45075);
      expect(r.type, 'credit');
    });
  });

  group('failed transactions are recorded but not counted', () {
    test('declined card payment', () {
      final r = parse(
        'Your transaction of Rs.5,000.00 on Card XX4412 was declined due to '
        'insufficient balance on 15-01-26. Ref 909090909090',
      );
      expect(r.isTransaction, isTrue);
      expect(r.status, TxnStatus.failed);
      expect(r.needsReview, isTrue);
    });

    test('failed UPI payment', () {
      final r = parse(
        'Rs.200 debit from A/c XX8724 failed. UPI Ref 121212121212',
      );
      expect(r.status, TxnStatus.failed);
    });
  });

  group('non-transactional messages are rejected with a reason', () {
    test('OTP', () {
      final r = parse(
        '123456 is your OTP for a transaction of Rs.5,000 on your card. '
        'Do not share it with anyone.',
      );
      expect(r.isTransaction, isFalse);
      expect(r.rejectReason, SmsRejectReason.otp);
    });

    test('promotional loan offer', () {
      final r = parse(
        'Dear Customer, you are pre-approved for a personal loan of '
        'Rs.5,00,000 at 10.5% p.a. Apply now!',
      );
      expect(r.isTransaction, isFalse);
      expect(r.rejectReason, SmsRejectReason.promotional);
    });

    test('collect request is not money that moved', () {
      final r = parse(
        'RAHUL has requested Rs.500 via UPI. Approve the request in your app.',
      );
      expect(r.isTransaction, isFalse);
      expect(r.rejectReason, SmsRejectReason.paymentRequest);
    });

    test('mandate announcements are not imported', () {
      final r = parse(
        'Rs.499 will be debited from your A/c XX8724 on 20-01-26 towards '
        'your Netflix e-mandate.',
      );
      expect(r.isTransaction, isFalse);
      expect(r.rejectReason, SmsRejectReason.futureOrMandate);
    });

    test('balance enquiry has no movement', () {
      final r = parse('Avl Bal in your A/c XX8724 is Rs.18,500.00 as on 15-01-26');
      expect(r.isTransaction, isFalse);
      expect(r.rejectReason, SmsRejectReason.balanceEnquiry);
    });
  });

  group('dates', () {
    test('uses the date stated in the body for a late-delivered SMS', () {
      final r = parse(
        'A/c XX8724 debited by Rs.100 on 10-01-26 Ref 123456789',
        at: DateTime(2026, 1, 15, 9, 0),
      );
      expect(r.dateFromBody, isTrue);
      expect(r.dateTime.year, 2026);
      expect(r.dateTime.month, 1);
      expect(r.dateTime.day, 10);
    });

    test('accepts 01Jan26 style', () {
      final r = parse(
        'A/c XX8724 debited by Rs.100 on 03Jan26 Ref 123456789',
        at: DateTime(2026, 1, 15),
      );
      expect(r.dateTime.day, 3);
      expect(r.dateTime.month, 1);
    });

    test('picks up an explicit time', () {
      final r = parse(
        'Rs.100 debited from A/c XX8724 on 10-01-26 at 14:35 Ref 123456789',
        at: DateTime(2026, 1, 15),
      );
      expect(r.dateTime.hour, 14);
      expect(r.dateTime.minute, 35);
    });

    test('ignores an impossible date and falls back to delivery time', () {
      final r = parse(
        'Rs.100 debited from A/c XX8724 on 31-02-26 Ref 123456789',
        at: DateTime(2026, 2, 20),
      );
      expect(r.dateFromBody, isFalse);
      expect(r.dateTime, DateTime(2026, 2, 20));
    });

    test('ignores a far-future date such as a card expiry', () {
      final r = parse(
        'Rs.100 debited on card valid till 12-12-30 Ref 123456789',
        at: DateTime(2026, 1, 15),
      );
      expect(r.dateFromBody, isFalse);
    });
  });

  group('robustness', () {
    test('empty and malformed messages do not throw', () {
      expect(parse('').isTransaction, isFalse);
      expect(parse('   ').isTransaction, isFalse);
      expect(parse('!!!???').isTransaction, isFalse);
      expect(parse('debited credited debited').isTransaction, isFalse);
      expect(parse('Rs.').isTransaction, isFalse);
    });

    test('an amount with no direction verb is rejected, not assumed', () {
      final r = parse('Transaction of Rs.500.00 on A/c XX8724 Ref 123456');
      expect(r.isTransaction, isFalse);
      expect(r.rejectReason, SmsRejectReason.noDirection);
    });

    test('merchant is extracted where one is stated', () {
      final r = parse(
        'A/c X8724-debited by Rs.500.00 on 15Jan26 trf to BLINKIT '
        'Ref No 601512345678',
      );
      expect(r.merchant, 'BLINKIT');
    });

    test('missing merchant name is left null rather than invented', () {
      final r = parse('A/c XX8724 debited by Rs.100 Ref 123456789');
      expect(r.merchant, isNull);
    });
  });
}

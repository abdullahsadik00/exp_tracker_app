import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:family_expense_tracker/models/transaction_model.dart';
import 'package:family_expense_tracker/services/local_db_service.dart';
import 'package:family_expense_tracker/services/native_sms_queue.dart';
import 'package:family_expense_tracker/services/sms_reader.dart';
import 'package:family_expense_tracker/services/transaction_import_service.dart';
import 'package:family_expense_tracker/utils/money.dart';

/// Feeds the importer a fixed list of messages instead of a device inbox.
class FakeSmsReader implements SmsReader {
  FakeSmsReader(this.messages, {this.granted = true});

  List<RawSms> messages;
  bool granted;
  int readCount = 0;

  @override
  Future<bool> hasPermission() async => granted;

  @override
  Future<bool> ensurePermission() async => granted;

  @override
  Future<List<RawSms>> read({int count = 2000}) async {
    readCount++;
    return messages.take(count).toList();
  }
}

/// Stands in for the Android broadcast-receiver queue.
class FakeNativeSmsQueue extends NativeSmsQueue {
  FakeNativeSmsQueue(this._queued, {bool supported = true})
      : _supported = supported;

  final List<QueuedSms> _queued;
  final bool _supported;

  final List<int> acknowledged = [];

  /// How many transactions were in the ledger at the moment acknowledge was
  /// called — used to prove the import commits first.
  int rowsAtAcknowledge = -1;

  @override
  bool get isSupported => _supported;

  @override
  Future<List<QueuedSms>> pending({int limit = 200}) async =>
      _supported ? _queued.take(limit).toList() : const [];

  @override
  Future<void> acknowledge(List<int> ids) async {
    final raw = await LocalDbService.instance.database;
    final r = await raw.rawQuery('SELECT COUNT(*) as c FROM transactions');
    rowsAtAcknowledge = (r.first['c'] as num).toInt();
    acknowledged.addAll(ids);
    _queued.removeWhere((q) => ids.contains(q.id));
  }

  @override
  Future<int> count() async => _queued.length;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final db = LocalDbService.instance;
  final at = DateTime(2026, 1, 15, 10, 30);

  RawSms sms(String body, {String? sender, DateTime? when}) =>
      RawSms(body: body, sender: sender ?? 'VM-SBIINB', receivedAt: when ?? at);

  setUp(() async {
    await db.resetForTesting();
    // openDatabase with the ffi factory and this name gives each run a clean
    // file under the current directory; wipe anything a previous run left.
    final raw = await db.database;
    await raw.delete('transactions');
    await raw.delete('deleted_fingerprints');
    await raw.delete('sms_import_log');
    await raw.delete('accounts');
    await raw.delete('sync_state');
    await raw.delete('budgets');
  });

  tearDownAll(() async {
    await db.resetForTesting();
  });

  Future<int> countRows() async {
    final raw = await db.database;
    final r = await raw.rawQuery('SELECT COUNT(*) as c FROM transactions');
    return (r.first['c'] as num).toInt();
  }

  const debitSms =
      'Dear SBI User, your A/c X8724-debited by Rs.500.00 on 15Jan26 '
      'transfer to MUKESH CHAND Ref No 601512345678. Avl Bal Rs.9,500.00';
  const creditSms =
      'Dear Customer, Your A/c XX8724 is credited with Rs.2,000.00 on 15-01-26 '
      'by transfer from BEE LOGICA. Avl Bal Rs.11,500.00 -SBI';

  group('historical import', () {
    test('imports every recognisable transaction once', () async {
      final importer =
          TransactionImportService(reader: FakeSmsReader([sms(debitSms), sms(creditSms)]));

      final report = await importer.sync();

      expect(report.imported, 2);
      expect(report.duplicates, 0);
      expect(await countRows(), 2);
    });

    test('re-running the sync adds nothing', () async {
      final reader = FakeSmsReader([sms(debitSms), sms(creditSms)]);
      final importer = TransactionImportService(reader: reader);

      await importer.sync();
      final second = await importer.sync();
      final third = await importer.sync();

      expect(second.imported, 0);
      expect(second.duplicates, 2);
      expect(third.imported, 0);
      expect(await countRows(), 2);
    });

    test('a later sync over a superset of messages only adds the new ones',
        () async {
      final reader = FakeSmsReader([sms(debitSms)]);
      final importer = TransactionImportService(reader: reader);
      await importer.sync();

      reader.messages = [sms(debitSms), sms(creditSms)];
      final report = await importer.sync();

      expect(report.imported, 1);
      expect(report.duplicates, 1);
      expect(await countRows(), 2);
    });

    test('the identical message delivered twice yields one transaction',
        () async {
      final importer = TransactionImportService(
          reader: FakeSmsReader([sms(debitSms), sms(debitSms)]));

      final report = await importer.sync();

      expect(report.imported, 1);
      expect(await countRows(), 1);
    });

    test('the same payment announced by bank and by app is imported once',
        () async {
      final importer = TransactionImportService(
        reader: FakeSmsReader([
          sms('A/c XX8724 debited by Rs.250.00 on 15-01-26 '
              'UPI Ref 412345678901'),
          sms('You paid Rs.250.00 to MERCHANT via UPI. '
              'UPI transaction ID 412345678901', sender: 'VM-PHONEPE'),
        ]),
      );

      final report = await importer.sync();

      expect(report.imported, 1);
      expect(report.duplicates, 1);
    });

    test('two genuinely different payments of the same amount both survive',
        () async {
      final importer = TransactionImportService(
        reader: FakeSmsReader([
          sms('A/c XX8724 debited by Rs.50.00 on 15-01-26 Ref No 111111111111'),
          sms('A/c XX8724 debited by Rs.50.00 on 15-01-26 Ref No 222222222222'),
        ]),
      );

      final report = await importer.sync();

      expect(report.imported, 2);
      // They look alike, so both are surfaced for the user to confirm rather
      // than one being silently discarded.
      expect(report.flaggedForReview, greaterThanOrEqualTo(1));
    });

    test('non-financial messages are counted, not imported', () async {
      final importer = TransactionImportService(
        reader: FakeSmsReader([
          sms('123456 is your OTP. Do not share it with anyone.'),
          sms('You are pre-approved for a loan of Rs.5,00,000. Apply now!'),
          sms(debitSms),
        ]),
      );

      final report = await importer.sync();

      expect(report.imported, 1);
      expect(report.ignored, 2);
      expect(report.scanned, 3);
    });

    test('denied permission reports cleanly and writes nothing', () async {
      final importer = TransactionImportService(
          reader: FakeSmsReader([sms(debitSms)], granted: false));

      final report = await importer.sync();

      expect(report.permissionDenied, isTrue);
      expect(await countRows(), 0);
    });

    test('concurrent syncs do not double-import', () async {
      final importer =
          TransactionImportService(reader: FakeSmsReader([sms(debitSms), sms(creditSms)]));

      final results = await Future.wait([importer.sync(), importer.sync()]);

      expect(await countRows(), 2);
      // The second caller joined the run already in flight rather than starting
      // its own, so both see the same report.
      expect(results[0].imported, 2);
      expect(results[1].imported, 2);
    });
  });

  group('balance', () {
    test('is opening balance plus credits minus debits', () async {
      await db.setOpeningBalance('SBI', Money.parsePaise('10000')!);
      final importer =
          TransactionImportService(reader: FakeSmsReader([sms(debitSms), sms(creditSms)]));
      await importer.sync();

      // 10000 - 500 + 2000
      expect(await db.currentBalancePaise(), Money.parsePaise('11500'));
    });

    test('is unchanged by a repeated import', () async {
      final reader = FakeSmsReader([sms(debitSms), sms(creditSms)]);
      final importer = TransactionImportService(reader: reader);

      await importer.sync();
      final once = await db.currentBalancePaise();
      await importer.sync();
      await importer.sync();

      expect(await db.currentBalancePaise(), once);
    });

    test('excludes failed transactions', () async {
      final importer = TransactionImportService(
        reader: FakeSmsReader([
          sms(debitSms),
          sms('Your transaction of Rs.5,000.00 on Card XX4412 was declined '
              'due to insufficient funds. Ref 909090909090'),
        ]),
      );
      await importer.sync();

      expect(await countRows(), 2);
      expect(await db.currentBalancePaise(), Money.parsePaise('-500'));
    });

    test('a refund cancels out the expense it reverses', () async {
      final importer = TransactionImportService(
        reader: FakeSmsReader([
          sms('A/c XX8724 debited by Rs.1,200.00 on 15-01-26 Ref No 111111111111'),
          sms('Rs.1,200.00 has been refunded to your A/c XX8724 on 16-01-26 '
              'Ref No 222222222222'),
        ]),
      );
      await importer.sync();

      expect(await countRows(), 2);
      expect(await db.currentBalancePaise(), 0);
    });

    test('editing a transaction moves the balance immediately', () async {
      final importer = TransactionImportService(reader: FakeSmsReader([sms(debitSms)]));
      await importer.sync();

      final all = await db.getAllTransactions();
      await db.updateTransaction(all.first.copyWith(amountPaise: 70000));

      expect(await db.currentBalancePaise(), -70000);
    });

    test('deleting a transaction removes it from the balance', () async {
      final importer =
          TransactionImportService(reader: FakeSmsReader([sms(debitSms), sms(creditSms)]));
      await importer.sync();

      final all = await db.getAllTransactions();
      await db.deleteTransaction(all.firstWhere((t) => t.type == 'credit').id);

      expect(await db.currentBalancePaise(), -50000);
    });

    test('marking a failed transaction as real brings it into the balance',
        () async {
      final importer = TransactionImportService(
        reader: FakeSmsReader([
          sms('Rs.25.00 debit from A/c XX8724 failed. Ref No 333333333333'),
        ]),
      );
      await importer.sync();
      expect(await db.currentBalancePaise(), 0);

      final all = await db.getAllTransactions();
      await db.setTransactionStatus(all.first.id, TxnStatus.posted);

      expect(await db.currentBalancePaise(), -2500);
    });

    test('multiple accounts are summed and also reported separately', () async {
      await db.setOpeningBalance('SBI', 100000);
      await db.setOpeningBalance('BoB', 200000);

      final importer = TransactionImportService(
        reader: FakeSmsReader([
          sms(debitSms),
          sms('Rs.300.00 debited from A/c XX9999 on 15-01-26 '
              'Ref No 444444444444 -Bank of Baroda', sender: 'JD-BOBSMS'),
        ]),
      );
      await importer.sync();

      final byBank = await db.balanceByBankPaise();
      expect(byBank['SBI'], 100000 - 50000);
      expect(byBank['BoB'], 200000 - 30000);
      expect(await db.currentBalancePaise(), 220000);
    });
  });

  group('deleted transactions stay deleted', () {
    test('a deleted SMS transaction is not resurrected by the next sync',
        () async {
      final reader = FakeSmsReader([sms(debitSms), sms(creditSms)]);
      final importer = TransactionImportService(reader: reader);
      await importer.sync();

      final credit =
          (await db.getAllTransactions()).firstWhere((t) => t.type == 'credit');
      await db.deleteTransaction(credit.id);
      expect(await countRows(), 1);

      final report = await importer.sync();

      expect(await countRows(), 1);
      expect(report.suppressedByDelete, 1);
    });

    test('forgetting the tombstone allows a re-import', () async {
      final reader = FakeSmsReader([sms(debitSms)]);
      final importer = TransactionImportService(reader: reader);
      await importer.sync();

      final tx = (await db.getAllTransactions()).first;
      final fingerprint = tx.fingerprint!;
      await db.deleteTransaction(tx.id);
      await importer.sync();
      expect(await countRows(), 0);

      await db.forgetTombstone(fingerprint);
      await importer.sync();

      expect(await countRows(), 1);
    });

    test('clearing all data also clears tombstones', () async {
      final reader = FakeSmsReader([sms(debitSms)]);
      final importer = TransactionImportService(reader: reader);
      await importer.sync();
      await db.deleteTransaction((await db.getAllTransactions()).first.id);

      await db.clearAllTransactions();
      await importer.sync();

      expect(await countRows(), 1);
    });
  });

  group('manual entries are protected', () {
    test('an SMS import never overwrites a manual transaction', () async {
      await db.insertTransaction(TransactionModel(
        id: 'manual-1',
        amountPaise: 50000,
        type: 'debit',
        bankName: 'SBI',
        assignedTo: 'Me',
        category: 'Groceries',
        description: 'Vegetables',
        date: at,
        rawSmsText: 'Vegetables',
        source: TxnSource.manual,
      ));

      final importer = TransactionImportService(reader: FakeSmsReader([sms(debitSms)]));
      await importer.sync();

      final manual = (await db.getAllTransactions())
          .firstWhere((t) => t.id == 'manual-1');
      expect(manual.category, 'Groceries');
      expect(manual.description, 'Vegetables');
      expect(manual.source, TxnSource.manual);
    });

    test('two identical manual entries both persist', () async {
      for (var i = 0; i < 2; i++) {
        await db.insertTransaction(TransactionModel(
          id: 'manual-$i',
          amountPaise: 10000,
          type: 'debit',
          bankName: 'SBI',
          assignedTo: 'Me',
          category: 'Dining',
          description: 'Tea',
          // Different times, as two real purchases would be.
          date: at.add(Duration(hours: i)),
          rawSmsText: 'Tea',
        ));
      }
      expect(await countRows(), 2);
      expect(await db.currentBalancePaise(), -20000);
    });
  });

  group('statement imports', () {
    TransactionModel row(String desc, int paise, DateTime when) =>
        TransactionModel(
          id: '',
          amountPaise: paise,
          type: 'debit',
          bankName: 'SBI',
          assignedTo: 'Me',
          category: 'Other',
          description: desc,
          date: when,
          rawSmsText: desc,
          source: TxnSource.pdf,
        );

    test('every row is stored — blank ids no longer collide', () async {
      final rows = [
        row('SHOP A', 10000, DateTime(2026, 1, 2)),
        row('SHOP B', 20000, DateTime(2026, 1, 3)),
        row('SHOP C', 30000, DateTime(2026, 1, 4)),
      ];

      final added = await db.insertTransactionsBatch(rows);

      expect(added, 3);
      expect(await countRows(), 3);
    });

    test('genuinely duplicated statement rows are both kept', () async {
      final rows = [
        row('AUTO FARE', 5000, DateTime(2026, 1, 2)),
        row('AUTO FARE', 5000, DateTime(2026, 1, 2)),
      ];

      expect(await db.insertTransactionsBatch(rows), 2);
      expect(await db.currentBalancePaise(), -10000);
    });

    test('re-importing the same statement adds nothing', () async {
      final rows = [
        row('AUTO FARE', 5000, DateTime(2026, 1, 2)),
        row('AUTO FARE', 5000, DateTime(2026, 1, 2)),
        row('SHOP A', 10000, DateTime(2026, 1, 3)),
      ];

      await db.insertTransactionsBatch(rows);
      final second = await db.insertTransactionsBatch(rows);

      expect(second, 0);
      expect(await countRows(), 3);
    });
  });

  group('reconciliation', () {
    test('reports agreement once the opening balance is right', () async {
      // The debit SMS states an available balance of 9,500 after a 500 debit,
      // so the account must have opened at 10,000.
      await db.setOpeningBalance('SBI', Money.parsePaise('10000')!);
      final importer = TransactionImportService(reader: FakeSmsReader([sms(debitSms)]));
      await importer.sync();

      final results = await db.reconcile();
      final sbi = results.firstWhere((r) => r.bankName == 'SBI');

      expect(sbi.canCompare, isTrue);
      expect(sbi.isReconciled, isTrue);
      expect(sbi.differencePaise, 0);
    });

    test('reports the gap and explains it when a balance is missing', () async {
      final importer = TransactionImportService(reader: FakeSmsReader([sms(debitSms)]));
      await importer.sync();

      final sbi = (await db.reconcile()).firstWhere((r) => r.bankName == 'SBI');

      // Ledger says -500, bank says 9,500 — a 10,000 opening balance is missing.
      expect(sbi.calculatedPaise, -50000);
      expect(sbi.bankReportedPaise, 950000);
      expect(sbi.differencePaise, 1000000);
      expect(sbi.isReconciled, isFalse);
      expect(sbi.suggestedOpeningPaise, 1000000);
      expect(sbi.possibleReasons, isNotEmpty);
    });

    test('applying the suggested opening balance reconciles without touching '
        'any transaction', () async {
      final importer = TransactionImportService(reader: FakeSmsReader([sms(debitSms)]));
      await importer.sync();

      final before = await db.getAllTransactions();
      var sbi = (await db.reconcile()).firstWhere((r) => r.bankName == 'SBI');
      await db.setOpeningBalance('SBI', sbi.suggestedOpeningPaise);

      sbi = (await db.reconcile()).firstWhere((r) => r.bankName == 'SBI');
      final after = await db.getAllTransactions();

      expect(sbi.isReconciled, isTrue);
      expect(after.length, before.length);
      expect(after.first.amountPaise, before.first.amountPaise);
      expect(after.first.type, before.first.type);
    });

    test('a missing transaction shows up as a difference rather than being '
        'papered over', () async {
      await db.setOpeningBalance('SBI', Money.parsePaise('10000')!);
      final importer = TransactionImportService(reader: FakeSmsReader([sms(debitSms)]));
      await importer.sync();

      // The user deletes a transaction the bank still counted.
      await db.deleteTransaction((await db.getAllTransactions()).first.id);

      final results = await db.reconcile();
      // With no transactions left there is no anchor, so the mismatch is
      // reported as "cannot compare" rather than as a silent zero.
      expect(results.every((r) => !r.isReconciled), isTrue);
    });
  });

  group('background capture', () {
    test('drains the native queue into the ledger', () async {
      final queue = FakeNativeSmsQueue([
        QueuedSms(1, sms(debitSms)),
        QueuedSms(2, sms(creditSms)),
      ]);
      final importer = TransactionImportService(
          reader: FakeSmsReader(const []), nativeQueue: queue);

      final report = await importer.drainNativeQueue();

      expect(report!.imported, 2);
      expect(await countRows(), 2);
    });

    test('acknowledges only after the import has committed', () async {
      final queue = FakeNativeSmsQueue([QueuedSms(7, sms(debitSms))]);
      final importer = TransactionImportService(
          reader: FakeSmsReader(const []), nativeQueue: queue);

      await importer.drainNativeQueue();

      expect(queue.acknowledged, [7]);
      // The row existed before the acknowledgement was issued.
      expect(queue.rowsAtAcknowledge, 1);
    });

    test('a message left unacknowledged after a crash is not double-imported',
        () async {
      final message = sms(debitSms);
      final importer = TransactionImportService(
        reader: FakeSmsReader(const []),
        // Simulates the process dying between commit and acknowledge: the same
        // queue entry is still present on the next drain.
        nativeQueue: FakeNativeSmsQueue([QueuedSms(1, message)]),
      );
      await importer.drainNativeQueue();

      final retry = TransactionImportService(
        reader: FakeSmsReader(const []),
        nativeQueue: FakeNativeSmsQueue([QueuedSms(1, message)]),
      );
      final second = await retry.drainNativeQueue();

      expect(second!.imported, 0);
      expect(await countRows(), 1);
    });

    test('a captured message and the same message from the inbox scan produce '
        'one transaction', () async {
      final message = sms(debitSms);
      final importer = TransactionImportService(
        reader: FakeSmsReader([message]),
        nativeQueue: FakeNativeSmsQueue([QueuedSms(1, message)]),
      );

      await importer.drainNativeQueue();
      final scan = await importer.sync();

      expect(scan.imported, 0);
      expect(scan.duplicates, 1);
      expect(await countRows(), 1);
    });

    test('an empty queue is a no-op', () async {
      final importer = TransactionImportService(
          reader: FakeSmsReader(const []),
          nativeQueue: FakeNativeSmsQueue(const []));

      expect(await importer.drainNativeQueue(), isNull);
      expect(await countRows(), 0);
    });

    test('an unsupported platform is not an error', () async {
      final importer = TransactionImportService(
          reader: FakeSmsReader(const []),
          nativeQueue: FakeNativeSmsQueue(const [], supported: false));

      expect(await importer.drainNativeQueue(), isNull);
    });
  });

  group('audit trail', () {
    test('records an outcome for every message scanned', () async {
      final importer = TransactionImportService(
        reader: FakeSmsReader([
          sms(debitSms),
          sms('123456 is your OTP. Do not share.'),
          sms('Your A/c XX8724 txn could not be read by this parser at all '
              'because it has no amount.'),
        ]),
      );

      final report = await importer.sync();
      final summary = await db.getImportLogSummary();

      expect(summary.values.fold<int>(0, (a, b) => a + b), 3);
      expect(summary['imported'], 1);
      expect(report.scanned, 3);
    });

    test('last sync time and report survive a restart', () async {
      final importer = TransactionImportService(reader: FakeSmsReader([sms(debitSms)]));
      await importer.sync();

      await db.resetForTesting();

      final restored = await TransactionImportService(
              reader: FakeSmsReader(const []))
          .lastReport();
      expect(await db.lastSmsSyncAt(), isNotNull);
      expect(restored, isNotNull);
      expect(restored!.imported, 1);
    });
  });
}

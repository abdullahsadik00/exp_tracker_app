import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/transaction_model.dart';
import '../utils/money.dart';
import '../utils/stable_hash.dart';
import 'categorization_service.dart';
import 'sms_parser.dart';
import 'transaction_fingerprint.dart';
import 'dart:async';
import 'package:intl/intl.dart';

class LocalDbService {
  static final LocalDbService _instance = LocalDbService._internal();
  factory LocalDbService() => _instance;
  LocalDbService._internal();

  static LocalDbService get instance => _instance;

  static Database? _database;
  static Completer<Database>? _opening;

  /// SQL predicate shared by every balance-affecting aggregate. Failed and
  /// declined transactions are kept for audit but must never move the balance;
  /// expressing that rule in one constant is what keeps the many aggregate
  /// queries from drifting apart.
  static const String notFailed = "(status IS NULL OR status != 'failed')";

  static const String notTransfer = '(is_transfer IS NULL OR is_transfer != 1)';

  /// Opening the database is guarded so that two widgets building at the same
  /// time cannot each run `_initDb` and race the migration.
  Future<Database> get database async {
    if (_database != null) return _database!;
    if (_opening != null) return _opening!.future;

    final completer = Completer<Database>();
    _opening = completer;
    try {
      final db = await _initDb();
      _database = db;
      completer.complete(db);
    } catch (e, st) {
      _opening = null;
      completer.completeError(e, st);
    }
    return completer.future;
  }

  /// Closes and forgets the open database. Test-only: the service is a
  /// singleton with static state, so each test needs a clean slate.
  Future<void> resetForTesting() async {
    for (final query in _queries.values) {
      await query.dispose();
    }
    _queries.clear();
    await _database?.close();
    _database = null;
    _opening = null;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'expense_tracker.db');

    return await openDatabase(
      path,
      version: 6,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE transactions (
            id TEXT PRIMARY KEY,
            amount REAL,
            amount_paise INTEGER,
            type TEXT,
            bankName TEXT,
            assignedTo TEXT,
            category TEXT,
            date TEXT,
            rawSmsText TEXT,
            description TEXT,
            closingBalance REAL,
            notes TEXT,
            is_transfer INTEGER DEFAULT 0,
            source TEXT DEFAULT 'manual',
            fingerprint TEXT,
            merchant TEXT,
            reference_id TEXT,
            upi_txn_id TEXT,
            account_tail TEXT,
            sms_sender TEXT,
            status TEXT DEFAULT 'posted',
            txn_kind TEXT DEFAULT 'normal',
            needs_review INTEGER DEFAULT 0,
            review_reason TEXT,
            sms_balance_paise INTEGER,
            created_at TEXT,
            updated_at TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_date ON transactions (date)');
        await db.execute('CREATE INDEX idx_bank ON transactions (bankName)');
        await _createV6Objects(db);
        await _createFingerprintIndex(db);
        await db.execute('''
          CREATE TABLE budgets(
            category TEXT PRIMARY KEY,
            amount REAL
          )
        ''');
        await db.execute('''
          CREATE TABLE categorization_rules(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword TEXT NOT NULL,
            category TEXT,
            assigned_to TEXT,
            bank_name TEXT,
            priority INTEGER DEFAULT 100
          )
        ''');
        await _seedDefaultRules(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('CREATE INDEX IF NOT EXISTS idx_date ON transactions (date)');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_bank ON transactions (bankName)');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS budgets(
              category TEXT PRIMARY KEY,
              amount REAL
            )
          ''');
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS categorization_rules(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              keyword TEXT NOT NULL,
              category TEXT,
              assigned_to TEXT,
              bank_name TEXT,
              priority INTEGER DEFAULT 100
            )
          ''');
          final existing = await db.query('categorization_rules');
          if (existing.isEmpty) await _seedDefaultRules(db);
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE transactions ADD COLUMN is_transfer INTEGER DEFAULT 0');
          // Auto-mark existing manually-added Transfer category transactions
          await db.execute(
            "UPDATE transactions SET is_transfer = 1 WHERE category = 'Transfer'");
        }
        if (oldVersion < 6) {
          await _migrateToV6(db);
        }
      },
    );
  }

  // ─── Schema v6: provenance, deduplication and reconciliation ───────────────

  static const List<List<String>> _v6Columns = [
    ['amount_paise', 'INTEGER'],
    ['source', "TEXT DEFAULT 'manual'"],
    ['fingerprint', 'TEXT'],
    ['merchant', 'TEXT'],
    ['reference_id', 'TEXT'],
    ['upi_txn_id', 'TEXT'],
    ['account_tail', 'TEXT'],
    ['sms_sender', 'TEXT'],
    ['status', "TEXT DEFAULT 'posted'"],
    ['txn_kind', "TEXT DEFAULT 'normal'"],
    ['needs_review', 'INTEGER DEFAULT 0'],
    ['review_reason', 'TEXT'],
    ['sms_balance_paise', 'INTEGER'],
    ['created_at', 'TEXT'],
    ['updated_at', 'TEXT'],
  ];

  /// Tables and indexes introduced in v6. Shared by `onCreate` and `onUpgrade`
  /// so a fresh install and an upgraded install can never diverge.
  static Future<void> _createV6Objects(Database db) async {
    // Tombstones. Without these, deleting an SMS-imported transaction is
    // pointless: the next sync re-reads the same message and puts it straight
    // back. The fingerprint outlives the row.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS deleted_fingerprints(
        fingerprint TEXT PRIMARY KEY,
        deleted_at TEXT,
        note TEXT
      )
    ''');

    // Audit trail for every message the importer looked at, including the ones
    // it refused. "Nothing imported" must always be explainable.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sms_import_log(
        sms_hash TEXT PRIMARY KEY,
        sender TEXT,
        body TEXT,
        received_at TEXT,
        outcome TEXT,
        reason TEXT,
        txn_id TEXT,
        logged_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state(
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    // Opening balance per account, so the derived balance can be compared with
    // a real bank figure instead of always starting from zero.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS accounts(
        bank_name TEXT PRIMARY KEY,
        account_tail TEXT,
        opening_balance_paise INTEGER DEFAULT 0,
        opening_date TEXT,
        updated_at TEXT
      )
    ''');

    // Rows removed by the de-duplication pass are archived rather than dropped,
    // so a bad merge is always recoverable.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS merged_duplicates(
        id TEXT,
        fingerprint TEXT,
        payload TEXT,
        merged_at TEXT
      )
    ''');

    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_txn_status ON transactions (status)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_txn_source ON transactions (source)');
    // The unique fingerprint index is deliberately NOT created here. On an
    // upgrade this runs before the backfill, and the backfill's UPDATEs would
    // hit the constraint the moment two existing rows resolved to the same
    // fingerprint — which is exactly the case the migration exists to clean up.
    // Callers create it once the data is known to be unique.
  }

  /// The constraint that makes de-duplication a guarantee rather than a
  /// convention: no two rows may share a fingerprint. SQLite permits multiple
  /// NULLs, so rows that predate fingerprinting do not block it.
  static Future<void> _createFingerprintIndex(Database db) async {
    await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_txn_fingerprint '
        'ON transactions (fingerprint)');
  }

  static Future<void> _migrateToV6(Database db) async {
    final existing = await db.rawQuery('PRAGMA table_info(transactions)');
    final present = existing.map((c) => c['name'] as String).toSet();

    for (final col in _v6Columns) {
      if (present.contains(col[0])) continue;
      await db.execute('ALTER TABLE transactions ADD COLUMN ${col[0]} ${col[1]}');
    }

    // Move money onto the integer rail. ROUND before CAST because CAST
    // truncates and 8.2 * 100 is 819.9999999999999 in IEEE-754.
    await db.execute(
        'UPDATE transactions SET amount_paise = CAST(ROUND(amount * 100) AS INTEGER) '
        'WHERE amount_paise IS NULL');

    await db.execute("UPDATE transactions SET status = 'posted' WHERE status IS NULL");
    await db.execute("UPDATE transactions SET txn_kind = 'normal' WHERE txn_kind IS NULL");
    await db.execute('UPDATE transactions SET needs_review = 0 WHERE needs_review IS NULL');
    await db.execute('UPDATE transactions SET created_at = date WHERE created_at IS NULL');
    await db.execute('UPDATE transactions SET updated_at = date WHERE updated_at IS NULL');

    // Recover provenance from the id shapes the old code generated. This runs
    // over every row rather than only NULL ones, because `ADD COLUMN ... DEFAULT
    // 'manual'` has already backfilled the column — filtering on NULL here
    // would silently label every historic SMS import as manual. The CASE is
    // deterministic, so re-running it after an interrupted upgrade is a no-op.
    await db.execute('''
      UPDATE transactions SET source = CASE
        WHEN id LIKE 'sms\\_%' ESCAPE '\\' THEN 'sms'
        WHEN rawSmsText LIKE 'Excel Isol:%' THEN 'excel'
        ELSE 'manual'
      END
    ''');

    await _createV6Objects(db);
    await _backfillFingerprints(db);
    await _dedupeByFingerprint(db);

    // Only now is the column guaranteed unique, so the index can be enforced.
    await _createFingerprintIndex(db);
  }

  /// Gives every pre-existing row a fingerprint.
  ///
  /// This is the step that makes the first sync after upgrading safe: SMS rows
  /// are re-parsed from their stored body so they carry the same UPI/reference
  /// identity the importer will compute for the very same message, and are
  /// therefore recognised as already present instead of imported again.
  static Future<void> _backfillFingerprints(Database db) async {
    final rows = await db.query('transactions',
        columns: [
          'id', 'amount_paise', 'type', 'bankName', 'date', 'rawSmsText',
          'description', 'source', 'fingerprint',
        ],
        where: 'fingerprint IS NULL');
    if (rows.isEmpty) return;

    const parser = SmsParser();
    final batch = db.batch();
    // Counts identical field-tuples so genuinely duplicated statement rows keep
    // distinct fingerprints instead of being merged into one.
    final occurrences = <String, int>{};

    for (final row in rows) {
      final id = row['id'] as String? ?? '';
      final paise = (row['amount_paise'] as num?)?.toInt() ?? 0;
      final type = (row['type'] as String?) ?? 'debit';
      final bank = (row['bankName'] as String?) ?? 'SBI';
      final date = DateTime.tryParse((row['date'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final raw = (row['rawSmsText'] as String?) ?? '';
      final description = (row['description'] as String?) ?? '';
      final source = (row['source'] as String?) ?? TxnSource.manual;
      final isSms = source == TxnSource.sms;

      String? refId;
      String? upiId;
      String? tail;
      if (isSms && raw.isNotEmpty) {
        final parsed = parser.parse(body: raw, receivedAt: date);
        refId = parsed.referenceId;
        upiId = parsed.upiTransactionId;
        tail = parsed.accountTail;
      }

      final key = '$bank|$type|$paise|${date.toIso8601String()}|$description';
      final occurrence = occurrences[key] ?? 0;
      occurrences[key] = occurrence + 1;

      final fp = TransactionFingerprint.build(
        bank: bank,
        type: type,
        amountPaise: paise,
        dateTime: date,
        referenceId: refId,
        upiTransactionId: upiId,
        accountTail: tail,
        rawText: raw,
        description: description,
        allowBodyHash: isSms,
        occurrence: occurrence,
      );

      batch.update('transactions', {
        'fingerprint': fp,
        'reference_id': refId,
        'upi_txn_id': upiId,
        'account_tail': tail,
      }, where: 'id = ?', whereArgs: [id]);
    }

    await batch.commit(noResult: true);
  }

  /// Collapses rows that share a fingerprint, keeping the one that carries the
  /// most human curation.
  ///
  /// Losers are archived to `merged_duplicates` first — this runs unattended
  /// during an upgrade, so it must be reversible.
  static Future<void> _dedupeByFingerprint(Database db) async {
    final dupes = await db.rawQuery('''
      SELECT fingerprint FROM transactions
      WHERE fingerprint IS NOT NULL
      GROUP BY fingerprint HAVING COUNT(*) > 1
    ''');
    if (dupes.isEmpty) return;

    final now = DateTime.now().toIso8601String();
    int removed = 0;

    for (final d in dupes) {
      final fp = d['fingerprint'] as String;
      // A row the user has assigned to a person, categorised, annotated or
      // reviewed is worth more than an untouched auto-import.
      final rows = await db.rawQuery('''
        SELECT * FROM transactions WHERE fingerprint = ?
        ORDER BY
          (assignedTo IS NOT NULL AND assignedTo != 'Unassigned') DESC,
          (category IS NOT NULL AND category != 'Other') DESC,
          (notes IS NOT NULL AND notes != '') DESC,
          (is_transfer != 0) DESC,
          rowid ASC
      ''', [fp]);

      for (final loser in rows.skip(1)) {
        await db.insert('merged_duplicates', {
          'id': loser['id'],
          'fingerprint': fp,
          'payload': jsonEncode(loser),
          'merged_at': now,
        });
        await db.delete('transactions', where: 'id = ?', whereArgs: [loser['id']]);
        removed++;
      }
    }

    if (removed > 0) {
      await db.insert(
        'sync_state',
        {'key': 'v6_duplicates_merged', 'value': removed.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  static Future<void> _seedDefaultRules(Database db) async {
    final rules = <Map<String, dynamic>>[
      // Bank detection (priority 10)
      {'keyword': 'BARODA', 'bank_name': 'BoB', 'priority': 10},
      {'keyword': 'BARB',   'bank_name': 'BoB', 'priority': 10},
      {'keyword': 'BOB',    'bank_name': 'BoB', 'priority': 10},
      // Person assignment (priority 20)
      {'keyword': 'ABDULLAHSA', 'assigned_to': 'Me',  'priority': 20},
      {'keyword': 'NILOFAR',    'assigned_to': 'Mom', 'priority': 20},
      {'keyword': 'MOHD AAYAN', 'assigned_to': 'Dad', 'priority': 20},
      {'keyword': 'NAMDEO V',   'assigned_to': 'Dad', 'priority': 20},
      {'keyword': 'AQUIB AS',   'assigned_to': 'Dad', 'priority': 20},
      {'keyword': 'RAJAN HA',   'assigned_to': 'Dad', 'priority': 20},
      {'keyword': 'ABBU',       'assigned_to': 'Dad', 'priority': 20},
      {'keyword': 'MUBEEN M',   'assigned_to': 'Me',  'priority': 20},
      {'keyword': 'HEENA',      'assigned_to': 'Me',  'priority': 20},
      {'keyword': 'AMREEN',     'assigned_to': 'Me',  'priority': 20},
      {'keyword': 'IMRAN SH',   'assigned_to': 'Me',  'priority': 20},
      {'keyword': 'ALIABBAS',   'assigned_to': 'Me',  'priority': 20},
      {'keyword': 'YUNUS BA',   'assigned_to': 'Me',  'priority': 20},
      {'keyword': 'FAIZA FE',   'assigned_to': 'Me',  'priority': 20},
      {'keyword': 'ZAIN',       'assigned_to': 'Me',  'priority': 20},
      // Category rules (priority 30)
      {'keyword': 'BEE LOGICA',    'category': 'Salary',        'assigned_to': 'Me', 'priority': 30},
      {'keyword': 'INSUFFICIENT',  'category': 'Other',         'priority': 30},
      {'keyword': 'BSNL',          'category': 'Utilities',     'priority': 30},
      {'keyword': 'GOOGLE I',      'category': 'Utilities',     'priority': 30},
      {'keyword': 'AMAZON',        'category': 'Utilities',     'priority': 30},
      {'keyword': 'BAREERAH',      'category': 'Utilities',     'priority': 30},
      {'keyword': 'WIFI',          'category': 'Utilities',     'priority': 30},
      {'keyword': 'LIGHT',         'category': 'Utilities',     'priority': 30},
      {'keyword': 'ELECTRICITY',   'category': 'Utilities',     'priority': 30},
      {'keyword': 'DAWAT E',       'category': 'Gifts',         'priority': 30},
      {'keyword': 'DAWATEISLA',    'category': 'Gifts',         'priority': 30},
      {'keyword': 'SHADI',         'category': 'Gifts',         'priority': 30},
      {'keyword': 'WEDDING',       'category': 'Gifts',         'priority': 30},
      {'keyword': 'LAXMI',         'category': 'Gifts',         'priority': 30},
      {'keyword': 'MUKESH C',      'category': 'Groceries',     'priority': 30},
      {'keyword': 'PRAKASH',       'category': 'Groceries',     'priority': 30},
      {'keyword': 'BLINKIT',       'category': 'Groceries',     'priority': 30},
      {'keyword': 'JOHIRUL',       'category': 'Groceries',     'priority': 30},
      {'keyword': 'MAHENDRA',      'category': 'Groceries',     'priority': 30},
      {'keyword': 'MILAN SU',      'category': 'Groceries',     'priority': 30},
      {'keyword': 'JAGDISHC',      'category': 'Groceries',     'priority': 30},
      {'keyword': 'MAHA BAL',      'category': 'Groceries',     'priority': 30},
      {'keyword': 'HARIOM',        'category': 'Groceries',     'priority': 30},
      {'keyword': 'MILK',          'category': 'Groceries',     'priority': 30},
      {'keyword': 'DAHI',          'category': 'Groceries',     'priority': 30},
      {'keyword': 'EGG',           'category': 'Groceries',     'priority': 30},
      {'keyword': 'GROCE',         'category': 'Groceries',     'priority': 30},
      {'keyword': 'DMART',         'category': 'Groceries',     'priority': 30},
      {'keyword': 'PHYSIOMA',      'category': 'Healthcare',    'priority': 30},
      {'keyword': 'WELLNESS',      'category': 'Healthcare',    'priority': 30},
      {'keyword': 'RELAXSTA',      'category': 'Healthcare',    'priority': 30},
      {'keyword': 'MANTHAN',       'category': 'Healthcare',    'priority': 30},
      {'keyword': 'DR AMIR',       'category': 'Healthcare',    'priority': 30},
      {'keyword': 'MEDICAL',       'category': 'Healthcare',    'priority': 30},
      {'keyword': 'CLINIC',        'category': 'Healthcare',    'priority': 30},
      {'keyword': 'TAKWIM N',      'category': 'Dining',        'priority': 30},
      {'keyword': 'ISRAR BAIG',    'category': 'Dining',        'priority': 30},
      {'keyword': 'CHINNASA',      'category': 'Dining',        'priority': 30},
      {'keyword': 'SAMADHAN',      'category': 'Dining',        'priority': 30},
      {'keyword': 'CROWN BA',      'category': 'Dining',        'priority': 30},
      {'keyword': 'RESTAURANT',    'category': 'Dining',        'priority': 30},
      {'keyword': 'CAFE',          'category': 'Dining',        'priority': 30},
      {'keyword': 'TEA',           'category': 'Dining',        'priority': 30},
      {'keyword': 'SBIMOPS',       'category': 'Transfer',      'priority': 30},
      {'keyword': 'ATM',           'category': 'Transfer',      'priority': 30},
      {'keyword': 'SERAJ MU',      'category': 'Personal Care', 'priority': 30},
      {'keyword': 'AVENUE S',      'category': 'Personal Care', 'priority': 30},
      {'keyword': 'SALON',         'category': 'Personal Care', 'priority': 30},
      {'keyword': 'GYM',           'category': 'Personal Care', 'priority': 30},
      {'keyword': 'ROYAL SN',      'category': 'Entertainment', 'priority': 30},
      {'keyword': 'ANGEL LT',      'category': 'Investment',    'priority': 30},
      {'keyword': 'XEROX',         'category': 'Education',     'priority': 30},
      {'keyword': 'BOMBAY',        'category': 'Education',     'priority': 30},
      {'keyword': 'FLIPKART',      'category': 'Shopping',      'priority': 30},
      {'keyword': 'MEESHO',        'category': 'Shopping',      'priority': 30},
      {'keyword': 'SUPREME',       'category': 'Shopping',      'priority': 30},
      {'keyword': 'CAB',           'category': 'Transportation', 'priority': 30},
      {'keyword': 'AUTO',          'category': 'Transportation', 'priority': 30},
      {'keyword': 'RICK',          'category': 'Transportation', 'priority': 30},
    ];
    final batch = db.batch();
    for (final rule in rules) {
      batch.insert('categorization_rules', rule);
    }
    await batch.commit(noResult: true);
  }

  // ─── Categorization Rules CRUD ─────────────────────────────────────────────

  Future<List<CategorizationRule>> getCategorizationRules() async {
    final db = await database;
    final maps = await db.query('categorization_rules', orderBy: 'priority ASC, keyword ASC');
    return maps.map((m) => CategorizationRule.fromMap(m)).toList();
  }

  Future<void> insertCategorizationRule(CategorizationRule rule) async {
    final db = await database;
    await db.insert('categorization_rules', rule.toMap()..remove('id'));
    notifyChange();
  }

  Future<void> updateCategorizationRule(CategorizationRule rule) async {
    final db = await database;
    await db.update(
      'categorization_rules',
      rule.toMap(),
      where: 'id = ?',
      whereArgs: [rule.id],
    );
    notifyChange();
  }

  Future<void> deleteCategorizationRule(int id) async {
    final db = await database;
    await db.delete('categorization_rules', where: 'id = ?', whereArgs: [id]);
    notifyChange();
  }

  // ─── CRUD Methods ──────────────────────────────────────────────────────────

  /// Ensures a transaction carries a fingerprint before it reaches the table.
  ///
  /// Anything written without one bypasses the uniqueness guarantee, so this is
  /// applied on every write path rather than trusted to the callers.
  /// Also fills in an empty id, deriving it from the fingerprint. The PDF
  /// parser used to emit `id: ''` for every row, and since id is the primary
  /// key with an ignore-conflict insert, only the first row of a statement
  /// survived — the rest were dropped without a word.
  TransactionModel _withFingerprint(TransactionModel tx, {int occurrence = 0}) {
    if (tx.fingerprint != null && tx.fingerprint!.isNotEmpty) {
      return tx.id.isEmpty
          ? tx.copyWith(id: '${tx.source}_${stableHash(tx.fingerprint!)}')
          : tx;
    }
    final fingerprint = TransactionFingerprint.build(
      bank: tx.bankName,
      type: tx.type,
      amountPaise: tx.amountPaise,
      dateTime: tx.date,
      accountTail: tx.accountTail,
      referenceId: tx.referenceId,
      upiTransactionId: tx.upiTransactionId,
      rawText: tx.rawSmsText,
      description: tx.description,
      // Only a real message body is safe to hash; a manual entry's "raw text"
      // is the user's own description and two separate ₹100 "Tea" entries must
      // not collapse into one.
      allowBodyHash: tx.source == TxnSource.sms,
      occurrence: occurrence,
    );

    return tx.copyWith(
      fingerprint: fingerprint,
      id: tx.id.isEmpty ? '${tx.source}_${stableHash(fingerprint)}' : tx.id,
    );
  }

  Future<void> insertTransaction(TransactionModel transaction) async {
    final db = await database;
    final tx = _withFingerprint(transaction);
    await db.insert(
      'transactions',
      tx.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await syncLedgerBalances(tx.bankName);
    notifyChange();
  }

  /// Inserts many transactions, skipping any that already exist and any the
  /// user has previously deleted.
  ///
  /// Returns the number actually added. Idempotent: running it twice with the
  /// same input adds nothing the second time, because identity is decided by
  /// the unique `fingerprint` index rather than by a generated id.
  Future<int> insertTransactionsBatch(List<TransactionModel> transactions) async {
    final result = await insertTransactionsDetailed(transactions);
    return result.added;
  }

  Future<BatchInsertResult> insertTransactionsDetailed(
      List<TransactionModel> transactions) async {
    if (transactions.isEmpty) return const BatchInsertResult(0, 0, 0);
    final db = await database;

    // Disambiguate rows that are identical in every field within this batch —
    // a statement really can list two identical fares on one day.
    final occurrences = <String, int>{};
    final prepared = <TransactionModel>[];
    for (final tx in transactions) {
      final key = '${tx.bankName}|${tx.type}|${tx.amountPaise}|'
          '${tx.date.toIso8601String()}|${tx.description}';
      final n = occurrences[key] ?? 0;
      occurrences[key] = n + 1;
      prepared.add(_withFingerprint(tx, occurrence: n));
    }

    final tombstoned = await _tombstonedFingerprints(
        prepared.map((t) => t.fingerprint!).toList());

    int added = 0;
    int duplicates = 0;
    int suppressed = 0;
    final affectedBanks = <String>{};

    // One SQLite transaction: an interrupted import leaves either all of this
    // batch or none of it, never a half-written ledger.
    await db.transaction((txn) async {
      for (final tx in prepared) {
        if (tombstoned.contains(tx.fingerprint)) {
          suppressed++;
          continue;
        }
        final rowId = await txn.insert(
          'transactions',
          tx.toJson(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (rowId > 0) {
          added++;
          affectedBanks.add(tx.bankName);
        } else {
          duplicates++;
        }
      }
    });

    for (final bank in affectedBanks) {
      await syncLedgerBalances(bank);
    }
    if (added > 0 || suppressed > 0) notifyChange();
    return BatchInsertResult(added, duplicates, suppressed);
  }

  Future<Set<String>> _tombstonedFingerprints(List<String> fingerprints) async {
    if (fingerprints.isEmpty) return <String>{};
    final db = await database;
    final result = <String>{};
    // Chunked to stay well under SQLite's variable limit on large imports.
    const chunk = 400;
    for (var i = 0; i < fingerprints.length; i += chunk) {
      final slice = fingerprints.sublist(
          i, i + chunk > fingerprints.length ? fingerprints.length : i + chunk);
      final rows = await db.query(
        'deleted_fingerprints',
        columns: ['fingerprint'],
        where: 'fingerprint IN (${List.filled(slice.length, '?').join(',')})',
        whereArgs: slice,
      );
      result.addAll(rows.map((r) => r['fingerprint'] as String));
    }
    return result;
  }

  Future<TransactionModel?> findByFingerprint(String fingerprint) async {
    final db = await database;
    final rows = await db.query('transactions',
        where: 'fingerprint = ?', whereArgs: [fingerprint], limit: 1);
    if (rows.isEmpty) return null;
    return TransactionModel.fromJson(rows.first);
  }

  /// Finds transactions that look like the same movement as [tx] but carry a
  /// different fingerprint — same account, direction and amount within a few
  /// minutes.
  ///
  /// These are *not* auto-merged. Two ₹50 payments minutes apart are perfectly
  /// normal, so the importer flags them for review instead of guessing.
  Future<List<TransactionModel>> findSoftDuplicates(
    TransactionModel tx, {
    Duration window = const Duration(minutes: 5),
  }) async {
    final db = await database;
    final from = tx.date.subtract(window).toIso8601String();
    final to = tx.date.add(window).toIso8601String();
    final rows = await db.query(
      'transactions',
      where: 'amount_paise = ? AND type = ? AND bankName = ? '
          'AND date BETWEEN ? AND ? AND fingerprint != ?',
      whereArgs: [
        tx.amountPaise, tx.type, tx.bankName, from, to, tx.fingerprint ?? '',
      ],
    );
    return rows.map((r) => TransactionModel.fromJson(r)).toList();
  }

  Future<void> updateTransaction(TransactionModel transaction) async {
    final db = await database;

    // The bank may have been corrected during the edit. The *old* bank's
    // ledger has to be recomputed too, otherwise it keeps a running balance
    // that still includes a transaction it no longer owns.
    final before = await db.query('transactions',
        columns: ['bankName'], where: 'id = ?', whereArgs: [transaction.id]);
    final previousBank =
        before.isNotEmpty ? before.first['bankName'] as String? : null;

    final payload = transaction
        .copyWith(updatedAt: DateTime.now())
        .toJson()
      // An edit must never rewrite provenance timestamps.
      ..remove('created_at');

    await db.update(
      'transactions',
      payload,
      where: 'id = ?',
      whereArgs: [transaction.id],
    );

    await syncLedgerBalances(transaction.bankName);
    if (previousBank != null && previousBank != transaction.bankName) {
      await syncLedgerBalances(previousBank);
    }
    notifyChange();
  }

  /// Deletes a transaction and records a tombstone for its fingerprint.
  ///
  /// The tombstone is the whole point: without it the next SMS sync re-reads
  /// the same message, recomputes the same fingerprint, finds no matching row
  /// and cheerfully re-imports the transaction the user just removed.
  Future<void> deleteTransaction(String id, {bool tombstone = true}) async {
    final db = await database;
    final maps = await db.query(
      'transactions',
      columns: ['bankName', 'fingerprint', 'source'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return;

    final bankName = maps.first['bankName'] as String?;
    final fingerprint = maps.first['fingerprint'] as String?;

    await db.transaction((txn) async {
      if (tombstone && fingerprint != null && fingerprint.isNotEmpty) {
        await txn.insert(
          'deleted_fingerprints',
          {
            'fingerprint': fingerprint,
            'deleted_at': DateTime.now().toIso8601String(),
            'note': 'deleted by user',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.delete('transactions', where: 'id = ?', whereArgs: [id]);
    });

    if (bankName != null) {
      await syncLedgerBalances(bankName);
    }
    notifyChange();
  }

  /// Lets a previously deleted transaction be imported again on the next sync.
  Future<void> forgetTombstone(String fingerprint) async {
    final db = await database;
    await db.delete('deleted_fingerprints',
        where: 'fingerprint = ?', whereArgs: [fingerprint]);
    notifyChange();
  }

  Future<int> tombstoneCount() async {
    final db = await database;
    final r = await db
        .rawQuery('SELECT COUNT(*) as c FROM deleted_fingerprints');
    return (r.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<List<TransactionModel>> getAllTransactions() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('transactions', orderBy: 'date DESC');

    return List.generate(maps.length, (i) {
      return TransactionModel.fromJson(maps[i]);
    });
  }

  // New specific query methods to replace Firebase ones
  Future<List<TransactionModel>> getUnassignedTransactions() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'transactions',
      where: 'assignedTo = ?',
      whereArgs: ['Unassigned'],
      orderBy: 'date DESC',
    );
    return maps.map((m) => TransactionModel.fromJson(m)).toList();
  }

  Future<List<TransactionModel>> getRecentTransactions({int limit = 3}) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'transactions',
      orderBy: 'date DESC',
      limit: limit,
    );
    return maps.map((m) => TransactionModel.fromJson(m)).toList();
  }

  Future<Map<String, double>> getDashboardStatsOptimized() async {
    final db = await database;
    final now = DateTime.now();
    final monthStr = DateFormat('yyyy-MM').format(now);
    
    final Map<String, double> stats = {
      'total_income': 0.0,
      'total_expense': 0.0,
      'me_sbi_expense': 0.0,
      'me_sbi_income': 0.0,
      'me_bob_expense': 0.0,
      'me_bob_income': 0.0,
      'mom_flow': 0.0,
      'dad_flow': 0.0,
      'sbi_balance': 0.0,
      'bob_balance': 0.0,
      'balance': 0.0,
    };

    // 1. All-time balance per account, summed in integer paise and seeded with
    //    the per-account opening balances. The headline total is derived from
    //    these two and nothing else, so it cannot drift from the cards under
    //    it — and Mom's and Dad's spending, which comes out of these same two
    //    accounts, is never added on top.
    final byBank = await balanceByBankPaise();
    stats['sbi_balance'] = Money.toDouble(byBank['SBI'] ?? 0);
    stats['bob_balance'] = Money.toDouble(byBank['BoB'] ?? 0);
    stats['balance'] = ownAccounts.fold(
        0.0, (sum, bank) => sum + Money.toDouble(byBank[bank] ?? 0));

    // 2. Current Month Totals (exclude confirmed transfers and failed txns)
    final monthTotals = await db.rawQuery('''
      SELECT
        SUM(CASE WHEN type = 'credit' THEN amount_paise ELSE 0 END) as income,
        SUM(CASE WHEN type = 'debit' THEN amount_paise ELSE 0 END) as expense
      FROM transactions
      WHERE date LIKE '$monthStr%' AND $notTransfer AND $notFailed
    ''');
    stats['total_income'] =
        Money.toDouble((monthTotals.first['income'] as num?)?.toInt() ?? 0);
    stats['total_expense'] =
        Money.toDouble((monthTotals.first['expense'] as num?)?.toInt() ?? 0);

    // 3. Person specific flow (Monthly, exclude transfers)
    final personFlows = await db.rawQuery('''
      SELECT assignedTo, SUM(CASE WHEN type = 'credit' THEN amount_paise ELSE -amount_paise END) as flow
      FROM transactions
      WHERE date LIKE ? AND assignedTo IN ('Mom', 'Dad')
        AND $notTransfer AND $notFailed
      GROUP BY assignedTo
    ''', ['$monthStr%']);
    for (var row in personFlows) {
      final flow = Money.toDouble((row['flow'] as num?)?.toInt() ?? 0);
      if (row['assignedTo'] == 'Mom') stats['mom_flow'] = flow;
      if (row['assignedTo'] == 'Dad') stats['dad_flow'] = flow;
    }

    // 4. Me specific Bank flows (Monthly, exclude transfers)
    final bankFlows = await db.rawQuery('''
      SELECT bankName, type, SUM(amount_paise) as total
      FROM transactions
      WHERE date LIKE ? AND assignedTo = 'Me' AND bankName IN ('SBI', 'BoB')
        AND $notTransfer AND $notFailed
      GROUP BY bankName, type
    ''', ['$monthStr%']);
    for (var row in bankFlows) {
      final bank = row['bankName'];
      final type = row['type'];
      final val = Money.toDouble((row['total'] as num?)?.toInt() ?? 0);
      
      if (bank == 'SBI') {
        if (type == 'credit') stats['me_sbi_income'] = val;
        else stats['me_sbi_expense'] = val;
      } else if (bank == 'BoB') {
        if (type == 'credit') stats['me_bob_income'] = val;
        else stats['me_bob_expense'] = val;
      }
    }

    return stats;
  }

  Future<List<TransactionModel>> getTransactionsByMonth(String monthYear) async {
    final db = await database;
    final date = DateFormat('MMM yyyy').parse(monthYear);
    final sqlDate = DateFormat('yyyy-MM').format(date);
    
    final List<Map<String, dynamic>> maps = await db.query(
      'transactions',
      where: "date LIKE ?",
      whereArgs: ['$sqlDate%'],
      orderBy: 'date DESC',
    );
    return maps.map((m) => TransactionModel.fromJson(m)).toList();
  }

  Future<List<String>> getAvailableMonths() async {
    final db = await database;
    final List<Map<String, dynamic>> results = await db.rawQuery('''
      SELECT DISTINCT SUBSTR(date, 1, 7) as month FROM transactions ORDER BY month DESC
    ''');
    
    final List<String> months = [];
    for (var row in results) {
      final monthStr = row['month'] as String;
      final date = DateFormat('yyyy-MM').parse(monthStr);
      months.add(DateFormat('MMM yyyy').format(date));
    }
    
    final currentMonth = DateFormat('MMM yyyy').format(DateTime.now());
    if (!months.contains(currentMonth)) {
      months.insert(0, currentMonth);
    }
    
    return months;
  }

  Future<List<TransactionModel>> getFilteredTransactions({
    String? assignedTo,
    String? bankName,
    String? monthYear,
    String? category,
  }) async {
    final db = await database;
    List<String> whereClauses = [];
    List<dynamic> whereArgs = [];

    if (assignedTo != null && assignedTo != 'All') {
      whereClauses.add('assignedTo = ?');
      whereArgs.add(assignedTo);
    }

    if (bankName != null && bankName != 'All') {
      whereClauses.add('bankName = ?');
      whereArgs.add(bankName);
    }

    if (monthYear != null && monthYear != 'All Time') {
      final date = DateFormat('MMM yyyy').parse(monthYear);
      final sqlDate = DateFormat('yyyy-MM').format(date);
      whereClauses.add('date LIKE ?');
      whereArgs.add('$sqlDate%');
    }

    if (category != null && category != 'All Categories') {
      whereClauses.add('category = ?');
      whereArgs.add(category);
    }

    String? whereString = whereClauses.isEmpty ? null : whereClauses.join(' AND ');

    final List<Map<String, dynamic>> maps = await db.query(
      'transactions',
      where: whereString,
      whereArgs: whereArgs,
      orderBy: 'date DESC',
    );
    return maps.map((m) => TransactionModel.fromJson(m)).toList();
  }

  /// Recomputes the running ledger balance for one bank.
  ///
  /// This is a full recompute from the account's opening balance rather than an
  /// incremental patch from `fromDate`. The incremental version had two ways to
  /// go wrong that both produced a permanently skewed ledger: it seeded itself
  /// from a neighbouring row's `closingBalance` (so one bad value propagated
  /// forever), and `ORDER BY date` alone is not a total order — statement
  /// imports routinely give several rows the same timestamp, and SQLite was
  /// free to order those differently on each run. Ordering by `date, id` makes
  /// the result deterministic.
  ///
  /// Cost is linear in one bank's transactions, which is a few thousand rows at
  /// most; correctness is worth more than the saved milliseconds here.
  Future<void> syncLedgerBalances(String bankName) async {
    final db = await database;

    int running = await openingBalancePaise(bankName);

    final maps = await db.query(
      'transactions',
      columns: ['id', 'type', 'amount_paise', 'status', 'closingBalance'],
      where: 'bankName = ?',
      whereArgs: [bankName],
      orderBy: 'date ASC, id ASC',
    );
    if (maps.isEmpty) return;

    final batch = db.batch();
    for (final map in maps) {
      final status = map['status'] as String?;
      final paise = (map['amount_paise'] as num?)?.toInt() ?? 0;
      // Failed transactions appear in the list but move no money.
      if (status != TxnStatus.failed) {
        running += (map['type'] == 'credit') ? paise : -paise;
      }
      final rupees = Money.toDouble(running);
      final current = (map['closingBalance'] as num?)?.toDouble();
      if (current == null || (current - rupees).abs() > 0.001) {
        batch.update('transactions', {'closingBalance': rupees},
            where: 'id = ?', whereArgs: [map['id']]);
      }
    }
    await batch.commit(noResult: true);
  }

  /// Recomputes every bank's ledger. Used after restores and bulk edits, where
  /// working out exactly which banks moved is more error-prone than redoing all.
  Future<void> syncAllLedgers() async {
    final db = await database;
    final banks = await db
        .rawQuery('SELECT DISTINCT bankName FROM transactions WHERE bankName IS NOT NULL');
    for (final b in banks) {
      await syncLedgerBalances(b['bankName'] as String);
    }
  }

  Future<void> saveBudget(String category, double amount) async {
    final db = await database;
    await db.insert(
      'budgets',
      {'category': category, 'amount': amount},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyChange();
  }

  Future<void> deleteBudget(String category) async {
    final db = await database;
    await db.delete(
      'budgets',
      where: 'category = ?',
      whereArgs: [category],
    );
    notifyChange();
  }

  Future<List<Map<String, dynamic>>> getBudgetProgress() async {
    final db = await database;
    final now = DateTime.now();
    final monthStr = DateFormat('yyyy-MM').format(now);

    // Get all budgets
    final List<Map<String, dynamic>> budgets = await db.query('budgets');
    
    // Get spending per category for current month
    final List<Map<String, dynamic>> spending = await db.rawQuery('''
      SELECT category, SUM(amount) as total
      FROM transactions
      WHERE date LIKE ? AND type = 'debit'
        AND $notTransfer AND $notFailed
      GROUP BY category
    ''', ['$monthStr%']);

    Map<String, double> spendingMap = {
      for (var row in spending) row['category'] as String: (row['total'] as num).toDouble()
    };

    return budgets.map((b) {
      final category = b['category'] as String;
      final limit = (b['amount'] as num).toDouble();
      final spent = spendingMap[category] ?? 0.0;
      return {
        'category': category,
        'limit': limit,
        'spent': spent,
      };
    }).toList();
  }

  Future<double?> getCategoryBudget(String category) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'budgets',
      where: 'category = ?',
      whereArgs: [category],
    );
    if (maps.isNotEmpty) return (maps.first['amount'] as num).toDouble();
    return null;
  }

  // ── Smart Intelligence ──────────────────────────────────────────────────────

  /// Returns the 3-month average monthly spend for a category (excluding current month).
  Future<double> getCategoryAverage(String category) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT AVG(monthly) as avg FROM (
        SELECT strftime('%Y-%m', date) as m, SUM(amount) as monthly
        FROM transactions
        WHERE type = 'debit' AND category = ?
          AND date >= date('now', '-4 months')
          AND strftime('%Y-%m', date) != strftime('%Y-%m', 'now')
          AND $notTransfer AND $notFailed
        GROUP BY m
      )
    ''', [category]);
    return (result.first['avg'] as num?)?.toDouble() ?? 0.0;
  }

  /// Returns categories where this month's spend is ≥ 1.5× the 3-month average.
  Future<List<Map<String, dynamic>>> getSpendingAnomalies() async {
    final db = await database;
    final monthStr = DateFormat('yyyy-MM').format(DateTime.now());

    final currentRows = await db.rawQuery('''
      SELECT category, SUM(amount) as current_amount
      FROM transactions
      WHERE type = 'debit' AND date LIKE ?
        AND $notTransfer AND $notFailed
      GROUP BY category
    ''', ['$monthStr%']);

    final avgRows = await db.rawQuery('''
      SELECT category, AVG(monthly) as avg_amount FROM (
        SELECT category, strftime('%Y-%m', date) as m, SUM(amount) as monthly
        FROM transactions
        WHERE type = 'debit'
          AND date >= date('now', '-4 months')
          AND strftime('%Y-%m', date) != ?
          AND $notTransfer AND $notFailed
        GROUP BY category, m
      )
      GROUP BY category
    ''', [monthStr]);

    final avgMap = <String, double>{
      for (final r in avgRows)
        r['category'] as String: (r['avg_amount'] as num?)?.toDouble() ?? 0.0,
    };

    final anomalies = <Map<String, dynamic>>[];
    for (final row in currentRows) {
      final cat = row['category'] as String;
      final current = (row['current_amount'] as num).toDouble();
      final avg = avgMap[cat] ?? 0.0;
      if (avg > 200 && current >= avg * 1.5) {
        anomalies.add({
          'category': cat,
          'currentAmount': current,
          'avgAmount': avg,
          'ratio': current / avg,
        });
      }
    }
    anomalies.sort((a, b) => (b['ratio'] as double).compareTo(a['ratio'] as double));
    return anomalies;
  }

  /// Projects end-of-month spend based on daily burn rate so far.
  Future<Map<String, dynamic>> getMonthEndForecast() async {
    final db = await database;
    final now = DateTime.now();
    final monthStr = DateFormat('yyyy-MM').format(now);
    final daysElapsed = now.day;
    final totalDays = DateTime(now.year, now.month + 1, 0).day;

    final result = await db.rawQuery('''
      SELECT SUM(amount) as current_spend
      FROM transactions
      WHERE type = 'debit' AND date LIKE '$monthStr%'
        AND $notTransfer AND $notFailed
    ''');
    final currentSpend = (result.first['current_spend'] as num?)?.toDouble() ?? 0.0;
    final forecastedSpend = daysElapsed > 0 ? (currentSpend / daysElapsed) * totalDays : 0.0;

    final budgetsResult = await db.rawQuery('SELECT SUM(amount) as total FROM budgets');
    final totalBudget = (budgetsResult.first['total'] as num?)?.toDouble() ?? 0.0;

    return {
      'currentSpend': currentSpend,
      'forecastedSpend': forecastedSpend,
      'daysElapsed': daysElapsed,
      'totalDays': totalDays,
      'totalBudget': totalBudget,
    };
  }

  // ── Transfer Detection ───────────────────────────────────────────────────────

  /// Returns candidate transfer pairs: same amount, opposite type, different banks, within 48h.
  Future<List<Map<String, dynamic>>> getPotentialTransferPairs() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT
        t1.id        AS debit_id,
        t1.amount    AS amount,
        t1.bankName  AS from_bank,
        t1.date      AS debit_date,
        t1.description AS debit_desc,
        t2.id        AS credit_id,
        t2.bankName  AS to_bank,
        t2.date      AS credit_date,
        t2.description AS credit_desc
      FROM transactions t1
      INNER JOIN transactions t2 ON (
        t1.amount_paise = t2.amount_paise
        AND t2.type = 'credit'
        AND t1.bankName != t2.bankName
        AND ABS(julianday(t1.date) - julianday(t2.date)) <= 2.0
        AND (t2.is_transfer IS NULL OR t2.is_transfer = 0)
      )
      WHERE t1.type = 'debit'
        AND (t1.is_transfer IS NULL OR t1.is_transfer = 0)
        AND t1.date >= date('now', '-3 months')
      ORDER BY t1.date DESC
      LIMIT 20
    ''');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Marks both legs of a transfer pair as confirmed (is_transfer = 1).
  Future<void> confirmTransferPair(String debitId, String creditId) async {
    final db = await database;
    await db.rawUpdate(
      "UPDATE transactions SET is_transfer = 1, category = 'Transfer' WHERE id IN (?, ?)",
      [debitId, creditId],
    );
    notifyChange();
  }

  /// Marks both legs as dismissed (is_transfer = -1) so they won't appear again.
  Future<void> dismissTransferPair(String debitId, String creditId) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE transactions SET is_transfer = -1 WHERE id IN (?, ?)',
      [debitId, creditId],
    );
    notifyChange();
  }

  Stream<List<Map<String, dynamic>>> get potentialTransferPairsStream =>
      _streamOf('potentialTransferPairs', getPotentialTransferPairs);

  /// Finds descriptions that appear as debits in 3+ distinct months over the last 6 months.
  Future<List<Map<String, dynamic>>> getRecurringPatterns() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT
        description,
        category,
        COUNT(DISTINCT strftime('%Y-%m', date)) AS month_count,
        ROUND(AVG(amount), 2) AS avg_amount,
        MAX(date) AS last_seen
      FROM transactions
      WHERE type = 'debit' AND date >= date('now', '-6 months') AND $notFailed
      GROUP BY LOWER(description)
      HAVING month_count >= 3
      ORDER BY avg_amount DESC
      LIMIT 30
    ''');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<Map<String, double>> getYearlySpendingTrend() async {
    final db = await database;
    Map<String, double> trend = {};
    
    for (int i = 11; i >= 0; i--) {
      final date = DateTime(DateTime.now().year, DateTime.now().month - i, 1);
      final monthStr = DateFormat('yyyy-MM').format(date);
      final monthKey = DateFormat('MMM').format(date);
      
      final result = await db.rawQuery('''
        SELECT SUM(amount) as total FROM transactions
        WHERE date LIKE '$monthStr%' AND type = 'debit'
          AND $notTransfer AND $notFailed
      ''');
      
      trend[monthKey] = (result.first['total'] as num?)?.toDouble() ?? 0.0;
    }
    return trend;
  }

  // Backup & Restore
  Future<void> backupDatabase() async {
    final txns = await getAllTransactions();
    final jsonString = jsonEncode(txns.map((t) => t.toJson()).toList());
    
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/backup_${DateTime.now().millisecondsSinceEpoch}.json');
    await file.writeAsString(jsonString);

    await Share.shareXFiles([XFile(file.path)], text: 'Expense Tracker Backup');
  }

  Future<void> restoreDatabase(String jsonString) async {
    final db = await database;
    dynamic decoded = jsonDecode(jsonString);
    
    Map<String, dynamic> targetData = {};
    if (decoded is Map) {
      if (decoded.containsKey('transactions')) {
        targetData = Map<String, dynamic>.from(decoded['transactions']);
      } else {
        targetData = Map<String, dynamic>.from(decoded);
      }
    } else if (decoded is List) {
      // In case it's already a list (our own backup format)
      for (var item in decoded) {
        if (item is Map) {
          final id = item['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString();
          targetData[id] = item;
        }
      }
    }

    await db.transaction((txn) async {
      // Wiping table is removed to allow merging/upsert
      for (var entry in targetData.entries) {
        try {
          var txMap = Map<String, dynamic>.from(entry.value);
          // If ID is missing, use the map key (Firebase push ID)
          if (!txMap.containsKey('id') || txMap['id'] == null || txMap['id'] == '') {
            txMap['id'] = entry.key;
          }
          
          // Older backups predate fingerprints; compute one on the way in so
          // restored rows still participate in de-duplication.
          TransactionModel tx = _withFingerprint(TransactionModel.fromJson(txMap));
          await txn.insert('transactions', tx.toJson(), conflictAlgorithm: ConflictAlgorithm.replace);
        } catch (e) {
          print('Failed to restore transaction ${entry.key}: $e');
        }
      }
    });

    // A backup can contain any bank, not just the two the app started with.
    await syncAllLedgers();
    notifyChange();
  }

  /// Wipes the transaction table.
  ///
  /// Tombstones go with it: after a deliberate "clear everything", the user
  /// expects the next sync to rebuild from scratch, and leaving the tombstones
  /// behind would permanently suppress every transaction they had ever deleted.
  Future<void> clearAllTransactions() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('transactions');
      await txn.delete('deleted_fingerprints');
      await txn.delete('sms_import_log');
      await txn.delete('sync_state', where: 'key != ?', whereArgs: ['v6_duplicates_merged']);
    });
    notifyChange();
  }

  // To support fire-and-forget sync or reactivity, we can add a StreamController
  final _changeController = StreamController<void>.broadcast();
  Stream<void> get onChange => _changeController.stream;

  void notifyChange() => _changeController.add(null);

  /// One [_SharedQuery] per query, so a query is owned by the service rather
  /// than by whichever widget happened to ask for it first.
  final Map<String, dynamic> _queries = {};

  /// The stream for [key], creating it on first use.
  ///
  /// The stream is multi-subscription, so handing the same query to two widgets
  /// — or hoisting it into a `State` field and listening again after a rebuild —
  /// can never re-listen to one subscription. What the callers share is the
  /// single underlying fetch and its last result: one change notification means
  /// one database read, however many widgets are watching.
  Stream<T> _streamOf<T>(String key, Future<T> Function() fetch) =>
      (_queries.putIfAbsent(key, () => _SharedQuery<T>(fetch, onChange))
              as _SharedQuery<T>)
          .stream;

  Stream<List<TransactionModel>> getAllTransactionsStream() =>
      _streamOf('allTransactions', getAllTransactions);

  Stream<Map<String, double>> get dashboardStatsStream =>
      _streamOf('dashboardStats', getDashboardStatsOptimized);

  Stream<List<TransactionModel>> get unassignedTransactionsStream =>
      _streamOf('unassignedTransactions', getUnassignedTransactions);

  Stream<List<TransactionModel>> get recentTransactionsStream =>
      _streamOf('recentTransactions', () => getRecentTransactions(limit: 3));

  Stream<List<Map<String, dynamic>>> get budgetProgressStream =>
      _streamOf('budgetProgress', getBudgetProgress);

  Stream<List<String>> get availableMonthsStream =>
      _streamOf('availableMonths', getAvailableMonths);

  Stream<Map<String, double>> get yearlySpendingTrendStream =>
      _streamOf('yearlySpendingTrend', getYearlySpendingTrend);

  Stream<List<CategorizationRule>> get categorizationRulesStream =>
      _streamOf('categorizationRules', getCategorizationRules);

  Stream<List<Map<String, dynamic>>> get anomaliesStream =>
      _streamOf('anomalies', getSpendingAnomalies);

  Stream<Map<String, dynamic>> get forecastStream =>
      _streamOf('forecast', getMonthEndForecast);

  Stream<List<Map<String, dynamic>>> get recurringPatternsStream =>
      _streamOf('recurringPatterns', getRecurringPatterns);
  
  // Bulk Update Bank
  Future<void> bulkUpdateBank(Set<String> txIds, String newBank) async {
    if (txIds.isEmpty) return;
    final db = await database;
    final ids = txIds.toList();
    final placeholders = List.filled(ids.length, '?').join(',');

    // Capture the banks losing these transactions before the update, so their
    // ledgers get recomputed too. Only syncing the destination bank left every
    // source bank with a running balance that still counted the moved rows.
    final before = await db.rawQuery(
      'SELECT DISTINCT bankName FROM transactions WHERE id IN ($placeholders)',
      ids,
    );
    final affected = before
        .map((r) => r['bankName'] as String?)
        .whereType<String>()
        .toSet()
      ..add(newBank);

    await db.transaction((txn) async {
      await txn.update(
        'transactions',
        {'bankName': newBank, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
    });

    for (final bank in affected) {
      await syncLedgerBalances(bank);
    }
    notifyChange();
  }

  // Bulk Update AssignedTo
  Future<void> bulkUpdateAssignedTo(Set<String> txIds, String newAssignedTo) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var id in txIds) {
        await txn.update(
          'transactions',
          {'assignedTo': newAssignedTo},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
    notifyChange();
  }

  // Bulk Delete Transactions
  Future<void> bulkDeleteTransactions(Set<String> txIds,
      {bool tombstone = true}) async {
    if (txIds.isEmpty) return;
    final db = await database;
    final ids = txIds.toList();
    final placeholders = List.filled(ids.length, '?').join(',');

    // Identify affected banks and fingerprints before deleting
    final maps = await db.query(
      'transactions',
      columns: ['bankName', 'fingerprint'],
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );

    final affectedBanks =
        maps.map((m) => m['bankName'] as String?).whereType<String>().toSet();
    final fingerprints =
        maps.map((m) => m['fingerprint'] as String?).whereType<String>().toList();
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      if (tombstone) {
        for (final fp in fingerprints) {
          await txn.insert(
            'deleted_fingerprints',
            {'fingerprint': fp, 'deleted_at': now, 'note': 'bulk delete'},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await txn.delete(
        'transactions',
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
    });

    for (var bank in affectedBanks) {
      await syncLedgerBalances(bank);
    }
    notifyChange();
  }

  Future<void> updateTransactionTimeAndSync(List<TransactionModel> reorderedTxns, String bankName) async {
    final db = await database;
    Batch batch = db.batch();
    for (int i = 0; i < reorderedTxns.length; i++) {
      var tx = reorderedTxns[i];
      DateTime newDate = DateTime(tx.date.year, tx.date.month, tx.date.day, 23, 59 - i, 0);
      batch.update('transactions', {'date': newDate.toIso8601String()}, where: 'id = ?', whereArgs: [tx.id]);
    }
    await batch.commit(noResult: true);
    await syncLedgerBalances(bankName);
    notifyChange();
  }

  // ── Opening balances ────────────────────────────────────────────────────────

  /// The balance an account held before the first transaction the app knows
  /// about. Without it, a derived balance can only ever be a *net change*, and
  /// comparing that against a real bank balance is meaningless.
  Future<int> openingBalancePaise(String bankName) async {
    final db = await database;
    final rows = await db.query('accounts',
        columns: ['opening_balance_paise'],
        where: 'bank_name = ?',
        whereArgs: [bankName],
        limit: 1);
    if (rows.isEmpty) return 0;
    return (rows.first['opening_balance_paise'] as num?)?.toInt() ?? 0;
  }

  Future<int> totalOpeningBalancePaise() async {
    final db = await database;
    final r = await db
        .rawQuery('SELECT SUM(opening_balance_paise) as total FROM accounts');
    return (r.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<void> setOpeningBalance(String bankName, int paise,
      {DateTime? openingDate}) async {
    final db = await database;
    await db.insert(
      'accounts',
      {
        'bank_name': bankName,
        'opening_balance_paise': paise,
        'opening_date': openingDate?.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // The whole ledger for that bank shifts by the delta.
    await syncLedgerBalances(bankName);
    notifyChange();
  }

  Future<List<Map<String, dynamic>>> getAccounts() async {
    final db = await database;
    return (await db.query('accounts', orderBy: 'bank_name ASC'))
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  // ── Balance derivation ──────────────────────────────────────────────────────

  /// The one true balance: opening balances plus every non-failed transaction,
  /// summed as integers.
  ///
  /// Nothing in the app stores a balance that it later mutates — every figure
  /// on screen comes back through here, which is what makes an edit, an import
  /// and a delete all take effect immediately and identically.
  Future<int> currentBalancePaise() async {
    final db = await database;
    final r = await db.rawQuery('''
      SELECT SUM(CASE WHEN type = 'credit' THEN amount_paise ELSE -amount_paise END) as total
      FROM transactions WHERE $notFailed
    ''');
    final movement = (r.first['total'] as num?)?.toInt() ?? 0;
    return await totalOpeningBalancePaise() + movement;
  }

  /// The only two accounts that actually hold money. Me, Mom and Dad are people
  /// transacting *within* these accounts, not accounts of their own.
  static const List<String> ownAccounts = ['SBI', 'BoB'];

  /// The headline balance: what the two real accounts hold, all-time.
  ///
  /// Deliberately not the same as [currentBalancePaise], which sums every bank
  /// the ledger has ever seen. Mom's and Dad's spending already leaves one of
  /// these two accounts, so adding a per-person figure on top would count the
  /// same rupees twice.
  Future<int> ownAccountsBalancePaise() async {
    final byBank = await balanceByBankPaise();
    return ownAccounts.fold<int>(0, (sum, bank) => sum + (byBank[bank] ?? 0));
  }

  Future<Map<String, int>> balanceByBankPaise() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT bankName,
             SUM(CASE WHEN type = 'credit' THEN amount_paise ELSE -amount_paise END) as total
      FROM transactions WHERE $notFailed
      GROUP BY bankName
    ''');
    final result = <String, int>{};
    for (final r in rows) {
      final bank = r['bankName'] as String? ?? 'Unknown';
      result[bank] = (r['total'] as num?)?.toInt() ?? 0;
    }
    for (final acc in await getAccounts()) {
      final bank = acc['bank_name'] as String;
      final opening = (acc['opening_balance_paise'] as num?)?.toInt() ?? 0;
      result[bank] = (result[bank] ?? 0) + opening;
    }
    return result;
  }

  // ── Sync state ──────────────────────────────────────────────────────────────

  static const String kLastSmsSyncAt = 'last_sms_sync_at';
  static const String kLastSmsSyncReport = 'last_sms_sync_report';

  /// Last time messages captured by the Android broadcast receiver were
  /// drained. Tracked separately from a full inbox scan so the sync screen can
  /// show that background capture is actually working.
  static const String kLastSmsCaptureAt = 'last_sms_capture_at';

  /// Records that the SMS permission has been asked for since RECEIVE_SMS was
  /// added to the manifest, so the request happens exactly once rather than on
  /// every launch.
  static const String kSmsPermissionPrompted = 'sms_permission_prompted_v2';

  Future<String?> getSyncState(String key) async {
    final db = await database;
    final rows = await db
        .query('sync_state', where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setSyncState(String key, String value) async {
    final db = await database;
    await db.insert('sync_state', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<DateTime?> lastSmsSyncAt() async {
    final v = await getSyncState(kLastSmsSyncAt);
    return v == null ? null : DateTime.tryParse(v);
  }

  Future<DateTime?> lastSmsCaptureAt() async {
    final v = await getSyncState(kLastSmsCaptureAt);
    return v == null ? null : DateTime.tryParse(v);
  }

  // ── SMS import audit log ────────────────────────────────────────────────────

  /// Records what happened to each message. Written in one batch so a crash
  /// mid-import cannot leave the log claiming a transaction was imported when
  /// the insert never committed.
  Future<void> writeImportLog(List<Map<String, dynamic>> entries) async {
    if (entries.isEmpty) return;
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final batch = db.batch();
    for (final e in entries) {
      batch.insert(
        'sms_import_log',
        {...e, 'logged_at': now},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Messages the parser could not turn into a transaction, newest first.
  /// These are shown to the user rather than discarded — an unreadable format
  /// is the most likely cause of a reconciliation gap.
  Future<List<Map<String, dynamic>>> getUnparsedMessages({int limit = 100}) async {
    final db = await database;
    final rows = await db.query(
      'sms_import_log',
      where: 'outcome = ?',
      whereArgs: ['unparsed'],
      orderBy: 'received_at DESC',
      limit: limit,
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<Map<String, int>> getImportLogSummary() async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT outcome, COUNT(*) as c FROM sms_import_log GROUP BY outcome');
    return {
      for (final r in rows)
        (r['outcome'] as String? ?? 'unknown'): (r['c'] as num).toInt()
    };
  }

  // ── Review queue ────────────────────────────────────────────────────────────

  Future<List<TransactionModel>> getNeedsReviewTransactions() async {
    final db = await database;
    final rows = await db.query('transactions',
        where: 'needs_review = 1', orderBy: 'date DESC');
    return rows.map((r) => TransactionModel.fromJson(r)).toList();
  }

  Future<int> needsReviewCount() async {
    final db = await database;
    final r = await db.rawQuery(
        'SELECT COUNT(*) as c FROM transactions WHERE needs_review = 1');
    return (r.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<void> resolveReview(String id) async {
    final db = await database;
    await db.update(
      'transactions',
      {
        'needs_review': 0,
        'review_reason': null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyChange();
  }

  /// Flips a transaction between counted and not-counted.
  ///
  /// Used when the user knows better than the parser — e.g. a "declined" alert
  /// that did in fact levy a charge. The balance follows automatically because
  /// it is derived, never stored.
  Future<void> setTransactionStatus(String id, String status) async {
    final db = await database;
    final rows = await db.query('transactions',
        columns: ['bankName'], where: 'id = ?', whereArgs: [id], limit: 1);
    await db.update(
      'transactions',
      {'status': status, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isNotEmpty) {
      await syncLedgerBalances(rows.first['bankName'] as String);
    }
    notifyChange();
  }

  // ── Reconciliation ──────────────────────────────────────────────────────────

  /// Compares the derived ledger against the balance the bank itself stated in
  /// its most recent SMS, per account.
  ///
  /// Deliberately read-only. A mismatch is evidence that a transaction is
  /// missing, duplicated or miscategorised — quietly nudging numbers to agree
  /// would destroy exactly the signal the user needs.
  Future<List<ReconciliationResult>> reconcile() async {
    final db = await database;

    final banks = await db.rawQuery(
        'SELECT DISTINCT bankName FROM transactions WHERE bankName IS NOT NULL');

    final unparsed = (await getImportLogSummary())['unparsed'] ?? 0;
    final reviewCount = await needsReviewCount();

    final results = <ReconciliationResult>[];
    for (final b in banks) {
      final bank = b['bankName'] as String;

      // The anchor is the newest transaction whose SMS quoted a balance. Its
      // own `closingBalance` is the derived ledger at exactly that point, so
      // the two figures are directly comparable with no extra summation.
      final anchorRows = await db.query(
        'transactions',
        where: 'bankName = ? AND sms_balance_paise IS NOT NULL AND $notFailed',
        whereArgs: [bank],
        orderBy: 'date DESC, id DESC',
        limit: 1,
      );

      final openingPaise = await openingBalancePaise(bank);

      if (anchorRows.isEmpty) {
        results.add(ReconciliationResult(
          bankName: bank,
          openingPaise: openingPaise,
          calculatedPaise: (await balanceByBankPaise())[bank] ?? 0,
          bankReportedPaise: null,
          asOf: null,
          unparsedMessages: unparsed,
          needsReviewCount: reviewCount,
        ));
        continue;
      }

      final anchor = anchorRows.first;
      final reported = (anchor['sms_balance_paise'] as num).toInt();
      final derivedRupees = (anchor['closingBalance'] as num?)?.toDouble();
      final derived =
          derivedRupees == null ? null : Money.fromDouble(derivedRupees);

      results.add(ReconciliationResult(
        bankName: bank,
        openingPaise: openingPaise,
        calculatedPaise: derived ?? 0,
        bankReportedPaise: reported,
        asOf: DateTime.tryParse((anchor['date'] ?? '').toString()),
        unparsedMessages: unparsed,
        needsReviewCount: reviewCount,
        hasAnchor: derived != null,
      ));
    }

    return results;
  }

  Stream<List<ReconciliationResult>> get reconciliationStream =>
      _streamOf('reconciliation', reconcile);

  Stream<List<TransactionModel>> get needsReviewStream =>
      _streamOf('needsReview', getNeedsReviewTransactions);
}

/// One query, one subscription to `onChange`, any number of widgets.
///
/// The old shape gave every widget its own `async*` generator, so a single
/// change re-ran the same SQL once per widget on screen, and any attempt to
/// share or re-listen to one of those generators threw "Stream has already been
/// listened to". Here the fetch and its result live in one place: subscribers
/// get a cheap per-caller view of it, and the database is read once per change
/// no matter how many of them there are.
class _SharedQuery<T> {
  _SharedQuery(this._fetch, Stream<void> changes) {
    _out = StreamController<T>.broadcast(
      onListen: () => _changeSub ??= changes.listen((_) => _refreshQuietly()),
      // Nobody is watching, so stop watching for changes too — that is what
      // keeps a closed screen from holding a live subscription. The cached
      // value is kept but marked stale, so the next subscriber re-reads rather
      // than painting whatever was true when the screen was closed.
      onCancel: () {
        _changeSub?.cancel();
        _changeSub = null;
        _stale = true;
      },
    );
  }

  final Future<T> Function() _fetch;
  late final StreamController<T> _out;
  StreamSubscription<void>? _changeSub;

  T? _last;
  bool _hasLast = false;
  bool _stale = false;

  /// In-flight fetch, so a burst of `notifyChange()` — an import commits one
  /// per batch — collapses into a single query instead of one per call.
  Future<T>? _inFlight;

  /// A multi-subscription stream: listening to the *same* stream object twice
  /// is allowed, which is the whole point. Each subscriber is seeded with the
  /// current value and then relays the shared one, so no caller can find itself
  /// holding a stream that has already been listened to.
  Stream<T> get stream => Stream<T>.multi((controller) {
        var delivered = false;

        final relay = _out.stream.listen(
          (value) {
            delivered = true;
            controller.add(value);
          },
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = relay.cancel;

        if (_hasLast && !_stale) {
          delivered = true;
          controller.add(_last as T);
        } else {
          // The relay above delivers the result to everyone watching; this only
          // covers the case where the fetch settled before the relay attached.
          _refresh().then(
            (value) {
              if (!delivered && !controller.isClosed) {
                delivered = true;
                controller.add(value);
              }
            },
            onError: (Object e, StackTrace st) {
              if (!controller.isClosed) controller.addError(e, st);
            },
          );
        }
      });

  Future<T> _refresh() => _inFlight ??= _run();

  Future<T> _run() async {
    try {
      final value = await _fetch();
      _last = value;
      _hasLast = true;
      _stale = false;
      if (!_out.isClosed && _out.hasListener) _out.add(value);
      return value;
    } catch (e, st) {
      if (!_out.isClosed && _out.hasListener) _out.addError(e, st);
      rethrow;
    } finally {
      _inFlight = null;
    }
  }

  /// Refresh driven by a change notification rather than by a subscriber: the
  /// error has already gone out through [_out], so it must not also surface as
  /// an unhandled future error.
  void _refreshQuietly() {
    _refresh().then((_) {}, onError: (Object _, StackTrace __) {});
  }

  Future<void> dispose() async {
    await _changeSub?.cancel();
    _changeSub = null;
    await _out.close();
  }
}

/// Outcome of a batch insert. Distinguishing "already had it" from "user had
/// deleted it" matters: the first is normal, the second is why an expected
/// transaction is missing.
class BatchInsertResult {
  final int added;
  final int duplicates;
  final int suppressedByTombstone;

  const BatchInsertResult(this.added, this.duplicates, this.suppressedByTombstone);

  int get total => added + duplicates + suppressedByTombstone;
}

/// A per-account comparison of the derived balance against the bank's own
/// reported figure.
class ReconciliationResult {
  final String bankName;
  final int openingPaise;
  final int calculatedPaise;
  final int? bankReportedPaise;
  final DateTime? asOf;
  final int unparsedMessages;
  final int needsReviewCount;
  final bool hasAnchor;

  const ReconciliationResult({
    required this.bankName,
    required this.openingPaise,
    required this.calculatedPaise,
    required this.bankReportedPaise,
    required this.asOf,
    this.unparsedMessages = 0,
    this.needsReviewCount = 0,
    this.hasAnchor = false,
  });

  bool get canCompare => bankReportedPaise != null && hasAnchor;

  /// Positive means the bank holds more than the transactions explain.
  int get differencePaise =>
      canCompare ? bankReportedPaise! - calculatedPaise : 0;

  /// A one-paisa tolerance absorbs nothing — the arithmetic is exact — but it
  /// keeps rows imported from rounded statement values from nagging.
  bool get isReconciled => canCompare && differencePaise.abs() <= 1;

  /// The opening balance that would make the ledger agree with the bank.
  ///
  /// Offered as a suggestion the user applies explicitly. It is legitimate
  /// because an opening balance is real missing data, unlike a fudge factor
  /// bolted onto the displayed total.
  int get suggestedOpeningPaise => openingPaise + differencePaise;

  List<String> get possibleReasons {
    if (!canCompare) {
      return [
        'No bank-reported balance found yet for $bankName. Sync SMS, or add an '
            'opening balance so the derived total can be compared.',
      ];
    }
    if (isReconciled) return const [];

    final reasons = <String>[];
    if (openingPaise == 0) {
      reasons.add(
          'No opening balance is set for $bankName, so the ledger starts at ₹0 '
          'and only reflects transactions the app has seen.');
    }
    if (differencePaise > 0) {
      reasons.add(
          'The bank holds more than the recorded transactions explain — a '
          'credit is likely missing (cash deposit, interest, or an SMS that '
          'could not be parsed).');
    } else {
      reasons.add(
          'The recorded transactions account for more money than the bank '
          'holds — a transaction may be recorded twice, or an expense was '
          'entered that never went through.');
    }
    if (unparsedMessages > 0) {
      reasons.add(
          '$unparsedMessages message(s) could not be parsed and may contain '
          'the missing transaction.');
    }
    if (needsReviewCount > 0) {
      reasons.add(
          '$needsReviewCount transaction(s) are flagged for review and may be '
          'wrong or duplicated.');
    }
    return reasons;
  }
}

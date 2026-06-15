import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/transaction_model.dart';
import 'categorization_service.dart';
import 'dart:async';
import 'package:intl/intl.dart';

class LocalDbService {
  static final LocalDbService _instance = LocalDbService._internal();
  factory LocalDbService() => _instance;
  LocalDbService._internal();

  static LocalDbService get instance => _instance;

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'expense_tracker.db');

    return await openDatabase(
      path,
      version: 4,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE transactions (
            id TEXT PRIMARY KEY,
            amount REAL,
            type TEXT,
            bankName TEXT,
            assignedTo TEXT,
            category TEXT,
            date TEXT,
            rawSmsText TEXT,
            description TEXT,
            closingBalance REAL,
            notes TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_date ON transactions (date)');
        await db.execute('CREATE INDEX idx_bank ON transactions (bankName)');
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
      },
    );
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
  Future<void> insertTransaction(TransactionModel transaction) async {
    final db = await database;
    await db.insert(
      'transactions',
      transaction.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await syncLedgerBalances(transaction.bankName, fromDate: transaction.date);
    notifyChange();
  }

  Future<int> insertTransactionsBatch(List<TransactionModel> transactions) async {
    if (transactions.isEmpty) return 0;
    final db = await database;
    int addedCount = 0;
    Set<String> affectedBanks = {};

    await db.transaction((txn) async {
      for (var tx in transactions) {
        final rowId = await txn.insert(
          'transactions',
          tx.toJson(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (rowId > 0) addedCount++;
        affectedBanks.add(tx.bankName);
      }
    });

    for (var bank in affectedBanks) {
      await syncLedgerBalances(bank);
    }
    notifyChange();
    return addedCount;
  }

  Future<void> updateTransaction(TransactionModel transaction) async {
    final db = await database;
    await db.update(
      'transactions',
      transaction.toJson(),
      where: 'id = ?',
      whereArgs: [transaction.id],
    );
    await syncLedgerBalances(transaction.bankName, fromDate: transaction.date);
    notifyChange();
  }

  Future<void> deleteTransaction(String id) async {
    final db = await database;
    // Get bankName before deleting for sync
    final List<Map<String, dynamic>> maps = await db.query(
      'transactions',
      columns: ['bankName'],
      where: 'id = ?',
      whereArgs: [id],
    );
    
    String? bankName;
    if (maps.isNotEmpty) {
      bankName = maps.first['bankName'] as String;
    }

    await db.delete(
      'transactions',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (bankName != null) {
      await syncLedgerBalances(bankName);
    }
    notifyChange();
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
      'balance': 0.0,
    };

    // 1. All-time balance
    final balanceResult = await db.rawQuery(
      "SELECT SUM(CASE WHEN type = 'credit' THEN amount ELSE -amount END) as total FROM transactions"
    );
    stats['balance'] = (balanceResult.first['total'] as num?)?.toDouble() ?? 0.0;

    // 2. Current Month Totals
    final monthTotals = await db.rawQuery('''
      SELECT 
        SUM(CASE WHEN type = 'credit' THEN amount ELSE 0 END) as income,
        SUM(CASE WHEN type = 'debit' THEN amount ELSE 0 END) as expense
      FROM transactions 
      WHERE date LIKE '$monthStr%'
    ''');
    stats['total_income'] = (monthTotals.first['income'] as num?)?.toDouble() ?? 0.0;
    stats['total_expense'] = (monthTotals.first['expense'] as num?)?.toDouble() ?? 0.0;

    // 3. Person specific flow (Monthly)
    final personFlows = await db.rawQuery('''
      SELECT assignedTo, SUM(CASE WHEN type = 'credit' THEN amount ELSE -amount END) as flow
      FROM transactions 
      WHERE date LIKE '$monthStr%' AND assignedTo IN ('Mom', 'Dad')
      GROUP BY assignedTo
    ''');
    for (var row in personFlows) {
      if (row['assignedTo'] == 'Mom') stats['mom_flow'] = (row['flow'] as num?)?.toDouble() ?? 0.0;
      if (row['assignedTo'] == 'Dad') stats['dad_flow'] = (row['flow'] as num?)?.toDouble() ?? 0.0;
    }

    // 4. Me specific Bank flows (Monthly)
    final bankFlows = await db.rawQuery('''
      SELECT bankName, type, SUM(amount) as total
      FROM transactions 
      WHERE date LIKE '$monthStr%' AND assignedTo = 'Me' AND bankName IN ('SBI', 'BoB')
      GROUP BY bankName, type
    ''');
    for (var row in bankFlows) {
      final bank = row['bankName'];
      final type = row['type'];
      final val = (row['total'] as num?)?.toDouble() ?? 0.0;
      
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

  Future<void> syncLedgerBalances(String bankName, {DateTime? fromDate}) async {
    final db = await database;
    
    // 1. Get starting balance if fromDate is provided
    double runningBalance = 0.0;
    String queryWhere = 'bankName = ?';
    List<dynamic> queryArgs = [bankName];
    
    if (fromDate != null) {
      final prevResult = await db.rawQuery('''
        SELECT closingBalance FROM transactions 
        WHERE bankName = ? AND date < ? 
        ORDER BY date DESC LIMIT 1
      ''', [bankName, fromDate.toIso8601String()]);
      
      if (prevResult.isNotEmpty) {
        runningBalance = (prevResult.first['closingBalance'] as num?)?.toDouble() ?? 0.0;
      }
      queryWhere += ' AND date >= ?';
      queryArgs.add(fromDate.toIso8601String());
    }

    // 2. Fetch only affected transactions
    final List<Map<String, dynamic>> maps = await db.query(
      'transactions', 
      where: queryWhere, 
      whereArgs: queryArgs, 
      orderBy: 'date ASC'
    );
    
    if (maps.isEmpty) return;

    Batch batch = db.batch();
    bool hasUpdates = false;
    
    for (var map in maps) {
      TransactionModel tx = TransactionModel.fromJson(map);
      runningBalance += (tx.type == 'credit' ? tx.amount : -tx.amount);
      if (tx.closingBalance != runningBalance) {
        batch.update('transactions', {'closingBalance': runningBalance}, where: 'id = ?', whereArgs: [tx.id]);
        hasUpdates = true;
      }
    }
    await batch.commit(noResult: true);
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
      WHERE date LIKE '$monthStr%' AND type = 'debit'
      GROUP BY category
    ''');

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
      WHERE type = 'debit' AND date LIKE '$monthStr%'
      GROUP BY category
    ''');

    final avgRows = await db.rawQuery('''
      SELECT category, AVG(monthly) as avg_amount FROM (
        SELECT category, strftime('%Y-%m', date) as m, SUM(amount) as monthly
        FROM transactions
        WHERE type = 'debit'
          AND date >= date('now', '-4 months')
          AND strftime('%Y-%m', date) != '$monthStr'
        GROUP BY category, m
      )
      GROUP BY category
    ''');

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
      WHERE type = 'debit' AND date >= date('now', '-6 months')
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
          
          TransactionModel tx = TransactionModel.fromJson(txMap);
          await txn.insert('transactions', tx.toJson(), conflictAlgorithm: ConflictAlgorithm.replace);
        } catch (e) {
          print('Failed to restore transaction ${entry.key}: $e');
        }
      }
    });

    // Re-sync specific banks after restore to ensure math is correct
    await syncLedgerBalances('SBI');
    await syncLedgerBalances('BoB');
    notifyChange();
  }

  Future<void> clearAllTransactions() async {
    final db = await database;
    await db.delete('transactions');
    notifyChange();
  }

  // To support fire-and-forget sync or reactivity, we can add a StreamController
  final _changeController = StreamController<void>.broadcast();
  Stream<void> get onChange => _changeController.stream;

  void notifyChange() => _changeController.add(null);

  Stream<List<TransactionModel>> getAllTransactionsStream() async* {
    yield await getAllTransactions();
    await for (final _ in onChange) {
      yield await getAllTransactions();
    }
  }

  Stream<T> _streamOf<T>(Future<T> Function() fetch) async* {
    yield await fetch();
    await for (final _ in onChange) {
      yield await fetch();
    }
  }

  Stream<Map<String, double>> get dashboardStatsStream =>
      _streamOf(getDashboardStatsOptimized);

  Stream<List<TransactionModel>> get unassignedTransactionsStream =>
      _streamOf(getUnassignedTransactions);

  Stream<List<TransactionModel>> get recentTransactionsStream =>
      _streamOf(() => getRecentTransactions(limit: 3));

  Stream<List<Map<String, dynamic>>> get budgetProgressStream =>
      _streamOf(getBudgetProgress);

  Stream<List<String>> get availableMonthsStream =>
      _streamOf(getAvailableMonths);

  Stream<Map<String, double>> get yearlySpendingTrendStream =>
      _streamOf(getYearlySpendingTrend);

  Stream<List<CategorizationRule>> get categorizationRulesStream =>
      _streamOf(getCategorizationRules);

  Stream<List<Map<String, dynamic>>> get anomaliesStream =>
      _streamOf(getSpendingAnomalies);

  Stream<Map<String, dynamic>> get forecastStream =>
      _streamOf(getMonthEndForecast);

  Stream<List<Map<String, dynamic>>> get recurringPatternsStream =>
      _streamOf(getRecurringPatterns);
  
  // Bulk Update Bank
  Future<void> bulkUpdateBank(Set<String> txIds, String newBank) async {
    final db = await database;
    await db.transaction((txn) async {
      for (var id in txIds) {
        await txn.update(
          'transactions',
          {'bankName': newBank},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
    await syncLedgerBalances(newBank);
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
  Future<void> bulkDeleteTransactions(Set<String> txIds) async {
    final db = await database;
    
    // Identify affected banks before deleting
    final List<Map<String, dynamic>> maps = await db.query(
      'transactions',
      columns: ['bankName'],
      where: 'id IN (${txIds.map((_) => '?').join(',')})',
      whereArgs: txIds.toList(),
    );
    
    final Set<String> affectedBanks = maps.map((m) => m['bankName'] as String).toSet();

    await db.transaction((txn) async {
      await txn.delete(
        'transactions',
        where: 'id IN (${txIds.map((_) => '?').join(',')})',
        whereArgs: txIds.toList(),
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
}

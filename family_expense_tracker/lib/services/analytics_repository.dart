import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';

import '../utils/money.dart';
import 'local_db_service.dart';

/// The single source of truth for every number the Analytics tab shows.
///
/// Before this existed the same "how much did we spend" question was answered
/// three different ways — raw Dart filtering in the widget, `notTransfer +
/// notFailed` in SQL, and a service that filtered neither — so the headline
/// total could not be reconciled with the chart directly beneath it. In a money
/// app that is not a polish problem: one number disagreeing with another costs
/// the user their trust in all of them.
///
/// Everything here is therefore built from the shared predicates below, and the
/// screen loads one [AnalyticsSnapshot] per (month, revision) rather than
/// letting six independent streams each answer with their own definition.
class AnalyticsRepository {
  AnalyticsRepository([LocalDbService? db])
      : _service = db ?? LocalDbService.instance;

  final LocalDbService _service;

  /// The people a transaction can be attributed to. `Unassigned` is a real
  /// member here, not an absence — spending nobody has tagged is still spending,
  /// and hiding it is how a total silently loses money.
  static const List<String> members = ['Me', 'Mom', 'Dad', 'Unassigned'];

  // ── Canonical predicates ────────────────────────────────────────────────────
  // Every aggregate in this file is composed from these. Nothing else in the
  // app should hand-roll a spending filter.

  /// Confirmed transfers are money moving between our own accounts. Both legs
  /// are excluded from every figure. Unreviewed (0) and dismissed (-1) count as
  /// real transactions.
  static const String notTransfer = '(is_transfer IS NULL OR is_transfer != 1)';

  /// A failed transaction never moved money. Excluded everywhere, silently.
  static const String notFailed = "(status IS NULL OR status != 'failed')";

  static const String notTransferCategory =
      "(category IS NULL OR category != 'Transfer')";

  /// Legacy rows predate `amount_paise`, so fall back to the REAL column rather
  /// than silently summing NULLs to zero.
  static const String paise =
      'COALESCE(amount_paise, CAST(ROUND(amount * 100) AS INTEGER))';

  /// Rows that participate in an expense figure: debits, plus the refunds and
  /// reversals that give money back against them.
  static const String expenseRows = '$notTransfer AND $notFailed AND '
      '$notTransferCategory AND '
      "(type = 'debit' OR (type = 'credit' AND txn_kind IN ('refund', 'reversal')))";

  /// Debits add, refunds and reversals subtract. A ₹2,000 purchase refunded in
  /// full is ₹0 of spending, not ₹2,000 of spending and ₹2,000 of income.
  static const String signedExpense =
      "SUM(CASE WHEN type = 'debit' THEN $paise ELSE -$paise END)";

  /// Income is only ever reported in the income view. It is never netted
  /// against a spending total.
  static const String incomeRows = "type = 'credit' AND $notTransfer AND "
      "$notFailed AND (txn_kind IS NULL OR txn_kind NOT IN ('refund', 'reversal'))";

  // ── Month keys ──────────────────────────────────────────────────────────────
  // 'yyyy-MM' is the storage and comparison form; 'MMM yyyy' is display only.

  static String ymOf(DateTime d) => DateFormat('yyyy-MM').format(d);

  static String labelOf(String ym) =>
      DateFormat('MMMM yyyy').format(DateFormat('yyyy-MM').parse(ym));

  static String shortLabelOf(String ym) =>
      DateFormat('MMM yyyy').format(DateFormat('yyyy-MM').parse(ym));

  static String monthNameOf(String ym) =>
      DateFormat('MMMM').format(DateFormat('yyyy-MM').parse(ym));

  static String _shift(String ym, int months) {
    final d = DateFormat('yyyy-MM').parse(ym);
    return ymOf(DateTime(d.year, d.month + months, 1));
  }

  /// Months that have transactions, newest first, with the current month always
  /// present so a fresh install still has something to select.
  Future<List<String>> availableMonths() async {
    final db = await _service.database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT SUBSTR(date, 1, 7) AS ym FROM transactions '
      'WHERE date IS NOT NULL ORDER BY ym DESC',
    );
    final months = <String>[
      for (final r in rows)
        if ((r['ym'] as String?)?.length == 7) r['ym'] as String,
    ];
    final current = ymOf(DateTime.now());
    if (!months.contains(current)) months.insert(0, current);
    return months;
  }

  // ── The snapshot ────────────────────────────────────────────────────────────

  /// Loads every figure the Analytics screen shows, for one month, in one pass.
  ///
  /// One snapshot means one loading state, one error state, and — the point of
  /// the exercise — one set of numbers that agree with each other.
  Future<AnalyticsSnapshot> load(String ym) async {
    final db = await _service.database;
    final now = DateTime.now();
    final currentYm = ymOf(now);
    final isCurrent = ym == currentYm;

    final monthStart = DateFormat('yyyy-MM').parse(ym);
    final daysInMonth = DateTime(monthStart.year, monthStart.month + 1, 0).day;
    final daysElapsed = isCurrent ? now.day : daysInMonth;

    final prevYm = _shift(ym, -1);

    final spent = await _expenseTotal(db, ym);
    // Compare like with like: an in-progress month is measured against the same
    // stretch of the previous one, not against its finished total.
    final prevComparable = isCurrent
        ? await _expenseTotal(db, prevYm, uptoDayOfMonth: daysElapsed)
        : await _expenseTotal(db, prevYm);

    final income = await _incomeTotal(db, ym);
    final previousIncome = isCurrent
        ? await _incomeTotal(db, prevYm, uptoDayOfMonth: daysElapsed)
        : await _incomeTotal(db, prevYm);

    final budgets = await _budgets(db);
    final totalBudget = budgets.values.fold(0, (int s, int v) => s + v);

    final byCategory = await _expenseByCategory(db, ym);
    final typical = await _typicalByCategory(db, ym);

    final categories = <CategoryRow>[];
    byCategory.forEach((category, amount) {
      if (amount <= 0) return;
      final t = typical[category];
      categories.add(CategoryRow(
        category: category,
        spentPaise: amount,
        share: spent > 0 ? amount / spent : 0,
        typicalPaise: t?.averagePaise,
        typicalMonths: t?.months ?? 0,
        budgetPaise: budgets[category],
      ));
    });
    categories.sort((a, b) => b.spentPaise.compareTo(a.spentPaise));

    final people = await _peopleBreakdown(db, ym, prevYm,
        isCurrent: isCurrent, daysElapsed: daysElapsed, monthTotal: spent);

    final trend = await _trend(db, ym, months: 6);

    final forecast = isCurrent && daysElapsed > 0
        ? (spent / daysElapsed * daysInMonth).round()
        : spent;

    final snapshot = AnalyticsSnapshot(
      ym: ym,
      isCurrentMonth: isCurrent,
      daysElapsed: daysElapsed,
      daysInMonth: daysInMonth,
      spentPaise: spent,
      previousComparablePaise: prevComparable,
      previousMonthName: monthNameOf(prevYm),
      incomePaise: income,
      previousIncomePaise: previousIncome,
      forecastPaise: forecast,
      totalBudgetPaise: totalBudget,
      unassignedPaise: people
          .firstWhere((p) => p.name == 'Unassigned',
              orElse: () => const PersonRow(
                  name: 'Unassigned', spentPaise: 0, share: 0, previousPaise: 0))
          .spentPaise,
      categories: categories,
      people: people,
      trend: trend,
      hasBudgets: budgets.isNotEmpty,
    );

    return snapshot.withAlert(_deriveAlert(snapshot));
  }

  // ── Detail ──────────────────────────────────────────────────────────────────

  /// Everything the category sheet needs. Same month, same rules as the list
  /// row it was opened from, so the two can never disagree.
  Future<CategoryDetail> categoryDetail(String ym, String category) async {
    final db = await _service.database;

    final spent = await _expenseTotal(db, ym, category: category);
    final typical = (await _typicalByCategory(db, ym, category: category))[category];
    final budgets = await _budgets(db);

    final trend = await _trend(db, ym, months: 6, category: category);

    final rows = await db.rawQuery(
      'SELECT assignedTo, $signedExpense AS p FROM transactions '
      'WHERE date LIKE ? AND category = ? AND $expenseRows GROUP BY assignedTo',
      ['$ym%', category],
    );
    final raw = <String, int>{};
    for (final r in rows) {
      raw[_normaliseMember(r['assignedTo'] as String?)] =
          (raw[_normaliseMember(r['assignedTo'] as String?)] ?? 0) +
              ((r['p'] as num?)?.toInt() ?? 0);
    }
    final people = <PersonRow>[
      for (final m in members)
        if ((raw[m] ?? 0) > 0)
          PersonRow(
            name: m,
            spentPaise: raw[m]!,
            share: spent > 0 ? raw[m]! / spent : 0,
            previousPaise: 0,
          ),
    ]..sort((a, b) => b.spentPaise.compareTo(a.spentPaise));

    final countRow = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM transactions '
      'WHERE date LIKE ? AND category = ? AND $expenseRows',
      ['$ym%', category],
    );

    return CategoryDetail(
      category: category,
      ym: ym,
      spentPaise: spent,
      typicalPaise: typical?.averagePaise,
      typicalMonths: typical?.months ?? 0,
      budgetPaise: budgets[category],
      trend: trend,
      people: people,
      transactionCount: (countRow.first['c'] as num?)?.toInt() ?? 0,
    );
  }

  /// The suggested monthly limit when setting a budget: what this category
  /// typically costs. Same definition as the "typical" shown everywhere else.
  Future<int?> suggestedBudgetPaise(String category) async {
    final db = await _service.database;
    final t = (await _typicalByCategory(db, ymOf(DateTime.now()),
        category: category))[category];
    return t?.averagePaise;
  }

  Future<void> saveBudget(String category, int limitPaise) =>
      _service.saveBudget(category, Money.toDouble(limitPaise));

  Future<void> deleteBudget(String category) => _service.deleteBudget(category);

  // ── Building blocks ─────────────────────────────────────────────────────────

  Future<int> _expenseTotal(
    Database db,
    String ym, {
    String? category,
    int? uptoDayOfMonth,
  }) async {
    final where = StringBuffer('date LIKE ? AND $expenseRows');
    final args = <Object?>['$ym%'];
    if (category != null) {
      where.write(' AND category = ?');
      args.add(category);
    }
    if (uptoDayOfMonth != null) {
      where.write(" AND CAST(strftime('%d', date) AS INTEGER) <= ?");
      args.add(uptoDayOfMonth);
    }
    final rows = await db.rawQuery(
      'SELECT $signedExpense AS p FROM transactions WHERE $where',
      args,
    );
    final total = (rows.first['p'] as num?)?.toInt() ?? 0;
    return total > 0 ? total : 0;
  }

  /// Money genuinely coming in: credits that are not transfers between our own
  /// accounts, not failed, and not refunds of our own spending. A refund is
  /// money coming back, not income — counting it as income would flatter the
  /// savings rate every time something was returned.
  Future<int> _incomeTotal(
    Database db,
    String ym, {
    int? uptoDayOfMonth,
  }) async {
    final where = StringBuffer('date LIKE ? AND $incomeRows');
    final args = <Object?>['$ym%'];
    if (uptoDayOfMonth != null) {
      where.write(" AND CAST(strftime('%d', date) AS INTEGER) <= ?");
      args.add(uptoDayOfMonth);
    }
    final rows = await db.rawQuery(
      'SELECT SUM($paise) AS p FROM transactions WHERE $where',
      args,
    );
    final total = (rows.first['p'] as num?)?.toInt() ?? 0;
    return total > 0 ? total : 0;
  }

  Future<Map<String, int>> _expenseByCategory(Database db, String ym) async {
    final rows = await db.rawQuery(
      'SELECT category, $signedExpense AS p FROM transactions '
      'WHERE date LIKE ? AND $expenseRows GROUP BY category',
      ['$ym%'],
    );
    return {
      for (final r in rows)
        (r['category'] as String?) ?? 'Other': (r['p'] as num?)?.toInt() ?? 0,
    };
  }

  /// What a category "typically" costs: the mean of the trailing three complete
  /// months before [ym], counting only months the category actually appeared in.
  ///
  /// Averaging over a fixed denominator of 3 would understate a category that
  /// only shows up occasionally and then flag every appearance as a spike.
  /// [TypicalSpend.months] is carried alongside so callers can refuse to draw a
  /// comparison from a single month of history.
  Future<Map<String, TypicalSpend>> _typicalByCategory(
    Database db,
    String ym, {
    String? category,
  }) async {
    final from = _shift(ym, -3);
    final args = <Object?>[from, ym];
    final categoryClause = category == null ? '' : ' AND category = ?';
    if (category != null) args.add(category);

    final rows = await db.rawQuery('''
      SELECT category, AVG(monthly) AS avg_p, COUNT(*) AS months FROM (
        SELECT category, SUBSTR(date, 1, 7) AS m, $signedExpense AS monthly
        FROM transactions
        WHERE SUBSTR(date, 1, 7) >= ? AND SUBSTR(date, 1, 7) < ?
          AND $expenseRows$categoryClause
        GROUP BY category, m
        HAVING monthly > 0
      )
      GROUP BY category
    ''', args);

    return {
      for (final r in rows)
        (r['category'] as String?) ?? 'Other': TypicalSpend(
          averagePaise: ((r['avg_p'] as num?)?.toDouble() ?? 0).round(),
          months: (r['months'] as num?)?.toInt() ?? 0,
        ),
    };
  }

  Future<List<PersonRow>> _peopleBreakdown(
    Database db,
    String ym,
    String prevYm, {
    required bool isCurrent,
    required int daysElapsed,
    required int monthTotal,
  }) async {
    Future<Map<String, int>> forMonth(String month, {int? uptoDay}) async {
      final where = StringBuffer('date LIKE ? AND $expenseRows');
      final args = <Object?>['$month%'];
      if (uptoDay != null) {
        where.write(" AND CAST(strftime('%d', date) AS INTEGER) <= ?");
        args.add(uptoDay);
      }
      final rows = await db.rawQuery(
        'SELECT assignedTo, $signedExpense AS p FROM transactions '
        'WHERE $where GROUP BY assignedTo',
        args,
      );
      final out = <String, int>{};
      for (final r in rows) {
        final key = _normaliseMember(r['assignedTo'] as String?);
        out[key] = (out[key] ?? 0) + ((r['p'] as num?)?.toInt() ?? 0);
      }
      return out;
    }

    final current = await forMonth(ym);
    final previous =
        await forMonth(prevYm, uptoDay: isCurrent ? daysElapsed : null);

    return [
      for (final m in members)
        // Me/Mom/Dad always appear, so a ₹0 month reads as "spent nothing"
        // rather than as missing data. Unassigned only appears when it exists —
        // it is a prompt to tag, and an empty prompt is noise.
        if (m != 'Unassigned' || (current[m] ?? 0) > 0)
          PersonRow(
            name: m,
            spentPaise: current[m] ?? 0,
            share: monthTotal > 0 ? (current[m] ?? 0) / monthTotal : 0,
            previousPaise: previous[m] ?? 0,
          ),
    ];
  }

  static String _normaliseMember(String? raw) =>
      members.contains(raw) ? raw! : 'Unassigned';

  /// Monthly totals ending at [ym] inclusive, oldest first. Months with no
  /// transactions at all are returned with a null amount so the chart can show
  /// a gap instead of claiming ₹0 was spent.
  ///
  /// Six months at both scopes: enough to see a direction, few enough that
  /// every month keeps its own axis label on a phone.
  Future<List<TrendPoint>> _trend(
    Database db,
    String ym, {
    int months = 6,
    String? category,
  }) async {
    final from = _shift(ym, -(months - 1));
    final args = <Object?>[from, ym];
    final categoryClause = category == null ? '' : ' AND category = ?';
    if (category != null) args.add(category);

    final rows = await db.rawQuery('''
      SELECT SUBSTR(date, 1, 7) AS m, $signedExpense AS p, COUNT(*) AS c
      FROM transactions
      WHERE SUBSTR(date, 1, 7) >= ? AND SUBSTR(date, 1, 7) <= ?
        AND $expenseRows$categoryClause
      GROUP BY m
    ''', args);

    final byMonth = {
      for (final r in rows)
        r['m'] as String: (
          ((r['p'] as num?)?.toInt() ?? 0),
          ((r['c'] as num?)?.toInt() ?? 0),
        ),
    };

    final points = <TrendPoint>[];
    for (var i = months - 1; i >= 0; i--) {
      final key = _shift(ym, -i);
      final hit = byMonth[key];
      points.add(TrendPoint(
        ym: key,
        label: DateFormat('MMM').format(DateFormat('yyyy-MM').parse(key)),
        paise: hit == null ? null : (hit.$1 > 0 ? hit.$1 : 0),
        isSelected: key == ym,
      ));
    }
    return points;
  }

  Future<Map<String, int>> _budgets(Database db) async {
    final rows = await db.query('budgets');
    return {
      for (final r in rows)
        r['category'] as String:
            Money.fromDouble(((r['amount'] as num?)?.toDouble() ?? 0)),
    };
  }

  // ── Alerts ──────────────────────────────────────────────────────────────────

  /// One alert, chosen by consequence rather than by which query happened to
  /// return something. The old screen showed a forecast warning and up to three
  /// spike rows simultaneously, which left the reader to work out which one
  /// mattered — the job the alert exists to do.
  AnalyticsAlert _deriveAlert(AnalyticsSnapshot s) {
    final overspent = s.categories
        .where((c) => c.isOverBudget)
        .toList()
      ..sort((a, b) => b.overBudgetPaise.compareTo(a.overBudgetPaise));

    if (overspent.isNotEmpty) {
      final c = overspent.first;
      final spike = c.isSpike ? ' — ${c.ratioLabel} your usual' : '';
      return AnalyticsAlert(
        severity: AlertSeverity.critical,
        message: '${c.category} is ${_r(c.overBudgetPaise)} over budget$spike',
        category: c.category,
      );
    }

    // Spending past what came in. Guarded on income being present at all:
    // mid-month, before salary lands, every household is "over" its income and
    // the warning would be noise rather than news.
    if (s.incomePaise > 0 && s.spentPaise > s.incomePaise) {
      return AnalyticsAlert(
        severity: AlertSeverity.critical,
        message: s.isCurrentMonth
            ? 'Spending has passed income by ${_r(-s.netPaise)} this month'
            : 'Spent ${_r(-s.netPaise)} more than came in',
      );
    }

    if (s.isCurrentMonth &&
        s.hasBudgets &&
        s.forecastPaise > s.totalBudgetPaise) {
      return AnalyticsAlert(
        severity: AlertSeverity.warning,
        message: 'On pace to exceed budget by '
            '${_r(s.forecastPaise - s.totalBudgetPaise)} this month',
      );
    }

    final spikes = s.categories.where((c) => c.isSpike).toList()
      ..sort((a, b) => (b.ratio ?? 0).compareTo(a.ratio ?? 0));
    if (spikes.isNotEmpty) {
      final c = spikes.first;
      return AnalyticsAlert(
        severity: AlertSeverity.warning,
        message: '${c.category} is ${c.ratioLabel} your usual — '
            '${_r(c.spentPaise)} vs ${_r(c.typicalPaise!)} typical',
        category: c.category,
      );
    }

    if (!s.hasBudgets) {
      return const AnalyticsAlert(
        severity: AlertSeverity.prompt,
        message: 'No budgets set yet — set one to track where you stand',
      );
    }

    if (s.unassignedPaise > 0 && s.spentPaise > 0 &&
        s.unassignedPaise / s.spentPaise > 0.10) {
      return AnalyticsAlert(
        severity: AlertSeverity.prompt,
        message: '${_r(s.unassignedPaise)} is untagged — '
            'these numbers are only as good as their tagging',
      );
    }

    return AnalyticsAlert(
      severity: AlertSeverity.ok,
      message: s.isCurrentMonth
          ? 'On track — projected ${_r(s.forecastPaise)} against '
              '${_r(s.totalBudgetPaise)} budgeted'
          : 'Finished ${_r((s.totalBudgetPaise - s.spentPaise).abs())} '
              '${s.spentPaise > s.totalBudgetPaise ? 'over' : 'under'} budget',
    );
  }

  static String _r(int p) =>
      NumberFormat.currency(symbol: '₹', decimalDigits: 0)
          .format(Money.toDouble(p));
}

// ── Value types ───────────────────────────────────────────────────────────────

class TypicalSpend {
  const TypicalSpend({required this.averagePaise, required this.months});
  final int averagePaise;
  final int months;
}

class CategoryRow {
  const CategoryRow({
    required this.category,
    required this.spentPaise,
    required this.share,
    required this.typicalPaise,
    required this.typicalMonths,
    required this.budgetPaise,
  });

  final String category;
  final int spentPaise;
  final double share;
  final int? typicalPaise;
  final int typicalMonths;
  final int? budgetPaise;

  bool get hasBudget => budgetPaise != null && budgetPaise! > 0;
  bool get isOverBudget => hasBudget && spentPaise > budgetPaise!;
  int get overBudgetPaise => isOverBudget ? spentPaise - budgetPaise! : 0;
  double get budgetProgress =>
      hasBudget ? (spentPaise / budgetPaise!).clamp(0.0, 1.0) : 0;

  /// Only compared when there is enough history to compare against. One prior
  /// month is an anecdote, not a baseline.
  bool get hasComparison =>
      typicalPaise != null && typicalPaise! > 0 && typicalMonths >= 2;

  double? get ratio => hasComparison ? spentPaise / typicalPaise! : null;

  /// A ₹200 floor keeps rounding noise in a tiny category from reading as a
  /// spending emergency.
  bool get isSpike =>
      hasComparison && typicalPaise! > 20000 && (ratio ?? 0) >= 1.5;

  String get ratioLabel => '${(ratio ?? 0).toStringAsFixed(1)}×';

  /// Signed change against typical, as a fraction. Null when uncomparable.
  double? get deltaFraction =>
      hasComparison ? (spentPaise - typicalPaise!) / typicalPaise! : null;
}

class PersonRow {
  const PersonRow({
    required this.name,
    required this.spentPaise,
    required this.share,
    required this.previousPaise,
  });

  final String name;
  final int spentPaise;
  final double share;
  final int previousPaise;

  int get deltaPaise => spentPaise - previousPaise;
}

class TrendPoint {
  const TrendPoint({
    required this.ym,
    required this.label,
    required this.paise,
    required this.isSelected,
  });

  final String ym;
  final String label;

  /// Null means "no transactions recorded in this month at all" — a gap, not a
  /// zero. Claiming ₹0 for a month the user simply had not started tracking is
  /// the kind of small lie that makes a chart untrustworthy.
  final int? paise;
  final bool isSelected;
}

enum AlertSeverity { critical, warning, prompt, ok }

class AnalyticsAlert {
  const AnalyticsAlert({
    required this.severity,
    required this.message,
    this.category,
  });

  final AlertSeverity severity;
  final String message;

  /// When present the alert is tappable and opens this category.
  final String? category;
}

class CategoryDetail {
  const CategoryDetail({
    required this.category,
    required this.ym,
    required this.spentPaise,
    required this.typicalPaise,
    required this.typicalMonths,
    required this.budgetPaise,
    required this.trend,
    required this.people,
    required this.transactionCount,
  });

  final String category;
  final String ym;
  final int spentPaise;
  final int? typicalPaise;
  final int typicalMonths;
  final int? budgetPaise;
  final List<TrendPoint> trend;
  final List<PersonRow> people;
  final int transactionCount;

  bool get hasBudget => budgetPaise != null && budgetPaise! > 0;
  bool get isOverBudget => hasBudget && spentPaise > budgetPaise!;
  double get budgetProgress =>
      hasBudget ? (spentPaise / budgetPaise!).clamp(0.0, 1.0) : 0;
  bool get hasComparison =>
      typicalPaise != null && typicalPaise! > 0 && typicalMonths >= 2;
  double? get ratio => hasComparison ? spentPaise / typicalPaise! : null;
}

class AnalyticsSnapshot {
  const AnalyticsSnapshot({
    required this.ym,
    required this.isCurrentMonth,
    required this.daysElapsed,
    required this.daysInMonth,
    required this.spentPaise,
    required this.previousComparablePaise,
    required this.previousMonthName,
    required this.incomePaise,
    required this.previousIncomePaise,
    required this.forecastPaise,
    required this.totalBudgetPaise,
    required this.unassignedPaise,
    required this.categories,
    required this.people,
    required this.trend,
    required this.hasBudgets,
    this.alert = const AnalyticsAlert(
        severity: AlertSeverity.ok, message: 'On track'),
  });

  final String ym;
  final bool isCurrentMonth;
  final int daysElapsed;
  final int daysInMonth;
  final int spentPaise;
  final int previousComparablePaise;
  final String previousMonthName;
  final int incomePaise;
  final int previousIncomePaise;

  /// Projected month-end spend for the current month; the final total for any
  /// past month. Same slot, period-appropriate content — a projection for a
  /// month that already ended is not a forecast, it is a fiction.
  final int forecastPaise;
  final int totalBudgetPaise;
  final int unassignedPaise;
  final List<CategoryRow> categories;
  final List<PersonRow> people;
  final List<TrendPoint> trend;
  final bool hasBudgets;
  final AnalyticsAlert alert;

  bool get isEmpty => spentPaise == 0 && categories.isEmpty;

  int get deltaPaise => spentPaise - previousComparablePaise;

  double? get deltaFraction => previousComparablePaise > 0
      ? deltaPaise / previousComparablePaise
      : null;

  int get headroomPaise => totalBudgetPaise - spentPaise;

  /// What was left after spending. Negative means the month ate into savings.
  int get netPaise => incomePaise - spentPaise;

  /// The share of income not spent. Null when there is no income to divide by —
  /// a savings rate against zero income is not 0%, it is undefined, and
  /// printing "0%" would be a number the user could act on wrongly.
  double? get savingsRate =>
      incomePaise > 0 ? netPaise / incomePaise : null;

  int get incomeDeltaPaise => incomePaise - previousIncomePaise;

  /// Whether this household tracks income at all. Someone who only records
  /// spending should not be shown an empty income section every month, so the
  /// whole block stays hidden until there is income in this month or the last.
  bool get tracksIncome => incomePaise > 0 || previousIncomePaise > 0;

  double get budgetProgress =>
      totalBudgetPaise > 0 ? (spentPaise / totalBudgetPaise).clamp(0.0, 1.0) : 0;

  bool get projectedOverBudget =>
      hasBudgets && forecastPaise > totalBudgetPaise;

  AnalyticsSnapshot withAlert(AnalyticsAlert a) => AnalyticsSnapshot(
        ym: ym,
        isCurrentMonth: isCurrentMonth,
        daysElapsed: daysElapsed,
        daysInMonth: daysInMonth,
        spentPaise: spentPaise,
        previousComparablePaise: previousComparablePaise,
        previousMonthName: previousMonthName,
        incomePaise: incomePaise,
        previousIncomePaise: previousIncomePaise,
        forecastPaise: forecastPaise,
        totalBudgetPaise: totalBudgetPaise,
        unassignedPaise: unassignedPaise,
        categories: categories,
        people: people,
        trend: trend,
        hasBudgets: hasBudgets,
        alert: a,
      );
}

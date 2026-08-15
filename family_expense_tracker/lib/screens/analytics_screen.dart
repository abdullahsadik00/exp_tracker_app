import 'dart:async';

import 'package:flutter/material.dart';

import '../models/transaction_model.dart';
import '../models/txn_filter_request.dart';
import '../services/analytics_repository.dart';
import '../services/local_db_service.dart';
import '../theme/app_colors.dart';
import '../utils/amount_display.dart';
import '../utils/money.dart';
import '../widgets/category_detail_sheet.dart';
import '../widgets/trend_chart.dart';

/// Analytics, organised around the four questions a family actually asks:
/// how are we doing, where did it go, who spent it, and is that more than
/// before.
///
/// Everything on the screen comes from a single [AnalyticsSnapshot] loaded for
/// the selected month. That is deliberate: the previous version drove six
/// independent streams with three different definitions of "spending", so the
/// headline total could not be reconciled with the chart beneath it. One
/// snapshot means one loading state, one error state, and one set of numbers.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key, this.onViewTransactions});

  /// Opens the Transactions tab pre-filtered. Every drill-down on this screen
  /// ends here rather than in a transaction list of its own.
  final ValueChanged<TxnFilterRequest>? onViewTransactions;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  final AnalyticsRepository _repo = AnalyticsRepository();
  StreamSubscription<void>? _dbChanges;

  late String _ym;
  List<String> _months = const [];
  Future<AnalyticsSnapshot>? _snapshot;
  bool _showAllCategories = false;

  /// Rows shown before "Show all". Five covers the categories worth acting on
  /// in a typical month without turning the section into a scroll of its own.
  static const int _topCategoryCount = 5;

  @override
  void initState() {
    super.initState();
    _ym = AnalyticsRepository.ymOf(DateTime.now());
    // Assigned directly rather than through _reload: the first build has not
    // run yet, so there is no state to notify.
    _snapshot = _repo.load(_ym);
    _loadMonths();
    _dbChanges = LocalDbService.instance.onChange.listen((_) {
      if (!mounted) return;
      _loadMonths();
      _reload();
    });
  }

  @override
  void dispose() {
    _dbChanges?.cancel();
    super.dispose();
  }

  Future<void> _loadMonths() async {
    final months = await _repo.availableMonths();
    if (!mounted) return;

    // The selected month can disappear — delete a month's last transaction and
    // it drops out of the list. Fall back to the newest month and reload with
    // it, so the header and the figures below it never describe different
    // months.
    final fallback = !months.contains(_ym) && months.isNotEmpty;
    final ym = fallback ? months.first : _ym;
    final future = fallback ? _repo.load(ym) : null;

    setState(() {
      _months = months;
      _ym = ym;
      if (future != null) _snapshot = future;
    });
  }

  void _reload() {
    // Kick the query off outside setState, then swap the field in a block
    // body. An arrow body would hand setState the assignment's value — the
    // Future itself — which it rejects.
    final future = _repo.load(_ym);
    if (!mounted) {
      _snapshot = future;
      return;
    }
    setState(() {
      _snapshot = future;
    });
  }

  void _selectMonth(String ym) {
    if (ym == _ym) return;
    final future = _repo.load(ym);
    setState(() {
      _ym = ym;
      _showAllCategories = false;
      _snapshot = future;
    });
  }

  String get _monthLabel => AnalyticsRepository.shortLabelOf(_ym);

  void _viewTransactions({String? category, String? person}) {
    widget.onViewTransactions?.call(TxnFilterRequest(
      monthLabel: _monthLabel,
      category: category,
      person: person,
    ));
  }

  void _openCategory(String category) {
    CategoryDetailSheet.show(
      context,
      category: category,
      ym: _ym,
      repository: _repo,
      onViewTransactions: () => _viewTransactions(category: category),
      onEditBudget: () => _showBudgetDialog(category: category),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Analytics',
            style: TextStyle(
                fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadMonths();
          _reload();
          // The FutureBuilder renders the failure; swallowing it here only
          // stops the refresh gesture itself from throwing.
          try {
            await _snapshot;
          } catch (_) {}
        },
        color: AppColors.accent,
        backgroundColor: AppColors.surface,
        child: FutureBuilder<AnalyticsSnapshot>(
          future: _snapshot,
          builder: (context, snap) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
              children: [
                _monthFilter(),
                const SizedBox(height: 20),
                if (snap.hasError)
                  _errorCard(snap.error!)
                else if (!snap.hasData)
                  const _AnalyticsSkeleton()
                else
                  ..._sections(snap.data!),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _sections(AnalyticsSnapshot s) {
    return [
      _ThisMonthCard(snapshot: s),
      const SizedBox(height: 12),
      _AlertCard(
        alert: s.alert,
        onTap: () {
          final category = s.alert.category;
          if (category != null) {
            _openCategory(category);
          } else if (!s.hasBudgets) {
            _showBudgetDialog();
          } else if (s.unassignedPaise > 0) {
            _viewTransactions(person: 'Unassigned');
          }
        },
      ),
      const SizedBox(height: 32),
      _sectionHeader('Where it went'),
      const SizedBox(height: 12),
      _categorySection(s),
      const SizedBox(height: 32),
      _sectionHeader('Who spent it'),
      const SizedBox(height: 16),
      _peopleSection(s),
      const SizedBox(height: 32),
      _sectionHeader('Trend'),
      const SizedBox(height: 16),
      _card(child: TrendChart(points: s.trend, onMonthTap: _selectMonth)),
    ];
  }

  // ── Filter ──────────────────────────────────────────────────────────────────

  Widget _monthFilter() {
    final months = _months.isEmpty ? [_ym] : _months;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          const Icon(Icons.calendar_today_rounded,
              color: AppColors.accent, size: 18),
          const SizedBox(width: 12),
          const Text('Showing',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          const Spacer(),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: months.contains(_ym) ? _ym : months.first,
              dropdownColor: AppColors.surface,
              icon: const Icon(Icons.arrow_drop_down, color: AppColors.accent),
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 15),
              items: [
                for (final m in months)
                  DropdownMenuItem(
                      value: m,
                      child: Text(AnalyticsRepository.shortLabelOf(m))),
              ],
              onChanged: (v) => v == null ? null : _selectMonth(v),
            ),
          ),
        ],
      ),
    );
  }

  // ── Categories ──────────────────────────────────────────────────────────────

  Widget _categorySection(AnalyticsSnapshot s) {
    if (s.categories.isEmpty) {
      return _emptyCard(
        icon: Icons.receipt_long_outlined,
        title: 'No spending in $_monthLabel',
        body: 'Add transactions, or pick a different month above.',
      );
    }

    final visible = _showAllCategories
        ? s.categories
        : s.categories.take(_topCategoryCount).toList();
    final hidden = s.categories.length - visible.length;

    return Column(
      children: [
        for (final c in visible) ...[
          _CategoryRowTile(
            row: c,
            onTap: () => _openCategory(c.category),
            onSetBudget: () => _showBudgetDialog(category: c.category),
          ),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            if (hidden > 0)
              TextButton(
                onPressed: () => setState(() => _showAllCategories = true),
                child: Text('Show all ${s.categories.length}',
                    style: const TextStyle(color: AppColors.accent)),
              )
            else if (_showAllCategories && s.categories.length > _topCategoryCount)
              TextButton(
                onPressed: () => setState(() => _showAllCategories = false),
                child: const Text('Show less',
                    style: TextStyle(color: AppColors.accent)),
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _showBudgetDialog(),
              icon: const Icon(Icons.add, size: 16, color: AppColors.accent),
              label: const Text('Add budget',
                  style: TextStyle(color: AppColors.accent)),
            ),
          ],
        ),
      ],
    );
  }

  // ── People ──────────────────────────────────────────────────────────────────

  Widget _peopleSection(AnalyticsSnapshot s) {
    if (s.people.isEmpty || s.spentPaise == 0) {
      return _emptyCard(
        icon: Icons.people_outline,
        title: 'Nothing to split yet',
        body: 'Once there is spending in $_monthLabel it breaks down here.',
      );
    }

    return _card(
      child: Column(
        children: [
          for (var i = 0; i < s.people.length; i++) ...[
            _PersonRowTile(
              person: s.people[i],
              previousMonthName: s.previousMonthName,
              onTagUnassigned: s.people[i].name == 'Unassigned'
                  ? () => _viewTransactions(person: 'Unassigned')
                  : null,
            ),
            if (i != s.people.length - 1) const SizedBox(height: 18),
          ],
        ],
      ),
    );
  }

  // ── Chrome ──────────────────────────────────────────────────────────────────

  Widget _sectionHeader(String title) => Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      );

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: child,
      );

  Widget _emptyCard(
          {required IconData icon,
          required String title,
          required String body}) =>
      _card(
        child: Column(
          children: [
            Icon(icon, color: AppColors.textSecondary.withOpacity(0.5), size: 36),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15)),
            const SizedBox(height: 6),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
      );

  /// A failed query used to render as a missing card, which on a spending
  /// screen reads as "₹0" — the worst way for this app to fail. It says so
  /// now, and offers the retry.
  Widget _errorCard(Object error) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.debit.withOpacity(0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline,
                    color: AppColors.debit, size: 20),
                const SizedBox(width: 10),
                const Text("Couldn't load your analytics",
                    style: TextStyle(
                        color: AppColors.debit,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'These figures are unavailable right now — nothing is missing '
              'from your transactions.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text('$error',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: AppColors.textSecondary.withOpacity(0.7),
                    fontSize: 11)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh, size: 16, color: AppColors.accent),
                label: const Text('Try again',
                    style: TextStyle(color: AppColors.accent)),
              ),
            ),
          ],
        ),
      );

  // ── Budgets ─────────────────────────────────────────────────────────────────

  /// Budgets are edited where they are read — from a category row or the
  /// category sheet — rather than from a carousel of their own at the bottom
  /// of the screen.
  void _showBudgetDialog({String? category}) {
    final amountController = TextEditingController();
    String selected = category ?? TransactionModel.availableCategories.first;
    int? suggestion;
    String? loadedFor;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          if (loadedFor != selected) {
            loadedFor = selected;
            _repo.suggestedBudgetPaise(selected).then((value) {
              if (value == null || value <= 0 || !ctx.mounted) return;
              setDialogState(() {
                suggestion = value;
                if (amountController.text.isEmpty) {
                  amountController.text =
                      Money.toDouble(value).toStringAsFixed(0);
                }
              });
            });
          }

          return AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(
              category == null ? 'Set a budget' : '$category budget',
              style: const TextStyle(color: AppColors.textPrimary),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (category == null)
                  DropdownButtonFormField<String>(
                    value: selected,
                    dropdownColor: AppColors.surface,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      labelStyle: TextStyle(color: AppColors.textSecondary),
                    ),
                    items: [
                      for (final c in TransactionModel.availableCategories)
                        DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      amountController.clear();
                      setDialogState(() {
                        selected = v;
                        suggestion = null;
                      });
                    },
                  ),
                const SizedBox(height: 16),
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  autofocus: category != null,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Monthly limit (₹)',
                    labelStyle:
                        const TextStyle(color: AppColors.textSecondary),
                    helperText: suggestion == null
                        ? null
                        : 'Typically ${formatPaise(suggestion!)} a month',
                    helperStyle:
                        const TextStyle(color: AppColors.accent, fontSize: 11),
                    enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: AppColors.accent)),
                    focusedBorder: const UnderlineInputBorder(
                        borderSide:
                            BorderSide(color: AppColors.accent, width: 2)),
                  ),
                ),
              ],
            ),
            actions: [
              if (category != null)
                TextButton(
                  onPressed: () async {
                    await _repo.deleteBudget(category);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Remove',
                      style: TextStyle(color: AppColors.debit)),
                ),
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel',
                      style: TextStyle(color: AppColors.textSecondary))),
              ElevatedButton(
                onPressed: () async {
                  final rupees = double.tryParse(amountController.text.trim());
                  if (rupees == null || rupees <= 0) return;
                  await _repo.saveBudget(selected, Money.fromDouble(rupees));
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                style:
                    ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                child: const Text('Save',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── This month ────────────────────────────────────────────────────────────────

class _ThisMonthCard extends StatelessWidget {
  const _ThisMonthCard({required this.snapshot});

  final AnalyticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final overBudget = s.hasBudgets && s.headroomPaise < 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                s.isCurrentMonth
                    ? 'SPENT THIS MONTH'
                    : 'SPENT IN ${AnalyticsRepository.monthNameOf(s.ym).toUpperCase()}',
                style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2),
              ),
              const Spacer(),
              if (s.isCurrentMonth)
                Text('Day ${s.daysElapsed} of ${s.daysInMonth}',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatPaise(s.spentPaise),
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.2),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _DeltaLabel(
                  deltaPaise: s.deltaPaise,
                  hasBaseline: s.previousComparablePaise > 0,
                  suffix: 'vs ${s.previousMonthName}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // The two supporting KPIs. Everything else that used to sit up here
          // was context, not a decision.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Kpi(
                  label: s.isCurrentMonth
                      ? 'Projected by ${s.daysInMonth} '
                          '${AnalyticsRepository.monthNameOf(s.ym).substring(0, 3)}'
                      : 'Final total',
                  value: formatPaise(s.forecastPaise),
                  emphasis: s.projectedOverBudget
                      ? AppColors.debit
                      : AppColors.textPrimary,
                ),
              ),
              Expanded(
                child: _Kpi(
                  label: !s.hasBudgets
                      ? 'Budget'
                      : (overBudget ? 'Over budget' : 'Left to spend'),
                  value: !s.hasBudgets
                      ? 'Not set'
                      : formatPaise(s.headroomPaise.abs()),
                  emphasis: !s.hasBudgets
                      ? AppColors.textSecondary
                      : (overBudget ? AppColors.debit : AppColors.credit),
                  sub: s.hasBudgets
                      ? 'of ${formatPaise(s.totalBudgetPaise)}'
                      : null,
                ),
              ),
            ],
          ),

          if (s.hasBudgets) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: s.budgetProgress,
                backgroundColor: Colors.white.withOpacity(0.05),
                color: overBudget ? AppColors.debit : AppColors.accent,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${(s.budgetProgress * 100).round()}% of '
              '${formatPaise(s.totalBudgetPaise)} budgeted',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.label,
    required this.value,
    required this.emphasis,
    this.sub,
  });

  final String label;
  final String value;
  final Color emphasis;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 11)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              style: TextStyle(
                  color: emphasis,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ),
        if (sub != null)
          Text(sub!,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 10)),
      ],
    );
  }
}

/// More spending than the comparison period is red, less is green. On a
/// spending screen "up" is not good news, and the colour should not have to be
/// re-learned per card.
class _DeltaLabel extends StatelessWidget {
  const _DeltaLabel({
    required this.deltaPaise,
    required this.hasBaseline,
    required this.suffix,
  });

  final int deltaPaise;
  final bool hasBaseline;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    if (!hasBaseline) {
      return Text('no $suffix to compare',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12));
    }
    if (deltaPaise == 0) {
      return Text('same as $suffix',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12));
    }
    final up = deltaPaise > 0;
    return Text(
      '${up ? '↑' : '↓'} ${formatPaise(deltaPaise.abs())} $suffix',
      style: TextStyle(
        color: up ? AppColors.debit : AppColors.credit,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

// ── Alert ─────────────────────────────────────────────────────────────────────

/// One alert, not a stack of them. The forecast warning and up to three spike
/// rows used to compete for the same attention, which left the reader to work
/// out which mattered — the job the alert exists to do.
class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.onTap});

  final AnalyticsAlert alert;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (alert.severity) {
      AlertSeverity.critical => (AppColors.debit, Icons.error_outline_rounded),
      AlertSeverity.warning => (Colors.amber, Icons.warning_amber_rounded),
      AlertSeverity.prompt => (AppColors.accent, Icons.lightbulb_outline),
      AlertSeverity.ok => (AppColors.credit, Icons.check_circle_outline),
    };

    final actionable = alert.severity != AlertSeverity.ok;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: actionable ? onTap : null,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  alert.message,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      height: 1.35),
                ),
              ),
              if (actionable) ...[
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded,
                    color: color.withOpacity(0.8), size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Category row ──────────────────────────────────────────────────────────────

class _CategoryRowTile extends StatelessWidget {
  const _CategoryRowTile({
    required this.row,
    required this.onTap,
    required this.onSetBudget,
  });

  final CategoryRow row;
  final VoidCallback onTap;
  final VoidCallback onSetBudget;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: row.isOverBudget
                  ? AppColors.debit.withOpacity(0.3)
                  : Colors.white.withOpacity(0.05),
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(row.category,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                  ),
                  Text(formatPaise(row.spentPaise),
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 36,
                    child: Text('${(row.share * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                  ),
                  const Icon(Icons.chevron_right_rounded,
                      color: AppColors.textSecondary, size: 18),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: row.hasBudget
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: row.budgetProgress,
                              backgroundColor: Colors.white.withOpacity(0.05),
                              color: row.isOverBudget
                                  ? AppColors.debit
                                  : AppColors.accent,
                              minHeight: 4,
                            ),
                          )
                        : const SizedBox(height: 4),
                  ),
                  const SizedBox(width: 12),
                  if (row.hasComparison) _comparison(),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      row.hasBudget
                          ? '${(row.spentPaise / row.budgetPaise! * 100).round()}% '
                              'of ${formatPaise(row.budgetPaise!)}'
                          : 'No budget set',
                      style: TextStyle(
                        color: row.isOverBudget
                            ? AppColors.debit
                            : AppColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  if (!row.hasBudget)
                    GestureDetector(
                      onTap: onSetBudget,
                      behavior: HitTestBehavior.opaque,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Text('Set',
                            style: TextStyle(
                                color: AppColors.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _comparison() {
    final ratio = row.ratio!;
    if (ratio >= 1.5) {
      return Text('↑ ${ratio.toStringAsFixed(1)}× usual',
          style: const TextStyle(
              color: AppColors.debit,
              fontSize: 11,
              fontWeight: FontWeight.bold));
    }
    final delta = row.deltaFraction!;
    if (delta.abs() < 0.05) {
      return const Text('→ usual',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 11));
    }
    final up = delta > 0;
    return Text(
      '${up ? '↑' : '↓'} ${(delta.abs() * 100).round()}%',
      style: TextStyle(
        color: up ? AppColors.debit : AppColors.credit,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

// ── Person row ────────────────────────────────────────────────────────────────

class _PersonRowTile extends StatelessWidget {
  const _PersonRowTile({
    required this.person,
    required this.previousMonthName,
    this.onTagUnassigned,
  });

  final PersonRow person;
  final String previousMonthName;
  final VoidCallback? onTagUnassigned;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(person.name,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
            const SizedBox(width: 10),
            Expanded(
              child: _DeltaLabel(
                deltaPaise: person.deltaPaise,
                hasBaseline: person.previousPaise > 0,
                suffix: 'vs $previousMonthName',
              ),
            ),
            Text('${(person.share * 100).round()}%',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(width: 12),
            Text(formatPaise(person.spentPaise),
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: person.share.clamp(0.0, 1.0),
            backgroundColor: Colors.white.withOpacity(0.05),
            color: memberColor(person.name),
            minHeight: 6,
          ),
        ),
        if (onTagUnassigned != null) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onTagUnassigned,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('Tag these →',
                  style: TextStyle(color: AppColors.accent, fontSize: 12)),
            ),
          ),
        ],
      ],
    );
  }
}

// ── Skeleton ──────────────────────────────────────────────────────────────────

/// Section-shaped placeholders instead of a full-screen spinner. The old screen
/// stacked two of those, so changing month blanked the entire tab.
class _AnalyticsSkeleton extends StatelessWidget {
  const _AnalyticsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _block(height: 168, radius: 24),
        const SizedBox(height: 12),
        _block(height: 60, radius: 20),
        const SizedBox(height: 32),
        _block(height: 12, radius: 4, width: 110),
        const SizedBox(height: 12),
        for (var i = 0; i < 3; i++) ...[
          _block(height: 84, radius: 16),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 22),
        _block(height: 12, radius: 4, width: 110),
        const SizedBox(height: 12),
        _block(height: 180, radius: 20),
      ],
    );
  }

  Widget _block({required double height, required double radius, double? width}) =>
      Container(
        width: width ?? double.infinity,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.surface.withOpacity(0.6),
          borderRadius: BorderRadius.circular(radius),
        ),
      );
}

import 'package:flutter/material.dart';

import '../services/analytics_repository.dart';
import '../theme/app_colors.dart';
import '../utils/amount_display.dart';
import 'trend_chart.dart';

/// The category drill-down, as a sheet over the ranked list rather than as a
/// screen behind a banner.
///
/// The screen it replaces was entered with no category chosen, carried no month
/// across, re-queried every transaction in the database, and ended in a
/// transaction list whose rows could not be tapped. Here you arrive having
/// already tapped the category the list told you was a problem, in the month
/// you were already looking at, and you leave through the Transactions tab —
/// which does lists properly.
class CategoryDetailSheet extends StatelessWidget {
  const CategoryDetailSheet({
    super.key,
    required this.category,
    required this.ym,
    required this.repository,
    required this.onViewTransactions,
    required this.onEditBudget,
  });

  final String category;
  final String ym;
  final AnalyticsRepository repository;
  final VoidCallback onViewTransactions;
  final VoidCallback onEditBudget;

  static Future<void> show(
    BuildContext context, {
    required String category,
    required String ym,
    required AnalyticsRepository repository,
    required VoidCallback onViewTransactions,
    required VoidCallback onEditBudget,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => CategoryDetailSheet(
        category: category,
        ym: ym,
        repository: repository,
        onViewTransactions: onViewTransactions,
        onEditBudget: onEditBudget,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (context, scrollController) {
        return FutureBuilder<CategoryDetail>(
          future: repository.categoryDetail(ym, category),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _Message(
                icon: Icons.error_outline,
                title: "Couldn't load $category",
                body: 'Close and try again.',
              );
            }
            if (!snapshot.hasData) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(48),
                  child: CircularProgressIndicator(color: AppColors.accent),
                ),
              );
            }
            return _content(context, snapshot.data!, scrollController);
          },
        );
      },
    );
  }

  Widget _content(
      BuildContext context, CategoryDetail d, ScrollController controller) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                '${d.category} · ${AnalyticsRepository.shortLabelOf(d.ym)}',
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: AppColors.textSecondary),
              onPressed: () => Navigator.pop(context),
              tooltip: 'Close',
            ),
          ],
        ),
        const SizedBox(height: 16),

        // The comparison line: the three stat cards this replaces answered
        // "what is the number" three times and "is that a lot" never.
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              formatPaise(d.spentPaise),
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1),
            ),
            const SizedBox(width: 12),
            if (d.hasComparison)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(
                  'vs ${formatPaise(d.typicalPaise!)} typical'
                  '  ·  ${_ratioLabel(d.ratio!)}',
                  style: TextStyle(
                    color: d.ratio! >= 1.5
                        ? AppColors.debit
                        : AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(bottom: 5),
                child: Text(
                  'not enough history to compare',
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
              ),
          ],
        ),

        if (d.hasBudget) ...[
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: d.budgetProgress,
              backgroundColor: Colors.white.withOpacity(0.05),
              color: d.isOverBudget ? AppColors.debit : AppColors.accent,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(d.spentPaise / d.budgetPaise! * 100).round()}% of '
            '${formatPaise(d.budgetPaise!)} budget',
            style: TextStyle(
              color: d.isOverBudget ? AppColors.debit : AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              onEditBudget();
            },
            icon: const Icon(Icons.tune, size: 16, color: AppColors.accent),
            label: Text(
              d.hasBudget ? 'Adjust budget' : 'Set a budget',
              style: const TextStyle(color: AppColors.accent),
            ),
          ),
        ),

        const SizedBox(height: 24),
        const _SectionLabel('Last 6 months'),
        const SizedBox(height: 12),
        TrendChart(points: d.trend, height: 140),

        const SizedBox(height: 28),
        const _SectionLabel('Who spent it'),
        const SizedBox(height: 12),
        if (d.people.isEmpty)
          const Text('Nobody — no spending recorded this month',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13))
        else
          for (final p in d.people) ...[
            _PersonLine(person: p),
            const SizedBox(height: 12),
          ],

        const SizedBox(height: 20),
        // Analytics hands off rather than rebuilding a transaction list of its
        // own. One list implementation, with the search and editing the other
        // one never had.
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: d.transactionCount == 0
                ? null
                : () {
                    Navigator.pop(context);
                    onViewTransactions();
                  },
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: BorderSide(color: AppColors.accent.withOpacity(0.5)),
            ),
            icon: const Icon(Icons.receipt_long_rounded,
                size: 18, color: AppColors.accent),
            label: Text(
              d.transactionCount == 0
                  ? 'No transactions'
                  : 'View all ${d.transactionCount} transactions',
              style: const TextStyle(
                  color: AppColors.accent, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  static String _ratioLabel(double ratio) {
    if (ratio >= 1.05) return '↑ ${ratio.toStringAsFixed(1)}×';
    if (ratio <= 0.95) return '↓ ${((1 - ratio) * 100).round()}% less';
    return '→ about usual';
  }
}

class _PersonLine extends StatelessWidget {
  const _PersonLine({required this.person});

  final PersonRow person;

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
            const Spacer(),
            Text('${(person.share * 100).round()}%',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(width: 12),
            Text(formatPaise(person.spentPaise),
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: person.share.clamp(0.0, 1.0),
            backgroundColor: Colors.white.withOpacity(0.05),
            color: memberColor(person.name),
            minHeight: 6,
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.textSecondary, size: 40),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
      );
}

/// Member colours live here rather than in three screens' private helpers.
Color memberColor(String name) {
  switch (name) {
    case 'Me':
      return AppColors.memberMe;
    case 'Mom':
      return AppColors.memberMom;
    case 'Dad':
      return AppColors.memberDad;
    default:
      return AppColors.textSecondary;
  }
}

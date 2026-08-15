import 'dart:async';

import 'package:flutter/material.dart';

import '../services/analytics_repository.dart';
import '../services/local_db_service.dart';
import '../theme/app_colors.dart';
import '../utils/amount_display.dart';

/// Month-end forecast, told as the sentence it is: this much is projected, this
/// much of it is already spent, this much is still to come.
///
/// Self-contained — it loads its own figure and refreshes itself on database
/// changes — so it can sit on any screen. It reads the projection from
/// [AnalyticsRepository.forecast], the same arithmetic and the same spending
/// rules Analytics uses, so the two screens cannot quote different numbers.
class ForecastCard extends StatefulWidget {
  const ForecastCard({
    super.key,
    this.amountsHidden,
    this.onTap,
  });

  /// Honours the home screen's hide-amounts toggle. Omit it and figures always
  /// show.
  final ValueNotifier<bool>? amountsHidden;

  final VoidCallback? onTap;

  @override
  State<ForecastCard> createState() => _ForecastCardState();
}

class _ForecastCardState extends State<ForecastCard> {
  final AnalyticsRepository _repo = AnalyticsRepository();
  StreamSubscription<void>? _dbChanges;
  Future<ForecastSummary>? _future;

  @override
  void initState() {
    super.initState();
    _future = _repo.forecast();
    _dbChanges = LocalDbService.instance.onChange.listen((_) {
      if (!mounted) return;
      final future = _repo.forecast();
      setState(() {
        _future = future;
      });
    });
  }

  @override
  void dispose() {
    _dbChanges?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ForecastSummary>(
      future: _future,
      builder: (context, snapshot) {
        // No card rather than a broken one: on the home screen a forecast that
        // failed to load must not read as ₹0 projected.
        if (snapshot.hasError || !snapshot.hasData) {
          return const SizedBox.shrink();
        }
        final data = snapshot.data!;
        // Nothing spent yet means nothing to project from. An extrapolation
        // from zero is ₹0, which would say the month is free.
        if (data.isEmpty) return const SizedBox.shrink();

        final hidden = widget.amountsHidden;
        if (hidden == null) return _card(data, false);
        return ValueListenableBuilder<bool>(
          valueListenable: hidden,
          builder: (context, isHidden, _) => _card(data, isHidden),
        );
      },
    );
  }

  Widget _card(ForecastSummary f, bool hidden) {
    final accent = f.isProjectedOver ? AppColors.debit : AppColors.accent;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accent.withOpacity(0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                      f.isProjectedOver
                          ? Icons.trending_up_rounded
                          : Icons.insights_rounded,
                      color: accent,
                      size: 20),
                  const SizedBox(width: 10),
                  Text('Month-end forecast',
                      style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                  const Spacer(),
                  Text('Day ${f.daysElapsed} of ${f.daysInMonth}',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 11)),
                ],
              ),
              const SizedBox(height: 16),

              // The headline is the projection; the two figures under it are
              // the working — what is already gone, and what is still coming.
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(displayPaise(f.forecastPaise, hidden: hidden),
                      style: TextStyle(
                          color: accent,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1)),
                  const SizedBox(width: 8),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 5),
                    child: Text('projected',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: f.spentShare,
                  backgroundColor: Colors.white.withOpacity(0.06),
                  color: accent,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 10),
              _line(
                label: 'Spent so far',
                value: displayPaise(f.spentPaise, hidden: hidden),
                color: AppColors.textPrimary,
              ),
              const SizedBox(height: 4),
              _line(
                label: 'Still to come',
                value: displayPaise(f.stillToComePaise, hidden: hidden),
                color: AppColors.textSecondary,
              ),

              if (f.hasBudget) ...[
                const SizedBox(height: 10),
                Divider(color: Colors.white.withOpacity(0.06), height: 1),
                const SizedBox(height: 10),
                _line(
                  label: f.budgetRemainingPaise >= 0
                      ? 'Left of your ${displayPaise(f.totalBudgetPaise, hidden: hidden)} budget'
                      : 'Over your ${displayPaise(f.totalBudgetPaise, hidden: hidden)} budget',
                  value: displayPaise(f.budgetRemainingPaise.abs(),
                      hidden: hidden),
                  color: f.budgetRemainingPaise >= 0
                      ? AppColors.credit
                      : AppColors.debit,
                ),
                if (f.isProjectedOver) ...[
                  const SizedBox(height: 8),
                  Text(
                    '⚠ On pace to exceed it by '
                    '${displayPaise(f.projectedOverPaise, hidden: hidden)}',
                    style: const TextStyle(
                        color: AppColors.debit, fontSize: 11),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _line({
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12)),
        ),
        const SizedBox(width: 12),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

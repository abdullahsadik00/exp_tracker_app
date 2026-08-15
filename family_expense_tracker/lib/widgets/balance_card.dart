import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../utils/amount_display.dart';

/// The one card the dashboard uses for every figure it shows.
///
/// Deliberately flat — a surface and a hairline border rather than the gradient
/// and drop shadow the old carousel cards carried. With five of them on screen
/// at once, the decoration was competing with the numbers.
class BalanceCard extends StatelessWidget {
  const BalanceCard({
    super.key,
    required this.title,
    required this.amount,
    required this.hidden,
    this.caption,
    this.accent,
    this.trailing,
    this.footer,
    this.signed = false,
    this.emphasis = BalanceCardEmphasis.normal,
  });

  final String title;
  final double amount;

  /// When true the amount is masked. Labels and captions stay readable — only
  /// the money is sensitive.
  final bool hidden;

  /// What the number means, e.g. "this month". Mom and Dad are people, not
  /// accounts, so their figure must never read as a balance.
  final String? caption;

  final Color? accent;

  /// Optional badge shown beside the title, e.g. the reconciliation chip.
  final Widget? trailing;

  /// Optional content below the amount, e.g. this month's in/out figures.
  final Widget? footer;

  /// Show an explicit sign and colour the amount by direction.
  final bool signed;

  final BalanceCardEmphasis emphasis;

  bool get _isPrimary => emphasis == BalanceCardEmphasis.primary;

  @override
  Widget build(BuildContext context) {
    final Color amountColor;
    if (hidden || !signed) {
      amountColor = AppColors.textPrimary;
    } else if (amount < 0) {
      amountColor = AppColors.debit;
    } else {
      amountColor = AppColors.credit;
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(_isPrimary ? 20 : 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: (accent ?? Colors.white).withOpacity(accent != null ? 0.3 : 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent ?? AppColors.textSecondary,
                    fontSize: _isPrimary ? 13 : 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
          SizedBox(height: _isPrimary ? 8 : 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              signed
                  ? displaySignedAmount(amount, hidden: hidden, decimals: 0)
                  : displayAmount(amount, hidden: hidden, decimals: 0),
              style: TextStyle(
                color: amountColor,
                fontSize: _isPrimary ? 32 : 20,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
              ),
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 4),
            Text(
              caption!,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
          if (footer != null) ...[
            const SizedBox(height: 16),
            footer!,
          ],
        ],
      ),
    );
  }
}

enum BalanceCardEmphasis { normal, primary }

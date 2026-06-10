import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class CategoryMetricCard extends StatelessWidget {
  final String label;
  final String value;
  final String? subValue;
  final IconData icon;
  final Color iconColor;
  final bool isTrendPositive; // Positive for bad (e.g., spending increased), but here we follow UI color
  final double? trendPercentage;

  const CategoryMetricCard({
    super.key,
    required this.label,
    required this.value,
    this.subValue,
    required this.icon,
    this.iconColor = AppColors.accent,
    this.isTrendPositive = false,
    this.trendPercentage,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 16),
              ),
              const Spacer(),
              if (trendPercentage != null)
                Row(
                  children: [
                    Icon(
                      isTrendPositive ? Icons.trending_up : Icons.trending_down,
                      color: isTrendPositive ? AppColors.debit : AppColors.credit,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${trendPercentage!.toStringAsFixed(0)}%',
                      style: TextStyle(
                        color: isTrendPositive ? AppColors.debit : AppColors.credit,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (subValue != null)
            Padding(
              padding: const EdgeInsets.only(top: 2.0),
              child: Text(
                subValue!,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 10,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

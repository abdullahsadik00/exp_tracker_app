import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class SpendingChartBar extends StatefulWidget {
  final String label;
  final double amount;
  final double heightPercentage;
  final bool isAboveAverage;
  final bool isCurrentMonth;

  const SpendingChartBar({
    super.key,
    required this.label,
    required this.amount,
    required this.heightPercentage,
    this.isAboveAverage = false,
    this.isCurrentMonth = false,
  });

  @override
  State<SpendingChartBar> createState() => _SpendingChartBarState();
}

class _SpendingChartBarState extends State<SpendingChartBar> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0, end: widget.heightPercentage).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _controller.forward();
  }

  @override
  void didUpdateWidget(SpendingChartBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.heightPercentage != widget.heightPercentage) {
      _animation = Tween<double>(begin: _animation.value, end: widget.heightPercentage).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      );
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (widget.amount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 4.0),
            child: Text(
              widget.amount >= 1000 
                ? '${(widget.amount / 1000).toStringAsFixed(1)}k' 
                : widget.amount.toStringAsFixed(0),
              style: TextStyle(
                color: widget.isCurrentMonth ? AppColors.accent : AppColors.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        AnimatedBuilder(
          animation: _animation,
          builder: (context, child) {
            return Container(
              width: 14,
              height: 120 * _animation.value.clamp(0.05, 1.0),
              decoration: BoxDecoration(
                color: widget.isCurrentMonth 
                  ? AppColors.accent 
                  : (widget.isAboveAverage ? AppColors.debit.withOpacity(0.7) : AppColors.credit.withOpacity(0.7)),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                boxShadow: widget.isCurrentMonth ? [
                  BoxShadow(
                    color: AppColors.accent.withOpacity(0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  )
                ] : null,
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          widget.label,
          style: TextStyle(
            color: widget.isCurrentMonth ? AppColors.textPrimary : AppColors.textSecondary,
            fontSize: 10,
            fontWeight: widget.isCurrentMonth ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}

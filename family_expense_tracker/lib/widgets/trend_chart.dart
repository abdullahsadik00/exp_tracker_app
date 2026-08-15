import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../services/analytics_repository.dart';
import '../theme/app_colors.dart';
import '../utils/amount_display.dart';

/// The one trend component, used at both scopes: all spending on the Analytics
/// screen, one category inside the category sheet.
///
/// It replaces the two charts that used to answer this question separately — a
/// 12-month line and a 6-month bar chart, with different windows, different
/// axis maths and different bugs. Scope is a parameter now, not a second
/// implementation.
class TrendChart extends StatefulWidget {
  const TrendChart({
    super.key,
    required this.points,
    this.onMonthTap,
    this.height = 170,
  });

  final List<TrendPoint> points;

  /// When provided, tapping a month selects it. The chart is otherwise a
  /// read-only figure — and says so by not reacting.
  final ValueChanged<String>? onMonthTap;

  final double height;

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  int? _touchedIndex;

  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    if (points.isEmpty) return const SizedBox.shrink();

    // The readout follows the finger while touched, and otherwise reports the
    // month the rest of the screen is showing.
    final selected = points.indexWhere((p) => p.isSelected);
    final touched = _touchedIndex;
    final int readoutIndex = (touched != null &&
            touched >= 0 &&
            touched < points.length)
        ? touched
        : (selected >= 0 ? selected : points.length - 1);
    final readout = points[readoutIndex];

    final maxValue = points.fold<int>(
        0, (m, p) => (p.paise ?? 0) > m ? (p.paise ?? 0) : m);
    final maxY = maxValue > 0 ? maxValue * 1.25 : 1000.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A persistent readout instead of a floating tooltip: on a phone the
        // finger covers the tooltip it just summoned.
        Row(
          children: [
            Text(
              '${readout.label} ${readout.ym.substring(0, 4)}',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(width: 8),
            Text(
              readout.paise == null
                  ? 'no data'
                  : formatPaise(readout.paise!),
              style: TextStyle(
                color: readout.paise == null
                    ? AppColors.textSecondary
                    : AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: widget.height,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: (points.length - 1).toDouble(),
              minY: 0,
              maxY: maxY.toDouble(),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: maxY / 2,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: Colors.white.withOpacity(0.05),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                // A visible money scale. The old chart hid every axis, which
                // left the line shaped like information but carrying none.
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    interval: maxY / 2,
                    getTitlesWidget: (value, meta) {
                      if (value <= 0) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          formatCompactRupees(value.round()),
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    interval: 1,
                    getTitlesWidget: (value, meta) {
                      final i = value.round();
                      if (i < 0 || i >= points.length) {
                        return const SizedBox.shrink();
                      }
                      // Crowded axes get every other label; the selected month
                      // is always labelled, whatever the interval.
                      final dense = points.length > 8;
                      final p = points[i];
                      if (dense && !p.isSelected && i.isOdd) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          p.label,
                          style: TextStyle(
                            color: p.isSelected
                                ? AppColors.accent
                                : AppColors.textSecondary,
                            fontSize: 10,
                            fontWeight: p.isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                enabled: true,
                handleBuiltInTouches: false,
                touchCallback: (event, response) {
                  final spot = response?.lineBarSpots?.firstOrNull;
                  if (spot == null) {
                    if (_touchedIndex != null) {
                      setState(() => _touchedIndex = null);
                    }
                    return;
                  }
                  final index = spot.spotIndex;
                  if (index != _touchedIndex) {
                    setState(() => _touchedIndex = index);
                  }
                  if (event is FlTapUpEvent &&
                      index >= 0 &&
                      index < points.length) {
                    widget.onMonthTap?.call(points[index].ym);
                  }
                },
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < points.length; i++)
                      // A month with no transactions at all is a gap, not a
                      // zero — the chart must not claim we spent nothing in a
                      // month we simply were not tracking yet.
                      points[i].paise == null
                          ? FlSpot.nullSpot
                          : FlSpot(i.toDouble(),
                              points[i].paise!.toDouble()),
                  ],
                  isCurved: true,
                  preventCurveOverShooting: true,
                  color: AppColors.accent,
                  barWidth: 3,
                  isStrokeCapRound: true,
                  dotData: FlDotData(
                    show: true,
                    checkToShowDot: (spot, _) {
                      final i = spot.x.round();
                      return i == readoutIndex ||
                          (i >= 0 &&
                              i < points.length &&
                              points[i].isSelected);
                    },
                    getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                      radius: spot.x.round() == readoutIndex ? 5 : 4,
                      color: AppColors.accent,
                      strokeWidth: 2,
                      strokeColor: AppColors.surface,
                    ),
                  ),
                  belowBarData: BarAreaData(
                    show: true,
                    color: AppColors.accent.withOpacity(0.10),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (widget.onMonthTap != null) ...[
          const SizedBox(height: 8),
          const Text(
            'Tap a month to switch to it',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

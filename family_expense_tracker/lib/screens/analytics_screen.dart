import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../models/transaction_model.dart';
import '../services/local_db_service.dart';
import '../theme/app_colors.dart';
import 'category_insights_screen.dart';
import 'package:intl/intl.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  final LocalDbService _localDbService = LocalDbService();
  int touchedIndex = -1;
  late String _selectedMonth;

  @override
  void initState() {
    super.initState();
    _selectedMonth = DateFormat('MMM yyyy').format(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Analytics', 
          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: StreamBuilder<List<String>>(
        stream: _localDbService.availableMonthsStream,
        builder: (context, monthSnapshot) {
          if (monthSnapshot.connectionState == ConnectionState.waiting && !monthSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: AppColors.accent));
          }
          final sortedMonths = monthSnapshot.data ?? [DateFormat('MMM yyyy').format(DateTime.now())];
          if (!_selectedMonth.contains(' ') || !sortedMonths.contains(_selectedMonth)) {
             _selectedMonth = sortedMonths.first;
          }

          return FutureBuilder<List<TransactionModel>>(
            future: _localDbService.getTransactionsByMonth(_selectedMonth),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                return const Center(child: CircularProgressIndicator(color: AppColors.accent));
              }
              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}', style: const TextStyle(color: Colors.red)));
              }

              final transactions = snapshot.data ?? [];
              final debitTotals = _calculateDebitTotals(transactions);
              final totalDebit = debitTotals.values.fold(0.0, (sum, val) => sum + val);

              return SingleChildScrollView(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    _buildMonthFilter(sortedMonths),
                    const SizedBox(height: 24),
                    _buildTrendsButton(),
                    const SizedBox(height: 24),
                    if (totalDebit == 0) 
                      _buildEmptyState()
                    else ...[
                      _buildInsightCard(totalDebit),
                  const SizedBox(height: 32),
                  _buildYearlyTrendSection(),
                  const SizedBox(height: 32),
                  _buildChartSection(debitTotals),
                      const SizedBox(height: 32),
                      _buildLegendSection(debitTotals),
                    ],
                    const SizedBox(height: 48),
                    const SizedBox(height: 24),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildMonthFilter(List<String> months) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          const Icon(Icons.calendar_today_rounded, color: AppColors.accent, size: 20),
          const SizedBox(width: 12),
          const Text('Report for:', style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          const Spacer(),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: months.contains(_selectedMonth) ? _selectedMonth : months.first,
              dropdownColor: AppColors.surface,
              icon: const Icon(Icons.arrow_drop_down, color: AppColors.accent),
              style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 15),
              items: months.map((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: (newValue) {
                if (newValue != null) {
                  setState(() {
                    _selectedMonth = newValue;
                  });
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Map<String, double> _calculateDebitTotals(List<TransactionModel> transactions) {
    final totals = <String, double>{
      'Me': 0.0,
      'Mom': 0.0,
      'Dad': 0.0,
    };

    for (final txn in transactions) {
      if (txn.type == 'debit' && totals.containsKey(txn.assignedTo)) {
        totals[txn.assignedTo] = totals[txn.assignedTo]! + txn.amount;
      }
    }
    return totals;
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.pie_chart_outline, color: AppColors.textSecondary, size: 64),
          SizedBox(height: 16),
          Text('No spending data available yet', 
            style: TextStyle(color: AppColors.textSecondary, fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildInsightCard(double total) {
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 0);
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
          const Text('Total Family Spending', 
            style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          const SizedBox(height: 8),
          Text(currencyFormat.format(total),
            style: const TextStyle(
              color: AppColors.textPrimary, 
              fontSize: 32, 
              fontWeight: FontWeight.bold
            )),
        ],
      ),
    );
  }

  Widget _buildChartSection(Map<String, double> totals) {
    return AspectRatio(
      aspectRatio: 1.3,
      child: PieChart(
        PieChartData(
          pieTouchData: PieTouchData(
            touchCallback: (FlTouchEvent event, pieTouchResponse) {
              setState(() {
                if (!event.isInterestedForInteractions ||
                    pieTouchResponse == null ||
                    pieTouchResponse.touchedSection == null) {
                  touchedIndex = -1;
                  return;
                }
                touchedIndex = pieTouchResponse.touchedSection!.touchedSectionIndex;
              });
            },
          ),
          borderData: FlBorderData(show: false),
          sectionsSpace: 4,
          centerSpaceRadius: 50,
          sections: _getSections(totals),
        ),
      ),
    );
  }

  List<PieChartSectionData> _getSections(Map<String, double> totals) {
    final list = <PieChartSectionData>[];
    int i = 0;
    
    totals.forEach((person, amount) {
      if (amount > 0) {
        final isTouched = i == touchedIndex;
        final fontSize = isTouched ? 20.0 : 16.0;
        final radius = isTouched ? 65.0 : 55.0;
        final opacity = isTouched ? 1.0 : 0.85;

        list.add(
          PieChartSectionData(
            color: _getColorForPerson(person).withOpacity(opacity),
            value: amount,
            title: '${((amount / totals.values.fold(0.0, (sum, val) => sum + val)) * 100).toStringAsFixed(0)}%',
            radius: radius,
            titleStyle: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
        );
      }
      i++;
    });
    return list;
  }

  Widget _buildLegendSection(Map<String, double> totals) {
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 0);

    return Column(
      children: totals.entries.map((entry) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: _getColorForPerson(entry.key),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Text(entry.key, 
                style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(currencyFormat.format(entry.value), 
                style: const TextStyle(color: AppColors.textSecondary)),
            ],
          ),
        );
      }).toList(),
    );
  }

  Color _getColorForPerson(String person) {
    switch (person) {
      case 'Me': return AppColors.memberMe;
      case 'Mom': return AppColors.memberMom;
      case 'Dad': return AppColors.memberDad;
      default: return AppColors.textSecondary;
    }
  }



  Widget _buildTrendsButton() {
    return Container(
      width: double.infinity,
      height: 100,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.accent, Color(0xFF6366F1)], // Indigo-Violet gradient
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withOpacity(0.3),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onHighlightChanged: (v) {},
          borderRadius: BorderRadius.circular(24),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const CategoryInsightsScreen()),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.auto_graph_rounded, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text('View Detailed Category Trends', 
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis),
                      SizedBox(height: 4),
                      Text('Analyze peak months & averages', 
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                        overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right_rounded, color: Colors.white70),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildYearlyTrendSection() {
    return StreamBuilder<Map<String, double>>(
      stream: _localDbService.yearlySpendingTrendStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
        
        final trend = snapshot.data!;
        final maxVal = trend.values.fold(0.0, (m, v) => v > m ? v : m);
        final maxY = maxVal > 0 ? maxVal * 1.2 : 1000.0;

        return Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.05)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Spending Trend (12 Months)', 
                style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 32),
              AspectRatio(
                aspectRatio: 1.7,
                child: LineChart(
                  LineChartData(
                    gridData: FlGridData(show: false),
                    titlesData: FlTitlesData(
                      leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          interval: 2,
                          getTitlesWidget: (value, meta) {
                            int idx = value.toInt();
                            if (idx < 0 || idx >= trend.length) return const SizedBox();
                            return Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: Text(trend.keys.elementAt(idx), 
                                style: const TextStyle(color: AppColors.textSecondary, fontSize: 10)),
                            );
                          },
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    minX: 0,
                    maxX: 11,
                    minY: 0,
                    maxY: maxY,
                    lineBarsData: [
                      LineChartBarData(
                        spots: trend.values.toList().asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value)).toList(),
                        isCurved: true,
                        color: AppColors.accent,
                        barWidth: 4,
                        isStrokeCapRound: true,
                        dotData: FlDotData(show: false),
                        belowBarData: BarAreaData(
                          show: true,
                          color: AppColors.accent.withOpacity(0.1),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }
    );
  }
}

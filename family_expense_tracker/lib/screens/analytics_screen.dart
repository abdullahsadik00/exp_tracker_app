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

  // Read once, not on every build — a StreamBuilder handed a freshly minted
  // stream re-subscribes and re-queries on every rebuild.
  late final Stream<List<String>> _monthsStream =
      _localDbService.availableMonthsStream;
  late final Stream<Map<String, double>> _yearlyTrendStream =
      _localDbService.yearlySpendingTrendStream;
  late final Stream<Map<String, dynamic>> _forecastStream =
      _localDbService.forecastStream;
  late final Stream<List<Map<String, dynamic>>> _anomaliesStream =
      _localDbService.anomaliesStream;
  late final Stream<List<Map<String, dynamic>>> _budgetProgressStream =
      _localDbService.budgetProgressStream;

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
        stream: _monthsStream,
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
                      const SizedBox(height: 8),
                      const Center(
                        child: Text('Tap a segment to highlight',
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                      ),
                      const SizedBox(height: 24),
                      _buildLegendSection(debitTotals),
                    ],
                    // Deliberately outside the "no spending" branch above: a
                    // forecast and a budget matter most in a month that has
                    // not been spent in yet.
                    const SizedBox(height: 32),
                    _buildSmartInsightsSection(),
                    const SizedBox(height: 32),
                    _buildSectionHeader('Monthly Budgets'),
                    const SizedBox(height: 16),
                    _buildBudgetSection(),
                    const SizedBox(height: 48),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pie_chart_outline, color: AppColors.textSecondary.withOpacity(0.4), size: 64),
            const SizedBox(height: 16),
            Text('No spending data for $_selectedMonth',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('Add transactions or select a different month',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
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
        i++;
      }
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
      stream: _yearlyTrendStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox(
          height: 200,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: AppColors.accent),
                SizedBox(height: 12),
                Text('Loading spending trend...', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
              ],
            ),
          ),
        );
        
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

  // ── Smart Insights ──────────────────────────────────────────────────────────
  // Moved here from the dashboard, which had grown into a second analytics
  // screen. Unchanged in behaviour — same streams, same queries.

  Widget _buildSectionHeader(String title) {
    return Row(
      children: [
        Text(title,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold
          )),
      ],
    );
  }

  Widget _buildSmartInsightsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('Smart Insights'),
        const SizedBox(height: 16),
        _buildForecastCard(),
        const SizedBox(height: 12),
        _buildAnomaliesCard(),
      ],
    );
  }

  Widget _buildForecastCard() {
    return StreamBuilder<Map<String, dynamic>>(
      stream: _forecastStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final data = snapshot.data!;
        final current = data['currentSpend'] as double;
        final forecast = data['forecastedSpend'] as double;
        final daysElapsed = data['daysElapsed'] as int;
        final totalDays = data['totalDays'] as int;
        final totalBudget = data['totalBudget'] as double;
        final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 0);

        if (forecast == 0) return const SizedBox.shrink();

        final hasBudget = totalBudget > 0;
        final isOver = hasBudget && forecast > totalBudget;
        final progress = hasBudget ? (forecast / totalBudget).clamp(0.0, 1.0) : null;
        final accentColor = isOver ? AppColors.debit : AppColors.accent;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accentColor.withOpacity(0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(isOver ? Icons.trending_up_rounded : Icons.insights_rounded,
                      color: accentColor, size: 20),
                  const SizedBox(width: 10),
                  Text('Month-End Forecast',
                      style: TextStyle(
                          color: accentColor, fontWeight: FontWeight.bold, fontSize: 14)),
                  const Spacer(),
                  Text('Day $daysElapsed / $totalDays',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(currencyFormat.format(forecast),
                      style: TextStyle(
                          color: accentColor,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1)),
                  const SizedBox(width: 8),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text('projected',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                  ),
                  if (hasBudget) ...[
                    const Spacer(),
                    Text(
                      '/ ${currencyFormat.format(totalBudget)} budget',
                      style: TextStyle(
                          color: isOver ? AppColors.debit : AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${currencyFormat.format(current)} spent so far',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              if (progress != null) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.white.withOpacity(0.05),
                    color: accentColor,
                    minHeight: 5,
                  ),
                ),
                if (isOver)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '⚠ Projected to exceed budget by ${currencyFormat.format(forecast - totalBudget)}',
                      style: const TextStyle(color: AppColors.debit, fontSize: 11),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildAnomaliesCard() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _anomaliesStream,
      builder: (context, snapshot) {
        final anomalies = snapshot.data ?? [];
        if (anomalies.isEmpty) return const SizedBox.shrink();

        final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 0);

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.amber.withOpacity(0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 20),
                  const SizedBox(width: 10),
                  const Text('Spending Spikes',
                      style: TextStyle(
                          color: Colors.amber,
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                  const Spacer(),
                  Text('vs 3-month avg',
                      style: TextStyle(
                          color: AppColors.textSecondary.withOpacity(0.6), fontSize: 11)),
                ],
              ),
              const SizedBox(height: 16),
              ...anomalies.take(3).map((a) {
                final cat = a['category'] as String;
                final current = a['currentAmount'] as double;
                final avg = a['avgAmount'] as double;
                final ratio = a['ratio'] as double;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(cat,
                                style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14)),
                            const SizedBox(height: 2),
                            Text(
                              '${currencyFormat.format(current)} this month  •  avg ${currencyFormat.format(avg)}',
                              style: const TextStyle(
                                  color: AppColors.textSecondary, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.debit.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '↑ ${ratio.toStringAsFixed(1)}×',
                          style: const TextStyle(
                              color: AppColors.debit,
                              fontWeight: FontWeight.bold,
                              fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  // ── Budgets ─────────────────────────────────────────────────────────────────

  Widget _buildBudgetSection() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _budgetProgressStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData || (snapshot.data?.isEmpty ?? true)) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: AppColors.textSecondary, size: 20),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('No budgets set. Click here to start budgeting!',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                ),
                TextButton(
                  onPressed: () => _showSetBudgetDialog(context),
                  child: const Text('Add', style: TextStyle(color: AppColors.accent)),
                )
              ],
            ),
          );
        }

        final budgets = snapshot.data!;
        return SizedBox(
          height: 110,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: budgets.length + 1,
            itemBuilder: (context, index) {
              if (index == budgets.length) {
                return _buildAddBudgetCard();
              }
              final budget = budgets[index];
              return _buildBudgetCard(budget);
            },
          ),
        );
      }
    );
  }

  Widget _buildBudgetCard(Map<String, dynamic> budget) {
    final spent = budget['spent'] as double;
    final limit = budget['limit'] as double;
    final category = budget['category'] as String;
    final percent = (spent / limit).clamp(0.0, 1.0);
    final isOver = spent > limit;

    return Container(
      width: 180,
      margin: const EdgeInsets.only(right: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isOver ? Colors.red.withOpacity(0.3) : Colors.white.withOpacity(0.05)),
      ),
      child: InkWell(
        onTap: () => _showSetBudgetDialog(context, category: category, currentAmount: limit),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(category,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
                Text('${(percent * 100).toStringAsFixed(0)}%',
                  style: TextStyle(color: isOver ? Colors.red : AppColors.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                Text('₹${spent.toStringAsFixed(0)}', style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.bold)),
                Text(' / ₹${limit.toStringAsFixed(0)}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 10)),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: percent,
                backgroundColor: Colors.white.withOpacity(0.05),
                color: isOver ? Colors.red : AppColors.accent,
                minHeight: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddBudgetCard() {
    return Container(
      width: 60,
      margin: const EdgeInsets.only(right: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05), style: BorderStyle.solid),
      ),
      child: IconButton(
        onPressed: () => _showSetBudgetDialog(context),
        icon: const Icon(Icons.add, color: AppColors.textSecondary),
      ),
    );
  }

  void _showSetBudgetDialog(BuildContext context, {String? category, double? currentAmount}) {
    final amountController = TextEditingController(text: currentAmount?.toStringAsFixed(0) ?? '');
    String selectedCategory = category ?? TransactionModel.availableCategories.first;
    String? suggestionText;
    bool loadingStarted = false;

    Future<void> loadSuggestion(String cat, Function setDialogState) async {
      final avg = await _localDbService.getCategoryAverage(cat);
      if (avg > 0) {
        setDialogState(() {
          suggestionText = '3-month avg: ₹${avg.toStringAsFixed(0)}';
          if (amountController.text.isEmpty) {
            amountController.text = avg.toStringAsFixed(0);
          }
        });
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          if (category == null && suggestionText == null && !loadingStarted) {
            loadingStarted = true;
            loadSuggestion(selectedCategory, setDialogState);
          }
          return AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(category == null ? 'Set New Budget' : 'Update $category Budget',
              style: const TextStyle(color: AppColors.textPrimary)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (category == null)
                  DropdownButtonFormField<String>(
                    value: selectedCategory,
                    dropdownColor: AppColors.surface,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      labelStyle: TextStyle(color: AppColors.textSecondary)),
                    items: TransactionModel.availableCategories
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                    onChanged: (val) {
                      selectedCategory = val!;
                      amountController.clear();
                      loadingStarted = false;
                      setDialogState(() => suggestionText = null);
                      loadSuggestion(val, setDialogState);
                    },
                  ),
                const SizedBox(height: 16),
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  autofocus: category != null,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Monthly Limit (₹)',
                    labelStyle: const TextStyle(color: AppColors.textSecondary),
                    helperText: suggestionText,
                    helperStyle: const TextStyle(color: AppColors.accent, fontSize: 11),
                    enabledBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: AppColors.accent)),
                    focusedBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: AppColors.accent, width: 2)),
                  ),
                ),
              ],
            ),
            actions: [
              if (category != null)
                TextButton(
                  onPressed: () async {
                    await _localDbService.deleteBudget(category);
                    if (mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Delete', style: TextStyle(color: Colors.red)),
                ),
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  final amount = double.tryParse(amountController.text);
                  if (amount != null && amount > 0) {
                    await _localDbService.saveBudget(selectedCategory, amount);
                    if (mounted) Navigator.pop(ctx);
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                child: const Text('Save', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }
}

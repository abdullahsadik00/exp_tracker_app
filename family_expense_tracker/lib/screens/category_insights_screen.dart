import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/transaction_model.dart';
import '../services/local_db_service.dart';
import '../theme/app_colors.dart';


class CategoryInsightsScreen extends StatefulWidget {
  const CategoryInsightsScreen({super.key});

  @override
  State<CategoryInsightsScreen> createState() => _CategoryInsightsScreenState();
}

class _CategoryInsightsScreenState extends State<CategoryInsightsScreen> {
  final LocalDbService _localDbService = LocalDbService();
  List<TransactionModel> _allTransactions = [];
  List<String> _categories = [];
  String? _selectedCategory;

  // Analysis results
  double _avgMonthlySpend = 0.0;
  String _peakMonthName = 'N/A';
  double _peakMonthAmount = 0.0;
  String _lowestMonthName = 'N/A';
  double _lowestMonthAmount = 0.0;
  
  // Drill-down state
  String? _selectedMonthYear;
  List<String> _availableMonthYears = [];
  List<TransactionModel> _drillDownTransactions = [];

  Map<String, double> _last6MonthsTrends = {};
  Map<String, double> _familySplit = {'Me': 0.0, 'Mom': 0.0, 'Dad': 0.0};
  int _itemsPerPage = 50;
  int _currentPage = 1;

  void _runAnalysis() {
    if (_selectedCategory == null) return;

    final filtered = _allTransactions
        .where((t) => t.category == _selectedCategory && t.type == 'debit')
        .toList();

    // 1. Group by Month (All-Time)
    Map<String, double> monthlySpendMap = {};
    Map<String, List<TransactionModel>> monthlyTransactionsMap = {};

    for (var t in filtered) {
      String monthKey = DateFormat('MMM yyyy').format(t.date);
      monthlySpendMap[monthKey] = (monthlySpendMap[monthKey] ?? 0.0) + t.amount;
      monthlyTransactionsMap.putIfAbsent(monthKey, () => []).add(t);
    }

    // 2. All-Time Averages and Extremas
    if (monthlySpendMap.isNotEmpty) {
      // Average
      _avgMonthlySpend = monthlySpendMap.values.fold(0.0, (sum, val) => sum + val) / monthlySpendMap.length;

      // Peak (Highest)
      var peakEntry = monthlySpendMap.entries.reduce((a, b) => a.value > b.value ? a : b);
      _peakMonthName = peakEntry.key;
      _peakMonthAmount = peakEntry.value;

      // Lowest (Ignoring ₹0 or months with no data already filtered by map inclusion)
      var nonZeroMonths = monthlySpendMap.entries.where((e) => e.value > 0).toList();
      if (nonZeroMonths.isNotEmpty) {
        var lowEntry = nonZeroMonths.reduce((a, b) => a.value < b.value ? a : b);
        _lowestMonthName = lowEntry.key;
        _lowestMonthAmount = lowEntry.value;
      } else {
        _lowestMonthName = 'N/A';
        _lowestMonthAmount = 0.0;
      }
    } else {
      _avgMonthlySpend = 0.0;
      _peakMonthName = 'N/A';
      _peakMonthAmount = 0.0;
      _lowestMonthName = 'N/A';
      _lowestMonthAmount = 0.0;
    }

    // 3. Last 6 Months Trends (for Chart)
    _last6MonthsTrends = {};
    for (int i = 5; i >= 0; i--) {
      DateTime date = DateTime(DateTime.now().year, DateTime.now().month - i, 1);
      String monthKey = DateFormat('MMM yyyy').format(date);
      _last6MonthsTrends[monthKey] = monthlySpendMap[monthKey] ?? 0.0;
    }

    // 4. Family Split
    _familySplit = {'Me': 0.0, 'Mom': 0.0, 'Dad': 0.0};
    for (var t in filtered) {
      if (_familySplit.containsKey(t.assignedTo)) {
        _familySplit[t.assignedTo] = (_familySplit[t.assignedTo] ?? 0.0) + t.amount;
      }
    }

    // 5. Monthly Drill-Down State
    // Sort available months Latest to Oldest
    List<DateTime> monthDates = monthlySpendMap.keys.map((k) => DateFormat('MMM yyyy').parse(k)).toList();
    monthDates.sort((a, b) => b.compareTo(a));
    _availableMonthYears = monthDates.map((d) => DateFormat('MMM yyyy').format(d)).toList();

    // Default scroll target to latest available month or current month if changed
    if (_availableMonthYears.isNotEmpty) {
      _selectedMonthYear = _availableMonthYears.first;
      _drillDownTransactions = monthlyTransactionsMap[_selectedMonthYear!] ?? [];
      _drillDownTransactions.sort((a, b) => b.date.compareTo(a.date)); // Sort transactions inside month
    } else {
      _selectedMonthYear = null;
      _drillDownTransactions = [];
    }
    _currentPage = 1; // Reset pagination on category change
  }

  void _updateDrillDown(String monthYear) {
    setState(() {
      _selectedMonthYear = monthYear;
      _drillDownTransactions = _allTransactions
          .where((t) => 
            t.category == _selectedCategory && 
            t.type == 'debit' && 
            DateFormat('MMM yyyy').format(t.date) == monthYear)
          .toList();
      _drillDownTransactions.sort((a, b) => b.date.compareTo(a.date));
      _currentPage = 1; // Reset pagination on month change
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Category Insights', 
          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: FutureBuilder<List<TransactionModel>>(
        future: _localDbService.getAllTransactions(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: AppColors.accent),
                  SizedBox(height: 16),
                  Text('Analyzing transactions...', style: TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            );
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}', style: const TextStyle(color: Colors.red)));
          }

          if (snapshot.hasData) {
            _allTransactions = snapshot.data!;
            _categories = _allTransactions
                .map((t) => t.category)
                .where((c) => c != 'Income' && c != 'Other')
                .toSet()
                .toList();
            
            if (_categories.isNotEmpty) {
              Map<String, int> counts = {};
              for (var t in _allTransactions) {
                counts[t.category] = (counts[t.category] ?? 0) + 1;
              }
              _categories.sort((a, b) => (counts[b] ?? 0).compareTo(counts[a] ?? 0));
              
              _selectedCategory ??= _categories.first;
              _runAnalysis();
            }
          }

          if (_allTransactions.isEmpty) {
            return const Center(child: Text('No transactions found', style: TextStyle(color: AppColors.textSecondary)));
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCategoryDropdown(),
                const SizedBox(height: 32),
                _buildSummaryGrid(),
                const SizedBox(height: 32),
                _buildTrendSection(),
                const SizedBox(height: 32),
                _buildFamilyBreakdown(),
                const SizedBox(height: 40),
                _buildDrillDownSection(),
                const SizedBox(height: 48),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCategoryDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedCategory,
          dropdownColor: AppColors.surface,
          isExpanded: true,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.accent),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
          items: _categories.map((cat) {
            return DropdownMenuItem(
              value: cat,
              child: Row(
                children: [
                  const Icon(Icons.category_outlined, size: 18, color: AppColors.textSecondary),
                  const SizedBox(width: 12),
                  Text(cat),
                ],
              ),
            );
          }).toList(),
          onChanged: (val) {
            setState(() {
              _selectedCategory = val;
              _runAnalysis();
            });
          },
        ),
      ),
    );
  }

  Widget _buildSummaryGrid() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _buildSummaryCard('All-Time Avg', _avgMonthlySpend, color: AppColors.accent)),
            const SizedBox(width: 16),
            Expanded(child: _buildSummaryCard('Highest Month', _peakMonthAmount, subtitle: _peakMonthName, color: Colors.orangeAccent)),
          ],
        ),
        const SizedBox(height: 16),
        _buildSummaryCard('Lowest Month', _lowestMonthAmount, subtitle: _lowestMonthName, isWide: true, color: Colors.cyanAccent),
      ],
    );
  }

  Widget _buildSummaryCard(String title, double amount, {String? subtitle, Color color = AppColors.accent, bool isWide = false}) {
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 0);
    return Container(
      width: isWide ? double.infinity : null,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, 
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(currencyFormat.format(amount), 
              style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.bold)),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, 
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }

  Widget _buildTrendSection() {
    double maxY = _peakMonthAmount > 0 ? _peakMonthAmount * 1.2 : 1000.0;
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
          const Text('6-Month Trend', 
            style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 32),
          AspectRatio(
            aspectRatio: 1.5,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: maxY,
                barTouchData: BarTouchData(enabled: true),
                titlesData: FlTitlesData(
                  show: true,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        int index = value.toInt();
                        if (index < 0 || index >= _last6MonthsTrends.length) return const SizedBox();
                        String key = _last6MonthsTrends.keys.elementAt(index);
                        return Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text(key.split(' ').first, 
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 10)),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                gridData: FlGridData(show: false),
                borderData: FlBorderData(show: false),
                barGroups: _last6MonthsTrends.entries.toList().asMap().entries.map((entry) {
                  return BarChartGroupData(
                    x: entry.key,
                    barRods: [
                      BarChartRodData(
                        toY: entry.value.value > 0 ? entry.value.value : (maxY * 0.015),
                        color: entry.value.value > 0 ? AppColors.accent : AppColors.textSecondary.withOpacity(0.25),
                        width: 16,
                        borderRadius: const BorderRadius.only(topLeft: Radius.circular(4), topRight: Radius.circular(4)),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFamilyBreakdown() {
    double total = _familySplit.values.fold(0.0, (sum, val) => sum + val);
    
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
          const Text('Family Contribution', 
            style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 24),
          _buildContributionRow('Me', _familySplit['Me']!, total, AppColors.memberMe),
          const SizedBox(height: 16),
          _buildContributionRow('Mom', _familySplit['Mom']!, total, AppColors.memberMom),
          const SizedBox(height: 16),
          _buildContributionRow('Dad', _familySplit['Dad']!, total, AppColors.memberDad),
        ],
      ),
    );
  }

  Widget _buildContributionRow(String name, double amount, double total, Color color) {
    double percent = total > 0 ? amount / total : 0.0;
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 0);
    
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(name, style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
            Text(currencyFormat.format(amount), style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: percent,
            backgroundColor: Colors.white.withOpacity(0.05),
            color: color,
            minHeight: 8,
          ),
        ),
      ],
    );
  }

  Widget _buildDrillDownSection() {
    // Pagination Logic
    int totalPages = (_drillDownTransactions.length / _itemsPerPage).ceil();
    if (totalPages == 0) totalPages = 1;
    if (_currentPage > totalPages) _currentPage = totalPages;

    final paginatedList = _drillDownTransactions.skip((_currentPage - 1) * _itemsPerPage).take(_itemsPerPage).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Monthly Drill-Down', 
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
        const SizedBox(height: 16),
        _buildMonthSelector(),
        const SizedBox(height: 16),
        if (paginatedList.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.calendar_today_outlined, color: AppColors.textSecondary.withOpacity(0.4), size: 40),
                  const SizedBox(height: 12),
                  Text(
                    'No transactions in ${_selectedMonthYear ?? 'this month'}',
                    style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Select a different month above',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
          )
        else ...[
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: paginatedList.length,
            itemBuilder: (context, index) {
              return _buildTransactionTile(paginatedList[index]);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24.0),
            child: Column(
              children: [
                // Row 1: Items per page dropdown
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Transactions per page: ', 
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: [10, 25, 50, 75, 100].contains(_itemsPerPage) ? _itemsPerPage : 50,
                          dropdownColor: AppColors.surface,
                          icon: const Icon(Icons.arrow_drop_down, color: AppColors.accent),
                          style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
                          items: [10, 25, 50, 75, 100].map((int value) {
                            return DropdownMenuItem<int>(
                              value: value,
                              child: Text(value.toString()),
                            );
                          }).toList(),
                          onChanged: (newValue) {
                            if (newValue != null) {
                              setState(() {
                                _itemsPerPage = newValue;
                                _currentPage = 1;
                              });
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Row 2: Page Navigation
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left, color: AppColors.accent),
                      onPressed: _currentPage == 1 ? null : () => setState(() => _currentPage--),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () => _showJumpToPageDialog(context, totalPages),
                      icon: const Icon(Icons.edit, size: 16, color: AppColors.accent),
                      label: Text('Page $_currentPage of $totalPages', 
                        style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.chevron_right, color: AppColors.accent),
                      onPressed: _currentPage >= totalPages ? null : () => setState(() => _currentPage++),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  void _showJumpToPageDialog(BuildContext context, int totalPages) {
    final TextEditingController controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Jump to Page', style: TextStyle(color: AppColors.textPrimary)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Enter page number',
            hintStyle: TextStyle(color: AppColors.textSecondary),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent, width: 2)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              final int? page = int.tryParse(controller.text);
              if (page != null) {
                setState(() {
                  _currentPage = page.clamp(1, totalPages);
                });
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text('Go', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _availableMonthYears.contains(_selectedMonthYear) ? _selectedMonthYear : null,
          dropdownColor: AppColors.surface,
          isExpanded: true,
          hint: const Text('Select Month', style: TextStyle(color: AppColors.textSecondary)),
          icon: const Icon(Icons.calendar_month, color: AppColors.accent, size: 20),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
          items: _availableMonthYears.map((my) {
            return DropdownMenuItem(
              value: my,
              child: Text(my),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) _updateDrillDown(val);
          },
        ),
      ),
    );
  }

  Widget _buildTransactionTile(TransactionModel txn) {
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 0);
    final dateFormat = DateFormat('dd MMM');
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.04)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.debit.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.arrow_upward_rounded, color: AppColors.debit, size: 20),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                txn.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ],
        ),
        subtitle: Text(
          '${dateFormat.format(txn.date)} • ${txn.assignedTo}', 
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
          overflow: TextOverflow.ellipsis,
          maxLines: 1),
        trailing: Text(
          '- ${currencyFormat.format(txn.amount)}',
          style: const TextStyle(color: AppColors.debit, fontWeight: FontWeight.bold, fontSize: 15),
        ),
      ),
    );
  }
}

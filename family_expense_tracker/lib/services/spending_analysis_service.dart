import '../models/transaction_model.dart';
import 'package:intl/intl.dart';

class CategoryStats {
  final String category;
  final double averageMonthlySpend;
  final double highestMonthAmount;
  final String highestMonthName;
  final double lowestMonthAmount;
  final String lowestMonthName;
  final double currentMonthSpend;
  final double lifetimeSpend;
  final double suggestedBudget;

  CategoryStats({
    required this.category,
    required this.averageMonthlySpend,
    required this.highestMonthAmount,
    required this.highestMonthName,
    required this.lowestMonthAmount,
    required this.lowestMonthName,
    required this.currentMonthSpend,
    required this.lifetimeSpend,
    required this.suggestedBudget,
  });
}

class MonthlyTrend {
  final String month;
  final double amount;
  final bool isCurrentMonth;

  MonthlyTrend({required this.month, required this.amount, this.isCurrentMonth = false});
}

class MemberShare {
  final String name;
  final double amount;
  final double percentage;

  MemberShare({required this.name, required this.amount, required this.percentage});
}

class SpendingAnalysisService {
  /// Aggregates all spending data for a specific category.
  static CategoryStats calculateCategoryStats(List<TransactionModel> transactions, String category) {
    // Filter by Category and type=debit
    final catTxns = transactions.where((t) => t.category == category && t.type == 'debit').toList();
    
    if (catTxns.isEmpty) {
      return CategoryStats(
        category: category,
        averageMonthlySpend: 0,
        highestMonthAmount: 0,
        highestMonthName: 'N/A',
        lowestMonthAmount: 0,
        lowestMonthName: 'N/A',
        currentMonthSpend: 0,
        lifetimeSpend: 0,
        suggestedBudget: 0,
      );
    }

    // Group by Month (Year-Month key)
    final Map<String, double> monthlyMap = {};
    double lifetime = 0;
    final now = DateTime.now();
    final currentMonthKey = DateFormat('yyyy-MM').format(now);

    for (var txn in catTxns) {
      final key = DateFormat('yyyy-MM').format(txn.date);
      monthlyMap[key] = (monthlyMap[key] ?? 0) + txn.amount;
      lifetime += txn.amount;
    }

    final double currentMonthAmount = monthlyMap[currentMonthKey] ?? 0;
    
    // Sort months to find min/max
    final sortedMonths = monthlyMap.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    final highest = sortedMonths.last;
    final lowest = sortedMonths.first;
    
    final double avg = lifetime / monthlyMap.length;

    return CategoryStats(
      category: category,
      averageMonthlySpend: avg,
      highestMonthAmount: highest.value,
      highestMonthName: _getMonthNameFromKey(highest.key),
      lowestMonthAmount: lowest.value,
      lowestMonthName: _getMonthNameFromKey(lowest.key),
      currentMonthSpend: currentMonthAmount,
      lifetimeSpend: lifetime,
      suggestedBudget: avg * 1.10, // 10% buffer
    );
  }

  /// Returns trend data for the last 12 months for the bar chart.
  static List<MonthlyTrend> getMonthlyTrendData(List<TransactionModel> transactions, String category) {
    final now = DateTime.now();
    final List<MonthlyTrend> trend = [];
    
    final catTxns = transactions.where((t) => t.category == category && t.type == 'debit').toList();

    for (int i =  cycle(11); i >= 0; i--) {
      final date = DateTime(now.year, now.month - i, 1);
      final key = DateFormat('yyyy-MM').format(date);
      final monthName = DateFormat('MMM').format(date);
      
      final double total = catTxns
          .where((t) => DateFormat('yyyy-MM').format(t.date) == key)
          .fold(0, (sum, t) => sum + t.amount);

      trend.add(MonthlyTrend(
        month: monthName,
        amount: total,
        isCurrentMonth: i == 0,
      ));
    }
    return trend;
  }
  
  // Helper for cycle-like iteration (not a native dart function, just logic here)
  static int cycle(int val) => val; 

  /// Calculates family member distribution for the category.
  static List<MemberShare> getFamilyDistribution(List<TransactionModel> transactions, String category) {
    final catTxns = transactions.where((t) => t.category == category && t.type == 'debit').toList();
    final Map<String, double> shares = {'Me': 0, 'Mom': 0, 'Dad': 0};
    double total = 0;

    for (var txn in catTxns) {
      if (shares.containsKey(txn.assignedTo)) {
        shares[txn.assignedTo] = shares[txn.assignedTo]! + txn.amount;
        total += txn.amount;
      }
    }

    if (total == 0) return [];

    return shares.entries.map((e) => MemberShare(
      name: e.key,
      amount: e.value,
      percentage: (e.value / total) * 100,
    )).toList()..sort((a, b) => b.amount.compareTo(a.amount));
  }

  static String _getMonthNameFromKey(String key) {
    try {
      final date = DateFormat('yyyy-MM').parse(key);
      return DateFormat('MMMM yyyy').format(date);
    } catch (e) {
      return key;
    }
  }
}

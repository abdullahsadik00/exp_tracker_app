import 'package:flutter/material.dart';
import '../services/sms_service.dart';
import '../services/local_db_service.dart';
import '../models/transaction_model.dart';
import 'add_transaction_screen.dart';
import 'pdf_statement_screen.dart';
import 'transactions_screen.dart';

import '../theme/app_colors.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final SmsService _smsService = SmsService();
  final LocalDbService _localDbService = LocalDbService();
  final PageController _pageController = PageController(viewportFraction: 0.9);
  bool _isFetching = false;

  Future<void> _fetchAndSaveSms() async {
    setState(() => _isFetching = true);
    try {
      await _smsService.requestSmsPermission();
      final transactions = await _smsService.fetchBankMessages();
      
      int newCount = transactions.length;
      await _localDbService.insertTransactionsBatch(transactions);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fetched $newCount transactions from SMS')),
        );
        setState(() {}); // Refresh UI
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isFetching = false);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Family Tracker', 
          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: () => _showClearDataDialog(context),
            icon: const Icon(Icons.delete_forever, color: Colors.redAccent)
          ),
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const PdfStatementScreen()),
              );
            }, 
            icon: const Icon(Icons.table_view, color: AppColors.textPrimary)
          ),
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AddTransactionScreen()),
              );
            }, 
            icon: const Icon(Icons.add_circle_outline, color: AppColors.textPrimary)
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'backup') {
                await _localDbService.backupDatabase();
              } else if (value == 'restore') {
                FilePickerResult? result = await FilePicker.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['json'],
                );
                if (result != null && result.files.single.path != null) {
                  final file = File(result.files.single.path!);
                  final content = await file.readAsString();
                  await _localDbService.restoreDatabase(content);
                  if (mounted) {
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Data restored successfully!'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                }
              }
            },
            icon: const Icon(Icons.more_vert, color: AppColors.textPrimary),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'backup', child: Text('Backup Data', style: TextStyle(color: AppColors.textPrimary))),
              const PopupMenuItem(value: 'restore', child: Text('Restore Data', style: TextStyle(color: AppColors.textPrimary))),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStatsCarousel(),
              const SizedBox(height: 32),
              _buildSectionHeader('Needs Tagging (Inbox)', onViewAll: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const TransactionsScreen(initialFilter: 'Unassigned')),
                ).then((_) => setState(() {}));
              }),
              const SizedBox(height: 16),
              _buildInboxSection(),
              const SizedBox(height: 32),
              _buildSectionHeader('Monthly Budgets'),
              const SizedBox(height: 16),
              _buildBudgetSection(),
              const SizedBox(height: 32),
              _buildSectionHeader('Recent Insights', onViewAll: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const TransactionsScreen(initialFilter: 'All')),
                ).then((_) => setState(() {}));
              }),
              const SizedBox(height: 16),
              _buildPlaceholderInsight(),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isFetching ? null : _fetchAndSaveSms,
        backgroundColor: AppColors.accent,
        child: _isFetching 
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
          : const Icon(Icons.refresh, color: Colors.white),
      ),
    );
  }

  Widget _buildStatsCarousel() {
    return FutureBuilder<Map<String, double>>(
      future: _localDbService.getDashboardStatsOptimized(),
      builder: (context, snapshot) {
        final stats = snapshot.data ?? {};
        
        return SizedBox(
          height: 150,
          child: PageView(
            controller: _pageController,
            physics: const BouncingScrollPhysics(),
            children: [
              _buildOverviewCard(stats),
              _buildAccountCard('Me (SBI)', stats['me_sbi_income'] ?? 0, stats['me_sbi_expense'] ?? 0, [const Color(0xFF1E40AF), const Color(0xFF3B82F6)]),
              _buildAccountCard('Me (BoB)', stats['me_bob_income'] ?? 0, stats['me_bob_expense'] ?? 0, [const Color(0xFFEA580C), const Color(0xFFF97316)]),
              _buildPersonCard("Mom's Balance", stats['mom_flow'] ?? 0, [const Color(0xFF701A75), const Color(0xFFD946EF)]),
              _buildPersonCard("Dad's Balance", stats['dad_flow'] ?? 0, [const Color(0xFF134E4A), const Color(0xFF2DD4BF)]),
            ],
          ),
        );
      }
    );
  }

  Widget _buildOverviewCard(Map<String, double> stats) {
    final income = stats['total_income'] ?? 0.0;
    final expense = stats['total_expense'] ?? 0.0;
    final balance = stats['balance'] ?? 0.0;
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 2);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E293B), Color(0xFF334155)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Total Balance (All-Time)', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(currencyFormat.format(balance),
            style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
          const Spacer(),
          const Text("This Month's Flow", style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMiniStat('Income', currencyFormat.format(income), Icons.arrow_upward),
              _buildMiniStat('Expenses', currencyFormat.format(expense), Icons.arrow_downward),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildAccountCard(String title, double income, double expense, List<Color> colors) {
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 2);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: colors[0].withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('Net: ${currencyFormat.format(income - expense)}',
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildMiniStat('In', currencyFormat.format(income), Icons.add),
              _buildMiniStat('Out', currencyFormat.format(expense), Icons.remove),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildPersonCard(String title, double balance, List<Color> colors) {
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 2);
    final isNegative = balance < 0;
    final displayBalance = balance.abs();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: colors[0].withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 5))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(
            '${isNegative ? '-' : ''}${currencyFormat.format(displayBalance)}',
            style: TextStyle(
              color: isNegative ? Colors.redAccent.shade100 : Colors.greenAccent.shade100, 
              fontSize: 32, 
              fontWeight: FontWeight.bold
            )
          ),
          const SizedBox(height: 8),
          const Text('Net Monthly Flow', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildMiniStat(String label, String value, IconData icon) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 14, color: Colors.white),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        )
      ],
    );
  }

  Widget _buildSectionHeader(String title, {VoidCallback? onViewAll}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, 
          style: const TextStyle(
            color: AppColors.textPrimary, 
            fontSize: 18, 
            fontWeight: FontWeight.bold
          )),
        if (onViewAll != null)
          TextButton(
            onPressed: onViewAll, 
            child: const Text('View All', style: TextStyle(color: AppColors.accent))
          ),
      ],
    );
  }

  Widget _buildInboxSection() {
    return FutureBuilder<List<TransactionModel>>(
      future: _localDbService.getUnassignedTransactions(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: AppColors.accent));
        }
        final transactions = snapshot.data ?? [];

        if (transactions.isEmpty) {
          return Container(
            height: 180,
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.done_all, color: Colors.green, size: 40),
                SizedBox(height: 12),
                Text('All caught up!', style: TextStyle(color: AppColors.textSecondary)),
              ],
            ),
          );
        }

        return SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: transactions.length,
            itemBuilder: (context, index) {
              final txn = transactions[index];
              return _buildTransactionCard(txn);
            },
          ),
        );
      }
    );
  }

  Widget _buildTransactionCard(TransactionModel txn) {
  final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 2);

  return Container(
    width: 280,
    margin: const EdgeInsets.only(right: 16),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: Colors.white.withOpacity(0.05)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.2),
          blurRadius: 15,
          offset: const Offset(0, 8),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  txn.bankName,
                  style: const TextStyle(
                      color: AppColors.accent,
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              DateFormat('dd MMM').format(txn.date),
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                txn.description,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 8),
            _buildCategoryBadge(txn.category),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          currencyFormat.format(txn.amount),
          style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        Row(
          children: [
            Expanded(
                child: _buildAssignButton(
                    'Me', () async {
                      await _localDbService.updateTransaction(txn.copyWith(assignedTo: 'Me'));
                      setState(() {});
                    })),
            const SizedBox(width: 8),
            Expanded(
                child: _buildAssignButton('Mom',
                    () async {
                      await _localDbService.updateTransaction(txn.copyWith(assignedTo: 'Mom'));
                      setState(() {});
                    })),
            const SizedBox(width: 8),
            Expanded(
                child: _buildAssignButton('Dad',
                    () async {
                      await _localDbService.updateTransaction(txn.copyWith(assignedTo: 'Dad'));
                      setState(() {});
                    })),
          ],
        )
      ],
    ),
  );
}

  Widget _buildAssignButton(String label, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white.withOpacity(0.05),
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: Size.zero, // Important for narrow buttons
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
      ),
      child: Text(label),
    );
  }

  Widget _buildPlaceholderInsight() {
    return FutureBuilder<List<TransactionModel>>(
      future: _localDbService.getRecentTransactions(limit: 3),
      builder: (context, snapshot) {
        if (!snapshot.hasData || (snapshot.data?.isEmpty ?? true)) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text('No recent activities to show.', 
              style: TextStyle(color: AppColors.textSecondary)),
          );
        }

        final txns = snapshot.data!;
        return Column(
          children: txns.map((txn) {
            final isCredit = txn.type == 'credit';
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: isCredit ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                    radius: 20,
                    child: Icon(
                      isCredit ? Icons.arrow_downward : Icons.arrow_upward, 
                      color: isCredit ? Colors.green : Colors.red,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(txn.description, 
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text(DateFormat('dd MMM hh:mm a').format(txn.date), 
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      ],
                    ),
                  ),
                  Text(
                    '${isCredit ? '+' : '-'}₹${txn.amount.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: isCredit ? Colors.green : Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        );
      }
    );
  }

  void _showClearDataDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Clear All Data?', style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('This will delete all transactions permanently. Are you sure?', style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              await _localDbService.clearAllTransactions();
              if (mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('All data cleared!')));
                setState(() {});
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryBadge(String category) {
    Color badgeColor;
    switch (category) {
      case 'Groceries': badgeColor = Colors.green; break;
      case 'Dining': badgeColor = Colors.orange; break;
      case 'Shopping': badgeColor = Colors.pink; break;
      case 'Utilities': badgeColor = Colors.blue; break;
      case 'Salary': badgeColor = Colors.purple; break;
      case 'Healthcare': badgeColor = Colors.red; break;
      case 'Transportation': badgeColor = Colors.teal; break;
      case 'Education': badgeColor = Colors.indigo; break;
      case 'Gifts': badgeColor = Colors.amber; break;
      default: badgeColor = AppColors.textSecondary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: badgeColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        category,
        style: TextStyle(
            color: badgeColor, fontSize: 9, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildBudgetSection() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _localDbService.getBudgetProgress(),
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
    final amountController = TextEditingController(text: currentAmount?.toString() ?? '');
    String selectedCategory = category ?? TransactionModel.availableCategories.first;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
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
                decoration: const InputDecoration(labelText: 'Category', labelStyle: TextStyle(color: AppColors.textSecondary)),
                items: TransactionModel.availableCategories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (val) => selectedCategory = val!,
              ),
            const SizedBox(height: 16),
            TextField(
              controller: amountController,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Monthly Limit (₹)',
                labelStyle: TextStyle(color: AppColors.textSecondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent, width: 2)),
              ),
            ),
          ],
        ),
        actions: [
          if (category != null)
            TextButton(
              onPressed: () async {
                await _localDbService.deleteBudget(category);
                if (mounted) {
                  setState(() {});
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final amount = double.tryParse(amountController.text);
              if (amount != null && amount > 0) {
                await _localDbService.saveBudget(selectedCategory, amount);
                if (mounted) {
                  setState(() {});
                  Navigator.pop(ctx);
                }
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

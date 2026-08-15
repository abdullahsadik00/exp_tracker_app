import 'package:flutter/material.dart';
import '../services/local_db_service.dart';
import '../services/transaction_import_service.dart';
import '../models/transaction_model.dart';
import 'add_transaction_screen.dart';
import 'categorization_rules_screen.dart';
import 'transfer_review_screen.dart';
import 'pdf_statement_screen.dart';
import 'sms_sync_screen.dart';
import 'transactions_screen.dart';

import '../theme/app_colors.dart';
import '../utils/amount_display.dart';
import '../widgets/balance_card.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.amountsHidden});

  /// Owned by `MainScreen`, so the reveal survives a tab switch but not a
  /// relaunch.
  final ValueNotifier<bool> amountsHidden;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final TransactionImportService _importer = TransactionImportService();
  final LocalDbService _localDbService = LocalDbService();
  bool _isFetching = false;

  // Read once, not on every build. Rebuilding a StreamBuilder with a freshly
  // minted stream made every setState — the fetch spinner below, for one —
  // tear down its subscription and re-run the query behind it.
  late final Stream<Map<String, double>> _statsStream =
      _localDbService.dashboardStatsStream;
  late final Stream<List<ReconciliationResult>> _reconciliationStream =
      _localDbService.reconciliationStream;
  late final Stream<List<TransactionModel>> _unassignedStream =
      _localDbService.unassignedTransactionsStream;
  late final Stream<List<Map<String, dynamic>>> _transferPairsStream =
      _localDbService.potentialTransferPairsStream;

  Future<void> _fetchAndSaveSms() async {
    setState(() => _isFetching = true);
    try {
      final report = await _importer.sync();

      if (!mounted) return;

      // Report what actually happened. The old message printed the number of
      // messages parsed, which was the same every time and told the user
      // nothing about whether anything was added.
      final String message;
      if (report.permissionDenied) {
        message = 'SMS permission is required to import transactions.';
      } else if (report.error != null) {
        message = 'Sync failed: ${report.error}';
      } else {
        final parts = <String>['${report.imported} imported'];
        if (report.duplicates > 0) parts.add('${report.duplicates} already present');
        if (report.unparsed > 0) parts.add('${report.unparsed} unreadable');
        if (report.flaggedForReview > 0) {
          parts.add('${report.flaggedForReview} to review');
        }
        message = parts.join(' · ');
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          action: SnackBarAction(
            label: 'Details',
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SmsSyncScreen())),
          ),
        ),
      );
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Family Tracker',
          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: widget.amountsHidden,
            builder: (context, hidden, _) => IconButton(
              tooltip: hidden ? 'Show amounts' : 'Hide amounts',
              onPressed: () => widget.amountsHidden.value = !hidden,
              icon: Icon(
                hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                color: AppColors.textPrimary,
              ),
            ),
          ),
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
              if (value == 'sync') {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SmsSyncScreen()));
              } else if (value == 'rules') {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const CategorizationRulesScreen()));
              } else if (value == 'backup') {
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
              const PopupMenuItem(value: 'sync',    child: Text('SMS Sync & Reconciliation', style: TextStyle(color: AppColors.textPrimary))),
              const PopupMenuItem(value: 'rules',   child: Text('Auto-Categorization Rules', style: TextStyle(color: AppColors.textPrimary))),
              const PopupMenuItem(value: 'backup',  child: Text('Backup Data',  style: TextStyle(color: AppColors.textPrimary))),
              const PopupMenuItem(value: 'restore', child: Text('Restore Data', style: TextStyle(color: AppColors.textPrimary))),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildBalanceSection(),
              const SizedBox(height: 24),
              _buildNeedsTaggingRow(),
              _buildTransferReviewCard(),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: _isFetching ? 'Fetching SMS...' : 'Fetch bank SMS',
        onPressed: _isFetching ? null : _fetchAndSaveSms,
        backgroundColor: AppColors.accent,
        child: _isFetching
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
          : const Icon(Icons.refresh, color: Colors.white),
      ),
    );
  }

  // ── Balances ────────────────────────────────────────────────────────────────

  /// The whole money area, under one visibility listener so every figure on the
  /// screen hides and reveals together.
  Widget _buildBalanceSection() {
    return StreamBuilder<Map<String, double>>(
      stream: _statsStream,
      builder: (context, snapshot) {
        final stats = snapshot.data ?? const <String, double>{};

        return ValueListenableBuilder<bool>(
          valueListenable: widget.amountsHidden,
          builder: (context, hidden, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BalanceCard(
                title: 'Total Balance (All Time)',
                amount: stats['balance'] ?? 0,
                hidden: hidden,
                accent: AppColors.accent,
                emphasis: BalanceCardEmphasis.primary,
                trailing: _buildReconciliationChip(),
                footer: _buildMonthFlowFooter(stats, hidden),
              ),
              const SizedBox(height: 12),
              _cardRow([
                BalanceCard(
                  title: 'Me (SBI)',
                  amount: stats['sbi_balance'] ?? 0,
                  hidden: hidden,
                  caption: 'account balance',
                ),
                BalanceCard(
                  title: 'Me (BoB)',
                  amount: stats['bob_balance'] ?? 0,
                  hidden: hidden,
                  caption: 'account balance',
                ),
              ]),
              const SizedBox(height: 20),
              // Mom and Dad spend out of the two accounts above, so what they
              // have is a flow, not a balance of their own. Saying so here is
              // what stops the four cards reading as four pots of money.
              const Text(
                'Spent from these accounts',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              _cardRow([
                BalanceCard(
                  title: 'Mom',
                  amount: stats['mom_flow'] ?? 0,
                  hidden: hidden,
                  caption: 'this month',
                  signed: true,
                ),
                BalanceCard(
                  title: 'Dad',
                  amount: stats['dad_flow'] ?? 0,
                  hidden: hidden,
                  caption: 'this month',
                  signed: true,
                ),
              ]),
            ],
          ),
        );
      },
    );
  }

  /// Two cards side by side, matched in height whatever their content.
  Widget _cardRow(List<Widget> cards) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: cards[0]),
          const SizedBox(width: 12),
          Expanded(child: cards[1]),
        ],
      ),
    );
  }

  Widget _buildMonthFlowFooter(Map<String, double> stats, bool hidden) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildFlowStat('In this month', stats['total_income'] ?? 0,
            Icons.arrow_downward, AppColors.credit, hidden),
        _buildFlowStat('Out this month', stats['total_expense'] ?? 0,
            Icons.arrow_upward, AppColors.debit, hidden),
      ],
    );
  }

  Widget _buildFlowStat(
      String label, double value, IconData icon, Color color, bool hidden) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 10)),
            Text(
              displayAmount(value, hidden: hidden, decimals: 0),
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ],
    );
  }

  /// Small badge telling the user whether the derived balance currently agrees
  /// with the last balance the bank reported by SMS. Tapping it opens the
  /// reconciliation view — the number itself is never adjusted to match.
  Widget _buildReconciliationChip() {
    return StreamBuilder<List<ReconciliationResult>>(
      stream: _reconciliationStream,
      builder: (context, snapshot) {
        final results = snapshot.data;
        if (results == null || results.isEmpty) return const SizedBox.shrink();

        final comparable = results.where((r) => r.canCompare).toList();
        if (comparable.isEmpty) return const SizedBox.shrink();

        final mismatched = comparable.where((r) => !r.isReconciled).toList();
        final ok = mismatched.isEmpty;

        return GestureDetector(
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SmsSyncScreen())),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: (ok ? AppColors.credit : Colors.orangeAccent)
                  .withOpacity(0.25),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(ok ? Icons.check_circle : Icons.error_outline,
                    size: 11,
                    color: ok ? AppColors.credit : Colors.orangeAccent),
                const SizedBox(width: 4),
                Text(
                  ok ? 'Reconciled' : '${mismatched.length} mismatch',
                  style: TextStyle(
                    color: ok ? AppColors.credit : Colors.orangeAccent,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Actionable rows ─────────────────────────────────────────────────────────

  /// The tagging inbox itself lives on the Transactions tab, behind its
  /// existing 'Unassigned' filter. Home only says how much is waiting.
  Widget _buildNeedsTaggingRow() {
    return StreamBuilder<List<TransactionModel>>(
      stream: _unassignedStream,
      builder: (context, snapshot) {
        final count = snapshot.data?.length ?? 0;
        if (count == 0) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _buildActionRow(
            icon: Icons.label_outline,
            color: AppColors.accent,
            title: '$count transaction${count == 1 ? '' : 's'} need tagging',
            subtitle: 'Assign them to Me, Mom or Dad',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    const TransactionsScreen(initialFilter: 'Unassigned'),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTransferReviewCard() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _transferPairsStream,
      builder: (context, snapshot) {
        final count = snapshot.data?.length ?? 0;
        if (count == 0) return const SizedBox.shrink();

        return _buildActionRow(
          icon: Icons.swap_horiz_rounded,
          color: Colors.teal,
          title: '$count possible transfer${count == 1 ? '' : 's'} detected',
          subtitle: 'Review to keep spending totals accurate',
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const TransferReviewScreen())),
        );
      },
    );
  }

  Widget _buildActionRow({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textSecondary),
          ],
        ),
      ),
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
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

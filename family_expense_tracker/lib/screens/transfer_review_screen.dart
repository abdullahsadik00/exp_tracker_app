import 'package:flutter/material.dart';
import '../services/local_db_service.dart';
import '../theme/app_colors.dart';
import 'package:intl/intl.dart';

class TransferReviewScreen extends StatelessWidget {
  const TransferReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final db = LocalDbService.instance;
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 0);
    final dateFormat = DateFormat('dd MMM, hh:mm a');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Possible Transfers',
            style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: db.potentialTransferPairsStream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: AppColors.accent));
          }

          final pairs = snapshot.data ?? [];

          if (pairs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline_rounded,
                      color: AppColors.credit.withOpacity(0.6), size: 64),
                  const SizedBox(height: 16),
                  const Text('No unreviewed transfers',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 18)),
                  const SizedBox(height: 8),
                  const Text('All transactions are accounted for.',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                ],
              ),
            );
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: AppColors.textSecondary, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'These look like transfers between your accounts. Confirming them removes them from spending totals.',
                        style: TextStyle(
                            color: AppColors.textSecondary.withOpacity(0.8), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  physics: const BouncingScrollPhysics(),
                  itemCount: pairs.length,
                  itemBuilder: (context, index) {
                    final pair = pairs[index];
                    final amount = (pair['amount'] as num).toDouble();
                    final debitDate = DateTime.tryParse(pair['debit_date'] as String) ?? DateTime.now();
                    final creditDate = DateTime.tryParse(pair['credit_date'] as String) ?? DateTime.now();

                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withOpacity(0.06)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Amount header
                            Row(
                              children: [
                                const Icon(Icons.swap_horiz_rounded,
                                    color: AppColors.accent, size: 20),
                                const SizedBox(width: 10),
                                Text(
                                  currencyFormat.format(amount),
                                  style: const TextStyle(
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 22,
                                      letterSpacing: -0.5),
                                ),
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: AppColors.accent.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text('Possible Transfer',
                                      style: TextStyle(
                                          color: AppColors.accent,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),

                            // Transfer flow diagram
                            Row(
                              children: [
                                Expanded(
                                  child: _buildLeg(
                                    bank: pair['from_bank'] as String,
                                    label: 'Sent from',
                                    description: pair['debit_desc'] as String,
                                    date: dateFormat.format(debitDate),
                                    isDebit: true,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Column(
                                    children: [
                                      Icon(Icons.arrow_forward_rounded,
                                          color: AppColors.accent.withOpacity(0.6), size: 22),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: _buildLeg(
                                    bank: pair['to_bank'] as String,
                                    label: 'Received at',
                                    description: pair['credit_desc'] as String,
                                    date: dateFormat.format(creditDate),
                                    isDebit: false,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),

                            // Action buttons
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => db.dismissTransferPair(
                                      pair['debit_id'] as String,
                                      pair['credit_id'] as String,
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      side: BorderSide(
                                          color: Colors.white.withOpacity(0.15)),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12)),
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                    ),
                                    child: const Text('Not a Transfer',
                                        style: TextStyle(
                                            color: AppColors.textSecondary,
                                            fontSize: 13)),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 2,
                                  child: ElevatedButton(
                                    onPressed: () => db.confirmTransferPair(
                                      pair['debit_id'] as String,
                                      pair['credit_id'] as String,
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.accent,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12)),
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                    ),
                                    child: const Text('Confirm Transfer',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13)),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLeg({
    required String bank,
    required String label,
    required String description,
    required String date,
    required bool isDebit,
  }) {
    final color = isDebit ? AppColors.debit : AppColors.credit;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: color.withOpacity(0.8), fontSize: 10, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(bank,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 15)),
          const SizedBox(height: 6),
          Text(description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11)),
          const SizedBox(height: 4),
          Text(date,
              style: TextStyle(
                  color: AppColors.textSecondary.withOpacity(0.6), fontSize: 10)),
        ],
      ),
    );
  }
}

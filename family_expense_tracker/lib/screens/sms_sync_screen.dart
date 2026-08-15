import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/transaction_model.dart';
import '../services/local_db_service.dart';
import '../services/native_sms_queue.dart';
import '../services/transaction_import_service.dart';
import '../theme/app_colors.dart';
import '../utils/money.dart';

/// SMS import and balance reconciliation.
///
/// Everything the importer decided is visible here — what it added, what it
/// skipped and why, what it could not read, and whether the resulting balance
/// agrees with what the bank last reported.
class SmsSyncScreen extends StatefulWidget {
  const SmsSyncScreen({super.key});

  @override
  State<SmsSyncScreen> createState() => _SmsSyncScreenState();
}

class _SmsSyncScreenState extends State<SmsSyncScreen> {
  final LocalDbService _db = LocalDbService.instance;
  final TransactionImportService _importer = TransactionImportService();

  final _currency = NumberFormat.currency(symbol: '₹', decimalDigits: 2);

  final NativeSmsQueue _queue = NativeSmsQueue();

  // Read once rather than in build(): this screen calls setState on every
  // import-progress tick, which would otherwise restart both queries.
  late final Stream<List<ReconciliationResult>> _reconciliationStream =
      _db.reconciliationStream;
  late final Stream<List<TransactionModel>> _needsReviewStream =
      _db.needsReviewStream;

  bool _syncing = false;
  ImportProgress? _progress;
  ImportReport? _report;
  DateTime? _lastSync;
  DateTime? _lastCapture;
  int _queued = 0;

  @override
  void initState() {
    super.initState();
    _loadLastRun();
  }

  @override
  void dispose() {
    _queue.dispose();
    super.dispose();
  }

  Future<void> _loadLastRun() async {
    final report = await _importer.lastReport();
    final last = await _db.lastSmsSyncAt();
    final capture = await _db.lastSmsCaptureAt();
    final queued = await _queue.count();
    if (!mounted) return;
    setState(() {
      _report = report;
      _lastSync = last;
      _lastCapture = capture;
      _queued = queued;
    });
  }

  Future<void> _sync() async {
    setState(() {
      _syncing = true;
      _progress = null;
    });

    // Import anything the receiver captured in the background before scanning
    // the inbox, so a message that arrived seconds ago is not reported as
    // "unreadable" merely because the scan has not reached it yet.
    await _importer.drainNativeQueue();

    final report = await _importer.sync(
      maxMessages: 5000,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );

    if (!mounted) return;
    setState(() {
      _syncing = false;
      _progress = null;
      _report = report;
      _lastSync = report.finishedAt;
    });
    await _loadLastRun();
    if (!mounted) return;

    final message = report.permissionDenied
        ? 'SMS permission is required to import transactions.'
        : report.error != null
            ? 'Sync failed: ${report.error}'
            : 'Imported ${report.imported} · '
                '${report.duplicates} already present · '
                '${report.unparsed} unreadable';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor:
            report.error != null ? AppColors.debit : AppColors.surface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('SMS Sync & Reconciliation',
            style: TextStyle(
                color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _syncCard(),
          const SizedBox(height: 24),
          _sectionTitle('Reconciliation'),
          const SizedBox(height: 12),
          _reconciliationSection(),
          const SizedBox(height: 24),
          _sectionTitle('Needs Review'),
          const SizedBox(height: 12),
          _reviewSection(),
          const SizedBox(height: 24),
          _sectionTitle('Messages that could not be read'),
          const SizedBox(height: 12),
          _unparsedSection(),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(text,
      style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.bold));

  // ── Sync ────────────────────────────────────────────────────────────────────

  Widget _syncCard() {
    final r = _report;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Import from SMS',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
              ),
              FilledButton.icon(
                onPressed: _syncing ? null : _sync,
                style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                icon: _syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.sync, size: 18),
                label: Text(_syncing ? 'Syncing…' : 'Sync now'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _lastSync == null
                ? 'Never synced'
                : 'Last synced ${DateFormat('d MMM yyyy, h:mm a').format(_lastSync!)}',
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 4),
          const Text(
            'Running this again is safe — transactions already imported are '
            'never added twice, and anything you deleted stays deleted.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
          if (_queue.isSupported) ...[
            const SizedBox(height: 12),
            _backgroundCaptureRow(),
          ],
          if (_progress != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _progress!.total == 0 ? null : _progress!.fraction,
              backgroundColor: AppColors.background,
              color: AppColors.accent,
            ),
            const SizedBox(height: 6),
            Text(
              '${_progress!.phase}'
              '${_progress!.total > 0 ? ' ${_progress!.processed}/${_progress!.total}' : ''}',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11),
            ),
          ],
          if (r != null) ...[
            const SizedBox(height: 16),
            const Divider(color: Colors.white12),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _stat('Scanned', r.scanned, AppColors.textSecondary),
                _stat('Imported', r.imported, AppColors.credit),
                _stat('Already present', r.duplicates, AppColors.textSecondary),
                _stat('Previously deleted', r.suppressedByDelete,
                    AppColors.textSecondary),
                _stat('Unreadable', r.unparsed, Colors.orangeAccent),
                _stat('Not financial', r.ignored, AppColors.textSecondary),
                _stat('Failed / declined', r.failedTransactions, AppColors.debit),
                _stat('Flagged', r.flaggedForReview, Colors.orangeAccent),
                if (r.pendingUpgraded > 0)
                  _stat('Settled', r.pendingUpgraded, AppColors.credit),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Status of the Android broadcast receiver.
  ///
  /// Worth showing because it is the difference between "the app noticed your
  /// payment straight away" and "the app will notice next time you open it" —
  /// and because a stuck queue is a visible symptom of a real problem.
  Widget _backgroundCaptureRow() {
    final active = _lastCapture != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(active ? Icons.podcasts_rounded : Icons.podcasts_outlined,
              size: 16,
              color: active ? AppColors.credit : AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Background capture',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  _lastCapture == null
                      ? 'Waiting for the first transaction SMS to arrive.'
                      : 'Last captured '
                          '${DateFormat('d MMM, h:mm a').format(_lastCapture!)}'
                          '${_queued > 0 ? ' · $_queued waiting to import' : ''}',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$value',
              style: TextStyle(
                  color: color, fontSize: 18, fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 10)),
        ],
      ),
    );
  }

  // ── Reconciliation ──────────────────────────────────────────────────────────

  Widget _reconciliationSection() {
    return StreamBuilder<List<ReconciliationResult>>(
      stream: _reconciliationStream,
      builder: (context, snapshot) {
        final results = snapshot.data;
        if (results == null) {
          return _card(child: const _Loading());
        }
        if (results.isEmpty) {
          return _card(
            child: const Text('No transactions yet.',
                style: TextStyle(color: AppColors.textSecondary)),
          );
        }
        return Column(
          children: [
            for (final r in results) ...[
              _reconciliationCard(r),
              const SizedBox(height: 12),
            ]
          ],
        );
      },
    );
  }

  Widget _reconciliationCard(ReconciliationResult r) {
    final diff = r.differencePaise;
    final reconciled = r.isReconciled;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(r.bankName,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: (reconciled ? AppColors.credit : Colors.orangeAccent)
                      .withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  !r.canCompare
                      ? 'No bank figure'
                      : reconciled
                          ? 'Reconciled'
                          : 'Mismatch',
                  style: TextStyle(
                    color: reconciled ? AppColors.credit : Colors.orangeAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _row('Opening balance', _currency.format(Money.toDouble(r.openingPaise))),
          _row('Calculated balance',
              _currency.format(Money.toDouble(r.calculatedPaise))),
          if (r.bankReportedPaise != null)
            _row('Bank-reported balance',
                _currency.format(Money.toDouble(r.bankReportedPaise!))),
          if (r.asOf != null)
            _row('As of', DateFormat('d MMM yyyy, h:mm a').format(r.asOf!)),
          if (r.canCompare && !reconciled)
            _row(
              'Difference',
              '${diff > 0 ? '+' : ''}${_currency.format(Money.toDouble(diff))}',
              valueColor: diff > 0 ? AppColors.credit : AppColors.debit,
              bold: true,
            ),
          if (r.possibleReasons.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Possible reasons',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            for (final reason in r.possibleReasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $reason',
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        height: 1.4)),
              ),
          ],
          if (r.canCompare && !reconciled) ...[
            const SizedBox(height: 12),
            // The offer is to record a missing *opening balance* — real data
            // the app never had. It never edits transactions to force a match.
            OutlinedButton.icon(
              onPressed: () => _confirmOpeningBalance(r),
              icon: const Icon(Icons.flag_outlined, size: 16),
              label: Text(
                  'Set opening balance to ${_currency.format(Money.toDouble(r.suggestedOpeningPaise))}'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.accent),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Only do this if the gap is money that existed before your '
              'first recorded transaction. If a transaction is missing or '
              'duplicated, fix that instead — the balance will follow.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmOpeningBalance(ReconciliationResult r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Set opening balance?',
            style: TextStyle(color: AppColors.textPrimary)),
        content: Text(
          '${r.bankName}\'s opening balance will be set to '
          '${_currency.format(Money.toDouble(r.suggestedOpeningPaise))}.\n\n'
          'No transactions will be changed. If the difference is actually a '
          'missing or duplicated transaction, cancel and fix that instead.',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Set')),
        ],
      ),
    );

    if (ok != true) return;
    await _db.setOpeningBalance(r.bankName, r.suggestedOpeningPaise);
  }

  // ── Review queue ────────────────────────────────────────────────────────────

  Widget _reviewSection() {
    return StreamBuilder<List<TransactionModel>>(
      stream: _needsReviewStream,
      builder: (context, snapshot) {
        final items = snapshot.data;
        if (items == null) return _card(child: const _Loading());
        if (items.isEmpty) {
          return _card(
            child: const Text(
                'Nothing needs review. Every imported transaction was read '
                'confidently.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          );
        }
        return Column(
          children: [
            for (final tx in items) ...[
              _reviewTile(tx),
              const SizedBox(height: 8),
            ]
          ],
        );
      },
    );
  }

  Widget _reviewTile(TransactionModel tx) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(tx.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.bold)),
              ),
              Text(
                '${tx.type == 'credit' ? '+' : '-'}${_currency.format(tx.amount)}',
                style: TextStyle(
                    color: tx.type == 'credit'
                        ? AppColors.credit
                        : AppColors.debit,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${tx.bankName} · ${DateFormat('d MMM yyyy, h:mm a').format(tx.date)}'
            '${tx.status == TxnStatus.failed ? ' · not counted' : ''}',
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 11),
          ),
          if (tx.reviewReason != null) ...[
            const SizedBox(height: 6),
            Text(tx.reviewReason!,
                style: const TextStyle(
                    color: Colors.orangeAccent, fontSize: 11, height: 1.4)),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => _db.resolveReview(tx.id),
                child: const Text('Looks right'),
              ),
              if (tx.status == TxnStatus.failed)
                TextButton(
                  onPressed: () async {
                    await _db.setTransactionStatus(tx.id, TxnStatus.posted);
                    await _db.resolveReview(tx.id);
                  },
                  child: const Text('Count it'),
                ),
              if (tx.status != TxnStatus.failed)
                TextButton(
                  onPressed: () async {
                    await _db.setTransactionStatus(tx.id, TxnStatus.failed);
                    await _db.resolveReview(tx.id);
                  },
                  child: const Text("Don't count"),
                ),
              TextButton(
                onPressed: () => _db.deleteTransaction(tx.id),
                style: TextButton.styleFrom(foregroundColor: AppColors.debit),
                child: const Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Unparsed ────────────────────────────────────────────────────────────────

  Widget _unparsedSection() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _db.getUnparsedMessages(limit: 50),
      builder: (context, snapshot) {
        final rows = snapshot.data;
        if (rows == null) return _card(child: const _Loading());
        if (rows.isEmpty) {
          return _card(
            child: const Text(
                'Every bank-looking message was read successfully.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          );
        }
        return _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${rows.length} message(s) look financial but could not be '
                'turned into a transaction. If your balance does not '
                'reconcile, the missing amount is most likely in here.',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 12),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${row['sender'] ?? 'Unknown'} · '
                        '${_shortDate(row['received_at'] as String?)}',
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 10),
                      ),
                      Text((row['body'] as String? ?? ''),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textPrimary, fontSize: 12)),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _shortDate(String? iso) {
    final d = DateTime.tryParse(iso ?? '');
    if (d == null) return '';
    return DateFormat('d MMM yyyy').format(d);
  }

  // ── Shared chrome ───────────────────────────────────────────────────────────

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: child,
      );

  Widget _row(String label, String value,
      {Color? valueColor, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12)),
          Text(value,
              style: TextStyle(
                  color: valueColor ?? AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: bold ? FontWeight.bold : FontWeight.w500)),
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.accent),
          ),
        ),
      );
}

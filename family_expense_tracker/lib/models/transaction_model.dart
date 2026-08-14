import '../utils/money.dart';

/// Where a transaction came from. Manual entries are never overwritten by an
/// automated import, so the importer needs to be able to tell them apart.
class TxnSource {
  static const String manual = 'manual';
  static const String sms = 'sms';
  static const String pdf = 'pdf';
  static const String excel = 'excel';
  static const String restore = 'restore';
}

/// Lifecycle of the transaction as the bank reported it.
class TxnStatus {
  /// Money has moved. Counts towards the balance.
  static const String posted = 'posted';

  /// Authorised but not settled. Counts towards the balance — Indian bank
  /// debit alerts are almost always already settled — but tracked separately so
  /// a later "posted" message for the same reference updates instead of adding.
  static const String pending = 'pending';

  /// Declined / could not be processed. Kept for audit, excluded from balance.
  static const String failed = 'failed';
}

/// What kind of movement this is. All kinds affect the balance through their
/// credit/debit sign; the kind exists so refunds and reversals can be shown,
/// filtered and reconciled distinctly rather than being silently netted away.
class TxnKind {
  static const String normal = 'normal';
  static const String refund = 'refund';
  static const String reversal = 'reversal';
  static const String fee = 'fee';
  static const String atm = 'atm';
}

class TransactionModel {
  static const List<String> availableCategories = [
    'Salary', 'Business Income', 'Investment Return', 'Groceries', 'Utilities',
    'Rent', 'Transportation', 'Dining', 'Shopping', 'Entertainment', 'Healthcare',
    'Business Maintenance', 'Education', 'Personal Care', 'Gifts',
    'Transfer', 'Investment', 'Other'
  ];


  final String id;

  /// Canonical amount, in paise. Always positive; direction lives in [type].
  final int amountPaise;

  final String type; // credit/debit
  final String bankName; // SBI/BoB
  final String assignedTo; // Me/Mom/Dad/Unassigned
  final String category;
  final String description;
  final DateTime date;
  final String rawSmsText;
  final String? notes;

  /// Running ledger balance derived by [LocalDbService.syncLedgerBalances].
  /// This is computed data — never a bank-reported figure. See [smsBalancePaise].
  final double? closingBalance;

  // 0 = unreviewed, 1 = confirmed transfer, -1 = dismissed (not a transfer)
  final int isTransfer;

  // ─── Provenance & deduplication ────────────────────────────────────────────

  /// One of [TxnSource].
  final String source;

  /// Strongest available identity for this transaction. Unique across the
  /// table; this is what makes imports idempotent.
  final String? fingerprint;

  final String? merchant;
  final String? referenceId;
  final String? upiTransactionId;

  /// Last few digits of the account or card the money moved on.
  final String? accountTail;

  final String? smsSender;

  /// One of [TxnStatus].
  final String status;

  /// One of [TxnKind].
  final String txnKind;

  /// Set when the parser was not confident. Such rows are surfaced in the
  /// review queue instead of being trusted silently.
  final bool needsReview;
  final String? reviewReason;

  /// Balance the bank itself reported in the SMS ("Avl Bal Rs 12,345.67"),
  /// in paise. This is the independent anchor reconciliation compares against.
  final int? smsBalancePaise;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  TransactionModel({
    required this.id,
    double amount = 0,
    int? amountPaise,
    required this.type,
    required this.bankName,
    required this.assignedTo,
    required this.category,
    required this.description,
    required this.date,
    required this.rawSmsText,
    this.notes,
    this.closingBalance,
    this.isTransfer = 0,
    this.source = TxnSource.manual,
    this.fingerprint,
    this.merchant,
    this.referenceId,
    this.upiTransactionId,
    this.accountTail,
    this.smsSender,
    this.status = TxnStatus.posted,
    this.txnKind = TxnKind.normal,
    this.needsReview = false,
    this.reviewReason,
    this.smsBalancePaise,
    this.createdAt,
    this.updatedAt,
  }) : amountPaise = amountPaise ?? Money.fromDouble(amount);

  /// Rupee view of [amountPaise], for display and for the legacy `amount`
  /// column that the analytics queries still aggregate over.
  double get amount => Money.toDouble(amountPaise);

  /// Signed contribution to the balance, in paise. Failed transactions
  /// contribute nothing — this is the single place that rule is expressed in
  /// Dart, mirrored by `LocalDbService`'s SQL.
  int get signedPaise {
    if (status == TxnStatus.failed) return 0;
    return type == 'credit' ? amountPaise : -amountPaise;
  }

  TransactionModel copyWith({
    String? id,
    double? amount,
    int? amountPaise,
    String? type,
    String? bankName,
    String? assignedTo,
    String? category,
    String? description,
    DateTime? date,
    String? rawSmsText,
    String? notes,
    double? closingBalance,
    int? isTransfer,
    String? source,
    String? fingerprint,
    String? merchant,
    String? referenceId,
    String? upiTransactionId,
    String? accountTail,
    String? smsSender,
    String? status,
    String? txnKind,
    bool? needsReview,
    String? reviewReason,
    int? smsBalancePaise,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TransactionModel(
      id: id ?? this.id,
      amountPaise: amountPaise ??
          (amount != null ? Money.fromDouble(amount) : this.amountPaise),
      type: type ?? this.type,
      bankName: bankName ?? this.bankName,
      assignedTo: assignedTo ?? this.assignedTo,
      category: category ?? this.category,
      description: description ?? this.description,
      date: date ?? this.date,
      rawSmsText: rawSmsText ?? this.rawSmsText,
      notes: notes ?? this.notes,
      closingBalance: closingBalance ?? this.closingBalance,
      isTransfer: isTransfer ?? this.isTransfer,
      source: source ?? this.source,
      fingerprint: fingerprint ?? this.fingerprint,
      merchant: merchant ?? this.merchant,
      referenceId: referenceId ?? this.referenceId,
      upiTransactionId: upiTransactionId ?? this.upiTransactionId,
      accountTail: accountTail ?? this.accountTail,
      smsSender: smsSender ?? this.smsSender,
      status: status ?? this.status,
      txnKind: txnKind ?? this.txnKind,
      needsReview: needsReview ?? this.needsReview,
      reviewReason: reviewReason ?? this.reviewReason,
      smsBalancePaise: smsBalancePaise ?? this.smsBalancePaise,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      // `amount` stays the rupee REAL column so the existing analytics SQL
      // keeps working; `amount_paise` is the authoritative value.
      'amount': amount,
      'amount_paise': amountPaise,
      'type': type,
      'bankName': bankName,
      'assignedTo': assignedTo,
      'category': category,
      'description': description,
      'date': date.toIso8601String(),
      'rawSmsText': rawSmsText,
      'notes': notes ?? '',
      'closingBalance': closingBalance,
      'is_transfer': isTransfer,
      'source': source,
      'fingerprint': fingerprint,
      'merchant': merchant,
      'reference_id': referenceId,
      'upi_txn_id': upiTransactionId,
      'account_tail': accountTail,
      'sms_sender': smsSender,
      'status': status,
      'txn_kind': txnKind,
      'needs_review': needsReview ? 1 : 0,
      'review_reason': reviewReason,
      'sms_balance_paise': smsBalancePaise,
      'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
      'updated_at': (updatedAt ?? DateTime.now()).toIso8601String(),
    };
  }

  factory TransactionModel.fromJson(Map<String, dynamic> json) {
    try {
      // Rows written before schema v6 (and older JSON backups) have no
      // `amount_paise`; fall back to converting the REAL rupee column.
      final rawPaise = json['amount_paise'];
      final int paise = rawPaise != null
          ? (rawPaise as num).toInt()
          : Money.fromDouble(
              double.tryParse((json['amount'] ?? '0.0').toString()) ?? 0.0);

      return TransactionModel(
        id: (json['id'] ?? '').toString(),
        amountPaise: paise,
        type: (json['type'] ?? 'debit').toString(),
        bankName: (json['bankName'] ?? 'Other').toString(),
        assignedTo: (json['assignedTo'] ?? 'Unassigned').toString(),
        category: (json['category'] ?? 'Other').toString(),
        description: (json['description'] ?? 'General Transaction').toString(),
        date: DateTime.tryParse((json['date'] ?? '').toString()) ?? DateTime.now(),
        rawSmsText: (json['rawSmsText'] ?? '').toString(),
        notes: (json['notes'] ?? '').toString(),
        closingBalance: json['closingBalance'] != null ? double.tryParse(json['closingBalance'].toString()) : null,
        isTransfer: (json['is_transfer'] as num?)?.toInt() ?? 0,
        source: (json['source'] ?? TxnSource.manual).toString(),
        fingerprint: json['fingerprint']?.toString(),
        merchant: json['merchant']?.toString(),
        referenceId: json['reference_id']?.toString(),
        upiTransactionId: json['upi_txn_id']?.toString(),
        accountTail: json['account_tail']?.toString(),
        smsSender: json['sms_sender']?.toString(),
        status: (json['status'] ?? TxnStatus.posted).toString(),
        txnKind: (json['txn_kind'] ?? TxnKind.normal).toString(),
        needsReview: ((json['needs_review'] as num?)?.toInt() ?? 0) == 1,
        reviewReason: json['review_reason']?.toString(),
        smsBalancePaise: (json['sms_balance_paise'] as num?)?.toInt(),
        createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()),
        updatedAt: DateTime.tryParse((json['updated_at'] ?? '').toString()),
      );
    } catch (e) {
      // Return a partially corrupt but safe-to-render dummy if parsing fails fundamentally
      return TransactionModel(
        id: 'error_${DateTime.now().millisecondsSinceEpoch}',
        amount: 0.0,
        type: 'debit',
        bankName: 'Error',
        assignedTo: 'Unassigned',
        category: 'Error',
        description: 'Corrupt transaction data',
        date: DateTime.now(),
        rawSmsText: 'Parsing Error: $e',
        notes: '',
        closingBalance: null,
        needsReview: true,
        reviewReason: 'Corrupt row',
      );
    }
  }
}

class TransactionModel {
  static const List<String> availableCategories = [
    'Salary', 'Business Income', 'Investment Return', 'Groceries', 'Utilities', 
    'Rent', 'Transportation', 'Dining', 'Shopping', 'Entertainment', 'Healthcare', 
    'Business Maintenance', 'Education', 'Personal Care', 'Gifts', 
    'Transfer', 'Investment', 'Other'
  ];


  final String id;
  final double amount;
  final String type; // credit/debit
  final String bankName; // SBI/BoB
  final String assignedTo; // Me/Mom/Dad/Unassigned
  final String category;
  final String description;
  final DateTime date;
  final String rawSmsText;
  final String? notes;
  final double? closingBalance;

  TransactionModel({
    required this.id,
    required this.amount,
    required this.type,
    required this.bankName,
    required this.assignedTo,
    required this.category,
    required this.description,
    required this.date,
    required this.rawSmsText,
    this.notes,
    this.closingBalance,
  });

  TransactionModel copyWith({
    String? id,
    double? amount,
    String? type,
    String? bankName,
    String? assignedTo,
    String? category,
    String? description,
    DateTime? date,
    String? rawSmsText,
    String? notes,
    double? closingBalance,
  }) {
    return TransactionModel(
      id: id ?? this.id,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      bankName: bankName ?? this.bankName,
      assignedTo: assignedTo ?? this.assignedTo,
      category: category ?? this.category,
      description: description ?? this.description,
      date: date ?? this.date,
      rawSmsText: rawSmsText ?? this.rawSmsText,
      notes: notes ?? this.notes,
      closingBalance: closingBalance ?? this.closingBalance,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'amount': amount,
      'type': type,
      'bankName': bankName,
      'assignedTo': assignedTo,
      'category': category,
      'description': description,
      'date': date.toIso8601String(),
      'rawSmsText': rawSmsText,
      'notes': notes ?? '',
      'closingBalance': closingBalance,
    };
  }

  factory TransactionModel.fromJson(Map<String, dynamic> json) {
    try {
      return TransactionModel(
        id: (json['id'] ?? '').toString(),
        amount: double.tryParse((json['amount'] ?? '0.0').toString()) ?? 0.0,
        type: (json['type'] ?? 'debit').toString(),
        bankName: (json['bankName'] ?? 'Other').toString(),
        assignedTo: (json['assignedTo'] ?? 'Unassigned').toString(),
        category: (json['category'] ?? 'Other').toString(),
        description: (json['description'] ?? 'General Transaction').toString(),
        date: DateTime.tryParse((json['date'] ?? '').toString()) ?? DateTime.now(),
        rawSmsText: (json['rawSmsText'] ?? '').toString(),
        notes: (json['notes'] ?? '').toString(),
        closingBalance: json['closingBalance'] != null ? double.tryParse(json['closingBalance'].toString()) : null,
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
      );
    }
  }
}
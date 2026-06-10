class BudgetModel {
  final String category;
  final double amount;

  BudgetModel({
    required this.category,
    required this.amount,
  });

  Map<String, dynamic> toJson() {
    return {
      'category': category,
      'amount': amount,
    };
  }

  factory BudgetModel.fromJson(Map<String, dynamic> json) {
    return BudgetModel(
      category: json['category'],
      amount: (json['amount'] as num).toDouble(),
    );
  }
}

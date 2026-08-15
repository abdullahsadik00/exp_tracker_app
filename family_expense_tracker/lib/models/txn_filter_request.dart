/// A request to open the Transactions tab already filtered.
///
/// Analytics answers "what happened and is it a problem"; Transactions answers
/// "show me the rows". This is the handoff between them, and the reason
/// Analytics no longer carries a transaction list of its own.
class TxnFilterRequest {
  const TxnFilterRequest({this.monthLabel, this.category, this.person});

  /// Display-form month, `MMM yyyy` — the form the Transactions filters use.
  final String? monthLabel;

  final String? category;

  /// One of Me / Mom / Dad / Unassigned.
  final String? person;

  @override
  bool operator ==(Object other) =>
      other is TxnFilterRequest &&
      other.monthLabel == monthLabel &&
      other.category == category &&
      other.person == person;

  @override
  int get hashCode => Object.hash(monthLabel, category, person);

  @override
  String toString() =>
      'TxnFilterRequest(month: $monthLabel, category: $category, person: $person)';
}

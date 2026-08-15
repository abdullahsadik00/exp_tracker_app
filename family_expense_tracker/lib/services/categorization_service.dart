class CategorizationRule {
  final int? id;
  final String keyword;
  final String? category;
  final String? assignedTo;
  final String? bankName;
  final int priority;

  const CategorizationRule({
    this.id,
    required this.keyword,
    this.category,
    this.assignedTo,
    this.bankName,
    this.priority = 100,
  });

  factory CategorizationRule.fromMap(Map<String, dynamic> map) {
    return CategorizationRule(
      id: map['id'] as int?,
      keyword: map['keyword'] as String,
      category: map['category'] as String?,
      assignedTo: map['assigned_to'] as String?,
      bankName: map['bank_name'] as String?,
      priority: (map['priority'] as int?) ?? 100,
    );
  }

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'keyword': keyword,
    'category': category,
    'assigned_to': assignedTo,
    'bank_name': bankName,
    'priority': priority,
  };

  CategorizationRule copyWith({
    int? id,
    String? keyword,
    String? category,
    String? assignedTo,
    String? bankName,
    int? priority,
    bool clearCategory = false,
    bool clearAssignedTo = false,
    bool clearBankName = false,
  }) {
    return CategorizationRule(
      id: id ?? this.id,
      keyword: keyword ?? this.keyword,
      category: clearCategory ? null : (category ?? this.category),
      assignedTo: clearAssignedTo ? null : (assignedTo ?? this.assignedTo),
      bankName: clearBankName ? null : (bankName ?? this.bankName),
      priority: priority ?? this.priority,
    );
  }
}

/// What the rules alone say about a transaction, before any defaults are
/// applied. Null fields mean "no rule had an opinion".
class RuleMatch {
  const RuleMatch({this.category, this.assignedTo, this.bankName});

  final String? category;
  final String? assignedTo;
  final String? bankName;

  bool get isEmpty =>
      category == null && assignedTo == null && bankName == null;
}

class CategorizationService {
  final List<CategorizationRule> _rules;

  CategorizationService(this._rules);

  /// Runs the rules and reports only what they actually matched.
  ///
  /// Kept separate from [analyzeTransaction] because that one fills in
  /// 'Unassigned'/'SBI'/'Other' for anything unmatched, which is right when
  /// creating a transaction and wrong when re-categorising one that already
  /// exists — there, a default would overwrite a real value with a placeholder.
  RuleMatch match(String rawText) {
    final text = rawText.toUpperCase();
    String? assignedTo;
    String? bankName;
    String? category;

    for (final rule in _rules) {
      // Keywords are upper-cased on save, but rules restored from an older
      // backup or seeded elsewhere may not be. Matching against a normalised
      // copy means a lower-case keyword still works instead of silently
      // never matching anything.
      if (!text.contains(rule.keyword.toUpperCase())) continue;
      assignedTo ??= rule.assignedTo;
      bankName ??= rule.bankName;
      category ??= rule.category;
      if (assignedTo != null && bankName != null && category != null) break;
    }

    return RuleMatch(
      category: category,
      assignedTo: assignedTo,
      bankName: bankName,
    );
  }

  Map<String, String> analyzeTransaction(String rawText, String type) {
    final matched = match(rawText);
    String? assignedTo = matched.assignedTo;
    String? bankName = matched.bankName;
    String? category = matched.category;

    assignedTo ??= 'Unassigned';
    bankName ??= 'SBI';
    category ??= 'Other';

    // If a category was identified but person wasn't, default to 'Me'
    if (category != 'Other' && assignedTo == 'Unassigned') {
      assignedTo = 'Me';
    }

    return {
      'assignedTo': assignedTo,
      'bankName': bankName,
      'category': category,
      'description': _cleanupDescription(rawText),
    };
  }

  static String _cleanupDescription(String rawText) {
    if (rawText.contains('INSUFFICIENT BAL')) return 'ATM DECLINE CHARGE';

    RegExp transferFromRegExp = RegExp(
        r'transfer from\s+(.*?)(?:\s+Ref No|\s*$)', caseSensitive: false);
    if (transferFromRegExp.hasMatch(rawText)) {
      return transferFromRegExp.firstMatch(rawText)!.group(1)!.trim();
    }

    final upiMatch =
        RegExp(r'UPI/(?:CR|DR|REV|RET)/\d+/([^/]+)').firstMatch(rawText);
    if (upiMatch != null) {
      return upiMatch.group(1)!.trim();
    }

    RegExp neftByRegExp = RegExp(
        r'through NEFT.*?by\s+(.*?)(?:,| INFO:|-SBI|$)', caseSensitive: false);
    if (neftByRegExp.hasMatch(rawText)) {
      return neftByRegExp.firstMatch(rawText)!.group(1)!.trim();
    }

    if (rawText.toUpperCase().contains('NEFT*')) {
      var parts = rawText.split('*');
      if (parts.length >= 4) {
        String namePart = parts[3].trim();
        List<String> nameSubParts = namePart.split(' ');
        if (nameSubParts.length >= 2) {
          return '${nameSubParts[0]} ${nameSubParts[1]}'.trim();
        }
        return namePart;
      }
    }

    String clean = rawText;
    final lowerText = rawText.toLowerCase();

    if (lowerText.contains('trf to ')) {
      final startIndex = lowerText.indexOf('trf to ') + 'trf to '.length;
      String remaining = rawText.substring(startIndex);
      if (remaining.toLowerCase().contains(' refno')) {
        final refIndex = remaining.toLowerCase().indexOf(' refno');
        clean = remaining.substring(0, refIndex).trim();
      } else {
        clean = remaining.split(' ').take(2).join(' ').trim();
      }
      return clean;
    }

    final prefixes = [
      RegExp(r'^(DEP TFR\s+|WDL TFR\s+)'),
      RegExp(r'UPI-TRANSFER-'),
      RegExp(r'UPI-'),
      RegExp(r'TRANSFER TO\s+'),
      RegExp(r'SENT TO\s+'),
      RegExp(r'RECEIVED FROM\s+'),
      RegExp(r'FROM\s+'),
      RegExp(r'TO\s+'),
    ];

    for (var p in prefixes) {
      clean = clean.replaceFirst(p, '');
    }

    if (clean.length > 40) clean = clean.substring(0, 40) + '...';

    return clean.trim();
  }
}

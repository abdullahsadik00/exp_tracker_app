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

class CategorizationService {
  final List<CategorizationRule> _rules;

  CategorizationService(this._rules);

  Map<String, String> analyzeTransaction(String rawText, String type) {
    final text = rawText.toUpperCase();
    String? assignedTo;
    String? bankName;
    String? category;

    for (final rule in _rules) {
      if (!text.contains(rule.keyword)) continue;
      assignedTo ??= rule.assignedTo;
      bankName ??= rule.bankName;
      category ??= rule.category;
      if (assignedTo != null && bankName != null && category != null) break;
    }

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

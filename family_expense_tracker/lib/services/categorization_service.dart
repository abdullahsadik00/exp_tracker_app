class CategorizationService {
  static Map<String, String> analyzeTransaction(String rawText, String type) {
    String text = rawText.toUpperCase();
    String assignedTo = 'Unassigned';
    String bankName = 'SBI';
    String category = 'Other';
    String description = '';

    // Rule Set 1: AssignedTo & Bank
    if (text.contains('ABDULLAHSA')) {
      assignedTo = 'Me';
      if (text.contains('BARB')) bankName = 'BoB';
    } else if (_containsAny(text, ['MOHD AAYAN', 'NAMDEO V', 'AQUIB AS', 'RAJAN HA', 'ABBU'])) {
      assignedTo = 'Dad';
    } else if (_containsAny(text, ['MUBEEN M', 'HEENA', 'AMREEN', 'IMRAN SH', 'ALIABBAS', 'YUNUS BA', 'FAIZA FE', 'ZAIN', 'BEE LOGICAL'])) {
      assignedTo = 'Me';
    } else if (text.contains('NILOFAR')) {
      assignedTo = 'Mom';
    }

    // Bank fallback
    if (text.contains('BARODA') || text.contains('BOB') || text.contains('BARB')) {
      bankName = 'BoB';
    }

    // Rule Set 2: Category (Override defaults)
    if (text.contains('BEE LOGICA')) {
      category = 'Salary';
    } else if (text.contains('INSUFFICIENT BAL')) {
      category = 'Other';
    } else if (_containsAny(text, ['BSNL', 'GOOGLE I', 'AMAZON', 'BAREERAH', 'WIFI', 'LIGHT', 'ELECTRICITY'])) {
      category = 'Utilities';
    } else if (_containsAny(text, ['DAWAT E', 'DAWATEISLA', 'SHADI', 'WEDDING', 'LAXMI'])) {
      category = 'Gifts';
    } else if (_containsAny(text, ['MUKESH C', 'PRAKASH', 'BLINKIT', 'JOHIRUL', 'MAHENDRA', 'MILAN SU', 'JAGDISHC', 'MAHA BAL', 'HARIOM', 'MILK', 'DAHI', 'EGG', 'GROCE', 'DMART'])) {
      category = 'Groceries';
    } else if (_containsAny(text, ['PHYSIOMA', 'WELLNESS', 'RELAXSTA', 'MANTHAN', 'DR AMIR', 'MEDICAL', 'CLINIC'])) {
      category = 'Healthcare';
    } else if (_containsAny(text, ['TAKWIM N', 'ISRAR BAIG', 'CHINNASA', 'SAMADHAN', 'CROWN BA', 'RESTAURANT', 'CAFE', 'TEA'])) {
      category = 'Dining';
    } else if (text.contains('SBIMOPS') || text.contains('ATM')) {
      category = 'Transfer';
    } else if (_containsAny(text, ['SERAJ MU', 'AVENUE S', 'SALON', 'GYM'])) {
      category = 'Personal Care';
    } else if (text.contains('ROYAL SN')) {
      category = 'Entertainment';
    } else if (text.contains('ANGEL LT')) {
      category = 'Investment';
    } else if (_containsAny(text, ['XEROX', 'BOMBAY'])) {
      category = 'Education';
    } else if (_containsAny(text, ['FLIPKART', 'MEESHO', 'SUPREME'])) {
      category = 'Shopping';
    } else if (_containsAny(text, ['CAB', 'AUTO', 'RICK'])) {
      category = 'Transportation';
    }

    // Final AssignedTo Adjustment: Default to 'Me' for recognized categories, else 'Unassigned'
    if (category != 'Other' && assignedTo == 'Unassigned') {
      assignedTo = 'Me';
    }

    // Description Cleanup
    description = _cleanupDescription(rawText);

    return {
      'assignedTo': assignedTo,
      'bankName': bankName,
      'category': category,
      'description': description,
    };
  }

  static bool _containsAny(String text, List<String> keywords) {
    for (var kw in keywords) {
      if (text.contains(kw)) return true;
    }
    return false;
  }

  static String _cleanupDescription(String rawText) {
    if (rawText.contains('INSUFFICIENT BAL')) return 'ATM DECLINE CHARGE';

    // Transfer From extraction
    RegExp transferFromRegExp = RegExp(r'transfer from\s+(.*?)(?:\s+Ref No|\s*$)', caseSensitive: false);
    if (transferFromRegExp.hasMatch(rawText)) {
      return transferFromRegExp.firstMatch(rawText)!.group(1)!.trim();
    }

    // NEFT Extraction (Standard format)
    final upiMatch = RegExp(r'UPI/(?:CR|DR|REV|RET)/\d+/([^/]+)').firstMatch(rawText);
    if (upiMatch != null) {
      return upiMatch.group(1)!.trim();
    }

    // SBI NEFT format check
    RegExp neftByRegExp = RegExp(r'through NEFT.*?by\s+(.*?)(?:,| INFO:|-SBI|$)', caseSensitive: false);
    if (neftByRegExp.hasMatch(rawText)) {
      return neftByRegExp.firstMatch(rawText)!.group(1)!.trim();
    }

    // NEFT Extraction
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

    // Special case for 'trf to' (transfer to) which usually precedes the name
    if (lowerText.contains('trf to ')) {
      final startIndex = lowerText.indexOf('trf to ') + 'trf to '.length;
      String remaining = rawText.substring(startIndex);
      
      // Look for ' Refno' boundary
      if (remaining.toLowerCase().contains(' refno')) {
        final refIndex = remaining.toLowerCase().indexOf(' refno');
        clean = remaining.substring(0, refIndex).trim();
      } else {
        // Fallback: take the next few words for name
        clean = remaining.split(' ').take(2).join(' ').trim();
      }
      return clean;
    }

    // Remove common prefixes
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

    // Basic capitalization and trim
    if (clean.length > 40) clean = clean.substring(0, 40) + '...';
    
    return clean.trim();
  }
}

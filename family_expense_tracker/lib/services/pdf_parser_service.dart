import 'package:intl/intl.dart';
import '../models/transaction_model.dart';
import '../utils/money.dart';
import 'categorization_service.dart';
import 'local_db_service.dart';

class PdfParserService {
  /// Parses a bank statement string into a list of TransactionModel objects.
  /// This logic matches the specific layouts for SBI and BoB e-statements.
  static Future<List<TransactionModel>> parseStatement(String text) async {
    final rules = await LocalDbService.instance.getCategorizationRules();
    final categorizer = CategorizationService(rules);
    List<TransactionModel> parsedTransactions = [];
    final lines = text.split('\n');
    
    // Matches format like "12 Jan 2024", "1 Jan 2024", or "01-01-2026"
    final dateRegex = RegExp(r'\d{1,2}\s+[a-zA-Z]{3}\s+\d{4}|\d{1,2}-\d{1,2}-\d{4}');
    // Regex for matching transaction amounts with or without commas
    final amountRegex = RegExp(r'\d+,\d+\.\d{2}|\d+\.\d{2}');

    for (var line in lines) {
      String trimmedLine = line.trim();
      if (trimmedLine.isEmpty) continue;

      // Skip summary lines and boilerplates to avoid "hallucinating" transactions
      final lowerLine = trimmedLine.toLowerCase();
      if (lowerLine.contains('balance as on') || 
          lowerLine.contains('statement period') ||
          lowerLine.contains('statement from') ||
          lowerLine.contains('value date') ||
          lowerLine.contains('post date') ||
          lowerLine.contains('uncleared amount')) {
        continue;
      }

      final dateMatch = dateRegex.firstMatch(trimmedLine);
      if (dateMatch != null) {
        // Extract ALL decimal numbers from the line
        final matches = amountRegex.allMatches(trimmedLine);
        
        // If matches.length >= 2, we assume the last is the Balance, 
        // and the second to last is the Transaction Amount.
        if (matches.length >= 2) {
          final amountStr = matches.elementAt(matches.length - 2).group(0)!.replaceAll(',', '');
          final parsedAmount = double.tryParse(amountStr) ?? 0.0;
          
          if (parsedAmount > 0) {
            final upperLine = trimmedLine.toUpperCase();
            // Determine type by checking for keywords (case-insensitive)
            String type = (upperLine.contains(' TO ') || 
                           upperLine.contains(' DR ') || 
                           upperLine.contains('DEBIT')) ? 'debit' : 'credit';
            
            String dateStr = dateMatch.group(0)!;
            DateTime parsedDate = _parseDate(dateStr);

            final analysis = categorizer.analyzeTransaction(trimmedLine, type);

            // id and fingerprint are assigned by LocalDbService, which knows
            // how many identical rows this batch already contains. Leaving the
            // id blank here is safe now; it previously meant every row after
            // the first collided on the primary key and was silently dropped.
            parsedTransactions.add(TransactionModel(
              id: '',
              amountPaise: Money.parsePaise(amountStr) ?? 0,
              type: type,
              bankName: analysis['bankName']!,
              assignedTo: analysis['assignedTo']!,
              category: analysis['category']!,
              description: analysis['description']!,
              date: parsedDate,
              rawSmsText: trimmedLine,
              source: TxnSource.pdf,
              referenceId: _referenceFrom(trimmedLine),
            ));
          }
        }
      }
    }
    return parsedTransactions;
  }

  /// Statement rows usually carry the same reference the SMS did. Extracting
  /// it lets a statement import recognise transactions already imported from
  /// SMS instead of duplicating them.
  static final RegExp _refRegex = RegExp(
      r'(?:ref(?:erence)?\s*(?:no|id)?\.?[:\s-]*|utr[:\s-]*)([A-Za-z0-9]{6,25})',
      caseSensitive: false);

  static String? _referenceFrom(String line) {
    final v = _refRegex.firstMatch(line)?.group(1);
    if (v == null || !RegExp(r'\d').hasMatch(v)) return null;
    return v.toUpperCase();
  }

  /// Helper to parse bank-format dates with multiple format variations
  static DateTime _parseDate(String dateStr) {
    try {
      if (dateStr.contains('-')) {
        List<String> p = dateStr.split('-');
        // Handles dd-mm-yyyy or yyyy-mm-dd (assuming dd-mm-yyyy for this format)
        return DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
      }
      return DateFormat('dd MMM yyyy').parse(dateStr);
    } catch (e) {
      return DateTime.now(); // Fallback to now if parsing fails
    }
  }
}

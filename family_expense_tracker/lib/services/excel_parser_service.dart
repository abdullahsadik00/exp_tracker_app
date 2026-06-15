import 'package:excel/excel.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart';
import '../models/transaction_model.dart';
import 'categorization_service.dart';
import 'local_db_service.dart';

/// Top-level function to decode Excel in a background isolate
List<Map<String, dynamic>> _decodeExcelInBackground(List<int> bytes) {
  try {
    var excel = Excel.decodeBytes(bytes);
    List<Map<String, dynamic>> dataRows = [];

    if (excel.tables.isEmpty) return dataRows;

    // Use the first sheet or default sheet
    var table = excel.tables.values.first;
    int consecutiveEmptyRows = 0;

    for (var row in table.rows) {
      // Safety check: if row is empty or first cell is null
      String col0 = row[0]?.value?.toString().trim() ?? '';
      
      if (col0.isEmpty) {
        consecutiveEmptyRows++;
        // If we hit 10 consecutive empty rows, break to prevent infinite scans
        if (consecutiveEmptyRows >= 10) break;
        continue;
      }

      // Reset empty row counter
      consecutiveEmptyRows = 0;

      // Strict Regex check: only process rows where the first column is a date
      // Handles formats like 01/04/2025, 1/4/2025, 01-04-2025, etc.
      if (!RegExp(r'^\d{1,2}[/-]\d{1,2}[/-]\d{4}$').hasMatch(col0)) continue;

      // Extract raw values safely as strings to pass back to main isolate
      dataRows.add({
        'date': col0,
        'description': row[1]?.value?.toString() ?? "",
        'debit': row[3]?.value?.toString() ?? "",
        'credit': row[4]?.value?.toString() ?? "",
        'balance': row.length > 5 && row[5]?.value != null 
            ? row[5]!.value.toString().replaceAll(',', '').trim() 
            : null,
        'rawRow': row.map((e) => e?.value?.toString() ?? "").join(" | "),
      });
    }

    return dataRows;
  } catch (e) {
    debugPrint("Background Excel Decode Error: $e");
    return [];
  }
}

class ExcelParserService {
  static Future<List<TransactionModel>> parseStatement(List<int> bytes) async {
    try {
      // 1. Decode Excel and scan rows in a background isolate to avoid ANR
      final List<Map<String, dynamic>> rawData = await compute(_decodeExcelInBackground, bytes);

      final rules = await LocalDbService.instance.getCategorizationRules();
      final categorizer = CategorizationService(rules);

      List<TransactionModel> transactions = [];

      // 2. Process extracted data on the main thread for categorization
      int count = 0;
      for (var raw in rawData) {
        String dateStr = raw['date'] as String;
        
        if (_isValidDate(dateStr)) {
          DateTime date = _parseDate(dateStr);
          String description = raw['description'] as String;
          
          double? debit = _parseDouble(raw['debit']);
          double? credit = _parseDouble(raw['credit']);
          double? balance = _parseDouble(raw['balance']);
          
          String type = (credit != null && credit > 0) ? 'credit' : 'debit';
          double amount = (type == 'credit') ? credit! : (debit ?? 0.0);
          
          var analysis = categorizer.analyzeTransaction(description, type);
          
          transactions.add(TransactionModel(
            id: '${DateTime.now().millisecondsSinceEpoch}_${transactions.length}',
            amount: amount,
            type: type,
            bankName: analysis['bankName'] ?? 'SBI',
            assignedTo: analysis['assignedTo'] ?? 'Unassigned',
            category: analysis['category'] ?? 'Other',
            description: analysis['description'] ?? (description.isEmpty ? 'No Details' : description),
            date: date,
            rawSmsText: 'Excel Isol: ${raw['rawRow']}',
            closingBalance: balance,
          ));
        }
        
        count++;
        if (count % 20 == 0) {
          // Yield control back to the UI thread to prevent freezing
          await Future.delayed(const Duration(milliseconds: 10)); // Shorter delay for local parsing
        }
      }

      return transactions;
    } catch (e) {
      debugPrint('Error in ExcelParserService.parseStatement: $e');
      return [];
    }
  }

  static bool _isValidDate(String? value) {
    if (value == null || value.isEmpty) return false;
    final dateRegex = RegExp(r'\d{1,2}[/-]\d{1,2}[/-]\d{2,4}');
    return dateRegex.hasMatch(value);
  }

  static DateTime _parseDate(String dateStr) {
    try {
      String cleanStr = dateStr.trim();
      
      DateFormat? formatter;
      if (cleanStr.contains('/')) {
        formatter = DateFormat('dd/MM/yyyy');
      } else if (cleanStr.contains('-')) {
        formatter = DateFormat('dd-MM-yyyy');
      }

      if (formatter != null) {
        return formatter.parse(cleanStr);
      }
    } catch (e) {
      // Log or handle error if needed
    }
    
    try {
      return DateTime.parse(dateStr);
    } catch (_) {}
    
    return DateTime.now();
  }

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    
    String strValue = value.toString().replaceAll(',', '').trim();
    return double.tryParse(strValue);
  }
}

import 'package:csv/csv.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/transaction_model.dart';
import 'package:intl/intl.dart';

class ExportService {
  static Future<void> exportTransactions(List<TransactionModel> txns) async {
    try {
      List<List<dynamic>> rows = [];
      
      // Headers as requested
      rows.add(['Date', 'Amount', 'Type', 'Category', 'Bank', 'AssignedTo', 'Balance', 'Description', 'Notes']);

      // Data mapping
      for (var txn in txns) {
        rows.add([
          DateFormat('dd/MM/yyyy').format(txn.date),
          txn.amount,
          txn.type,
          txn.category,
          txn.bankName,
          txn.assignedTo,
          txn.closingBalance ?? 0.0,
          txn.description,
          txn.notes ?? ""
        ]);
      }

      // Convert using Csv().encode (csv 8.0.0+ syntax)
      String csvData = Csv().encode(rows);
      
      final directory = await getApplicationDocumentsDirectory();
      final path = "${directory.path}/transactions_export.csv";
      final file = File(path);
      await file.writeAsString(csvData);

      // Share with correct mimeType and text
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/csv')], 
        text: 'My Expense Backup'
      );
    } catch (e) {
      // Error handling
      rethrow;
    }
  }
}

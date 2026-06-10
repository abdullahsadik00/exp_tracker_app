import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/transaction_model.dart';
import '../services/local_db_service.dart';
import '../services/excel_parser_service.dart';
import '../theme/app_colors.dart';

class PdfStatementScreen extends StatefulWidget {
  const PdfStatementScreen({super.key});

  @override
  State<PdfStatementScreen> createState() => _PdfStatementScreenState();
}

class _PdfStatementScreenState extends State<PdfStatementScreen> {
  final LocalDbService _localDbService = LocalDbService();
  bool _isParsing = false;

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> pickAndParseExcel() async {
    // 1. Pick Excel File
    FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );

    if (result == null || result.files.single.path == null) return;

    setState(() => _isParsing = true);

    int total = 0;
    int current = 0;
    StateSetter? dialogSetState;

    // Show non-dismissible loading dialog with progress
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            dialogSetState = setDialogState;
            
            return AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Importing Transactions", 
                    style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 20),
                  const CircularProgressIndicator(color: AppColors.accent),
                  const SizedBox(height: 20),
                  const Text(
                    "Analyzing and saving transactions... Please wait.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  const Text("Please keep the app open.", 
                    style: TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.w500)),
                ],
              ),
            );
          },
        );
      },
    );

    try {
      final List<int> bytes = File(result.files.single.path!).readAsBytesSync();

      // 2. Parse Transactions via dedicated Service
      List<TransactionModel> parsedTransactions = await ExcelParserService.parseStatement(bytes);
      total = parsedTransactions.length;
      if (dialogSetState != null) dialogSetState!(() {});

      if (parsedTransactions.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No valid transactions found in the Excel file. Please check the format.'),
              duration: Duration(seconds: 5),
            ),
          );
        }
      } else {
        // Use the new batch upload method
        int added = await _localDbService.insertTransactionsBatch(parsedTransactions);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Successfully imported $added new transactions!'),
              backgroundColor: Colors.green,
            ),
          );
          // Only pop if we are not at the root
          if (Navigator.canPop(context)) {
            Navigator.pop(context); // Close the screen if possible
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception: ', '')),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isParsing = false);
        // Safely close the loading dialog
        if (Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Excel Statement Parser', 
          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoCard(),
            const SizedBox(height: 32),
            const Text('Upload Guidelines', 
              style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            const Text('Ensure your Excel follows the standard format: Date, Details, Ref, Debit, Credit, Balance.', 
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '⚠️ Please open the Excel file and \'Save As\' without a password before uploading.',
                      style: TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 140,
              child: ElevatedButton(
                onPressed: _isParsing ? null : () => pickAndParseExcel(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.surface,
                  foregroundColor: AppColors.accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                    side: const BorderSide(color: AppColors.accent, width: 2),
                  ),
                  elevation: 0,
                ),
                child: _isParsing
                  ? const CircularProgressIndicator(color: AppColors.accent)
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.upload_file, size: 48),
                        SizedBox(height: 12),
                        Text('Upload & Parse Statement', 
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
              ),
            ),
            const SizedBox(height: 24),
            const Center(
              child: Text('Supports Excel & CSV bank statements', 
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.accent.withOpacity(0.3)),
      ),
      child: Row(
        children: const [
          Icon(Icons.info_outline, color: AppColors.accent),
          SizedBox(width: 16),
          Expanded(
            child: Text(
              'Your statement is processed locally. Excel files are more reliable for parsing than PDFs.',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

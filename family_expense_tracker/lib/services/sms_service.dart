import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/transaction_model.dart';
import 'categorization_service.dart';

class SmsService {
  Future<void> requestSmsPermission() async {
    var status = await Permission.sms.status;
    if (!status.isGranted) {
      await Permission.sms.request();
    }
  }

  Future<List<TransactionModel>> fetchBankMessages() async {
    final smsQuery = SmsQuery();

    // flutter_sms_inbox uses querySms, not query with SQL syntax
    final messages = await smsQuery.querySms(
      kinds: [SmsQueryKind.inbox],
      count: 500, // adjust as needed
    );

    // Filter for bank messages manually
    final bankMessages = messages.where((msg) {
      final body = msg.body ?? '';
      return body.contains('SBI') || body.contains('BoB');
    }).toList();

    final List<TransactionModel> transactions = [];
    final primaryRegex = RegExp(
      r'(?:Rs\.?|INR|₹|debited by|credited by)\s*([0-9,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    );
    final fallbackRegex = RegExp(r'\d+,\d+(?:\.\d{2})?|\d+(?:\.\d{2})?');

    for (final message in bankMessages) {
      final body = message.body ?? '';
      String bodyLower = body.toLowerCase();

      // Skip spam/promotional/OTP messages
      if (bodyLower.contains('offer') || 
          bodyLower.contains('valid till') || 
          bodyLower.contains('credit card offer') || 
          bodyLower.contains('loan') || 
          bodyLower.contains('apply') ||
          bodyLower.contains('kyc') ||
          bodyLower.contains('otp')) {
        continue; 
      }

      // Must be a transactional message
      if (!bodyLower.contains('debited') && 
          !bodyLower.contains('credited') && 
          !bodyLower.contains('withdrawn') && 
          !bodyLower.contains('deposited')) {
        continue;
      }
      
      String? amountStr;
      final primaryMatch = primaryRegex.firstMatch(body);
      if (primaryMatch != null) {
        amountStr = primaryMatch.group(1);
      } else {
        final fallbackMatch = fallbackRegex.firstMatch(body);
        if (fallbackMatch != null) {
          amountStr = fallbackMatch.group(0);
        }
      }

      if (amountStr != null) {
        final amount = double.parse(amountStr.replaceAll(',', ''));
        
        // Smarter type detection
        final lowerBody = body.toLowerCase();
        String type = 'debit'; // default
        
        if (lowerBody.contains('credited')) {
          type = 'credit';
        } else if (lowerBody.contains('debited')) {
          type = 'debit';
        } else {
          final isCredit = lowerBody.contains('received') || 
                          lowerBody.contains('deposited');
          final isDebit = lowerBody.contains('sent') || 
                         lowerBody.contains('paid');
          
          if (isCredit && !isDebit) {
            type = 'credit';
          } else if (isDebit) {
            type = 'debit';
          }
        }
        
        // Smart Categorization
        final analysis = CategorizationService.analyzeTransaction(body, type);

        transactions.add(
          TransactionModel(
            id: 'sms_${DateTime.now().microsecondsSinceEpoch}',
            amount: amount,
            bankName: analysis['bankName']!,
            type: type,
            date: message.date ?? DateTime.now(),
            assignedTo: analysis['assignedTo']!,
            category: analysis['category']!,
            description: analysis['description']!,
            rawSmsText: body,
          ),
        );
      }
    }
    return transactions;
  }
}

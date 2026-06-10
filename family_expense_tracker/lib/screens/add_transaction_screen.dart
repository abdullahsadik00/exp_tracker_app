import 'package:flutter/material.dart';
import '../models/transaction_model.dart';
import '../services/local_db_service.dart';
import '../theme/app_colors.dart';
import 'package:intl/intl.dart';

class AddTransactionScreen extends StatefulWidget {
  const AddTransactionScreen({super.key});

  @override
  State<AddTransactionScreen> createState() => _AddTransactionScreenState();
}

class _AddTransactionScreenState extends State<AddTransactionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _localDbService = LocalDbService();
  
  final _amountController = TextEditingController();
  String _type = 'debit';
  String _bank = 'SBI';
  String _assignedTo = 'Me';
  String _selectedCategory = 'Other';
  final _descriptionController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  bool _isLoading = false;
  
  // Transfer related state
  bool _isTransfer = false;
  String _fromBank = 'SBI';
  String _toBank = 'BoB';

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _saveTransaction() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    
    try {
      String description = _descriptionController.text.trim();
      if (description.isEmpty) {
        description = 'Manual Entry';
      } else {
        // Apply Title Case (often referred to as Camel Case by users)
        description = description.split(' ').map((word) {
          if (word.isEmpty) return '';
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        }).join(' ');
      }

      final transactions = <TransactionModel>[];
      
      if (_isTransfer) {
        if (_fromBank == _toBank) {
          throw Exception('Source and destination banks cannot be the same');
        }
        
        final transferId = DateTime.now().microsecondsSinceEpoch.toString();
        final amount = double.parse(_amountController.text);
        
        // Debit from source
        transactions.add(TransactionModel(
          id: '${transferId}_out',
          amount: amount,
          type: 'debit',
          bankName: _fromBank,
          assignedTo: _assignedTo,
          category: 'Transfer',
          date: _selectedDate,
          rawSmsText: description.isEmpty ? 'Transfer to $_toBank' : description,
          description: description.isEmpty ? 'Transfer to $_toBank' : description,
        ));
        
        // Credit to destination
        transactions.add(TransactionModel(
          id: '${transferId}_in',
          amount: amount,
          type: 'credit',
          bankName: _toBank,
          assignedTo: _assignedTo,
          category: 'Transfer',
          date: _selectedDate,
          rawSmsText: description.isEmpty ? 'Transfer from $_fromBank' : description,
          description: description.isEmpty ? 'Transfer from $_fromBank' : description,
        ));
      } else {
        transactions.add(TransactionModel(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          amount: double.parse(_amountController.text),
          type: _type,
          bankName: _bank,
          assignedTo: _assignedTo,
          category: _selectedCategory,
          date: _selectedDate,
          rawSmsText: description,
          description: description,
        ));
      }
      
      // 2. Insert into local database
      await _localDbService.insertTransactionsBatch(transactions);
      
      // 3. Clear UI on success
      if (mounted) {
        _formKey.currentState!.reset();
        _amountController.clear();
        _descriptionController.clear();
        FocusScope.of(context).unfocus();
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Transaction saved successfully!'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          )
        );
        
        if (Navigator.canPop(context)) {
          Navigator.pop(context, _selectedDate);
        }
      }
    } catch (e, stacktrace) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          )
        );
        print('SAVE ERROR: $e\n$stacktrace');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: AppColors.accent,
              onPrimary: Colors.white,
              surface: AppColors.surface,
              onSurface: AppColors.textPrimary,
            ),
            dialogBackgroundColor: AppColors.background,
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Add Transaction', 
          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Transaction Details', 
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
              const SizedBox(height: 16),
              
              // Mode Toggle
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _isTransfer = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: !_isTransfer ? AppColors.accent : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              'Standard',
                              style: TextStyle(
                                color: !_isTransfer ? Colors.white : AppColors.textSecondary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _isTransfer = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: _isTransfer ? AppColors.accent : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              'Transfer',
                              style: TextStyle(
                                color: _isTransfer ? Colors.white : AppColors.textSecondary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Description Input
              const Text('Description', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextFormField(
                controller: _descriptionController,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Merchant Name or Details',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.all(20),
                ),
              ),
              const SizedBox(height: 24),
              
              // Amount Input
              const Text('Amount', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 24, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  hintText: '0.00',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                  prefixText: '₹ ',
                  prefixStyle: const TextStyle(color: AppColors.accent, fontSize: 24, fontWeight: FontWeight.bold),
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.all(20),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) return 'Please enter an amount';
                  if (double.tryParse(value) == null) return 'Please enter a valid number';
                  return null;
                },
              ),
              const SizedBox(height: 24),

              if (!_isTransfer) ...[
                // Type Dropdown
                _buildDropdownLabel('Type'),
                DropdownButtonFormField<String>(
                  value: _type,
                  dropdownColor: AppColors.surface,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: _dropdownDecoration(),
                  items: ['credit', 'debit'].map((val) => DropdownMenuItem(
                    value: val, 
                    child: Text(val.toUpperCase(), style: TextStyle(color: val == 'credit' ? Colors.green : Colors.red)),
                  )).toList(),
                  onChanged: (val) => setState(() => _type = val!),
                ),
                const SizedBox(height: 24),

                // Bank Dropdown
                _buildDropdownLabel('Bank / Account'),
                DropdownButtonFormField<String>(
                  value: _bank,
                  dropdownColor: AppColors.surface,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: _dropdownDecoration(),
                  items: ['SBI', 'BoB', 'Cash'].map((val) => DropdownMenuItem(
                    value: val, 
                    child: Text(val),
                  )).toList(),
                  onChanged: (val) => setState(() => _bank = val!),
                ),
                const SizedBox(height: 24),
              ] else ...[
                // Transfer Fields
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.accent.withOpacity(0.1)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildDropdownLabel('From Bank'),
                            DropdownButtonFormField<String>(
                              value: _fromBank,
                              dropdownColor: AppColors.surface,
                              isExpanded: true,
                              style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                              decoration: _dropdownDecoration().copyWith(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: ['SBI', 'BoB', 'Cash'].map((val) => DropdownMenuItem(
                                value: val, 
                                child: Text(val, overflow: TextOverflow.ellipsis),
                              )).toList(),
                              onChanged: (val) => setState(() => _fromBank = val!),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.swap_horiz_rounded, color: AppColors.accent, size: 20),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildDropdownLabel('To Bank'),
                            DropdownButtonFormField<String>(
                              value: _toBank,
                              dropdownColor: AppColors.surface,
                              isExpanded: true,
                              style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                              decoration: _dropdownDecoration().copyWith(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: ['SBI', 'BoB', 'Cash'].map((val) => DropdownMenuItem(
                                value: val, 
                                child: Text(val, overflow: TextOverflow.ellipsis),
                              )).toList(),
                              onChanged: (val) => setState(() => _toBank = val!),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // Assigned To Dropdown
              _buildDropdownLabel('Assigned To'),
              DropdownButtonFormField<String>(
                value: _assignedTo,
                dropdownColor: AppColors.surface,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: _dropdownDecoration(),
                items: ['Me', 'Mom', 'Dad'].map((val) => DropdownMenuItem(
                  value: val, 
                  child: Text(val),
                )).toList(),
                onChanged: (val) => setState(() => _assignedTo = val!),
              ),
              const SizedBox(height: 24),

              if (!_isTransfer) ...[
                // Category Dropdown
                _buildDropdownLabel('Category'),
                DropdownButtonFormField<String>(
                  value: TransactionModel.availableCategories.contains(_selectedCategory) ? _selectedCategory : 'Other',
                  dropdownColor: AppColors.surface,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: _dropdownDecoration(),
                  items: TransactionModel.availableCategories.map((val) => DropdownMenuItem(
                    value: val, 
                    child: Text(val),
                  )).toList(),
                  onChanged: (val) => setState(() => _selectedCategory = val!),
                ),
                const SizedBox(height: 24),
              ],
              
              // Date Picker
              _buildDropdownLabel('Date'),
              GestureDetector(
                onTap: () => _selectDate(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        DateFormat('dd MMM yyyy').format(_selectedDate),
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
                      ),
                      const Icon(Icons.calendar_today, color: AppColors.accent, size: 20),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 48),

              // Save Button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _saveTransaction,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                  child: _isLoading 
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Save Transaction', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDropdownLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(label, style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
    );
  }

  InputDecoration _dropdownDecoration() {
    return InputDecoration(
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    );
  }
}

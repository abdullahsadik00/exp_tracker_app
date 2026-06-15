import 'dart:async';
import 'package:flutter/material.dart';
import '../services/local_db_service.dart';
import '../models/transaction_model.dart';

import 'add_transaction_screen.dart';
import '../theme/app_colors.dart';
import 'package:intl/intl.dart';

class TransactionsScreen extends StatefulWidget {
  final String? initialFilter;
  const TransactionsScreen({super.key, this.initialFilter});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  final LocalDbService _localDbService = LocalDbService();
  late StreamSubscription _dbChangeSubscription;
  late String _selectedFilter;
  int _itemsPerPage = 50;
  int _currentPage = 1;
  Set<String> _selectedTxIds = {};
  List<TransactionModel> _allTransactions = [];
  bool _isLoading = true;

  final List<String> _filters = ['All', 'Unassigned', 'Me', 'Mom', 'Dad', 'SBI', 'BoB'];
  String _selectedMonth = 'All Time';
  String _selectedCategory = 'All Categories';

  // Categories are now managed in TransactionModel.availableCategories

  @override
  void initState() {
    super.initState();
    _selectedFilter = widget.initialFilter ?? 'All';
    _loadTransactions();
    _dbChangeSubscription = _localDbService.onChange.listen((_) {
      if (mounted) _loadTransactions();
    });
  }

  @override
  void dispose() {
    _dbChangeSubscription.cancel();
    super.dispose();
  }

  Future<void> _loadTransactions() async {
    final bankFilters = {'SBI', 'BoB'};
    String? assignedTo;
    String? bankName;

    if (_selectedFilter == 'All') {
      assignedTo = 'All';
    } else if (bankFilters.contains(_selectedFilter)) {
      bankName = _selectedFilter;
    } else {
      assignedTo = _selectedFilter;
    }

    var data = await LocalDbService.instance.getFilteredTransactions(
      assignedTo: assignedTo,
      bankName: bankName,
      monthYear: _selectedMonth,
      category: _selectedCategory,
    );

    if (mounted) {
      setState(() {
        _allTransactions = data;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Transactions',
            style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: AppColors.accent),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const AddTransactionScreen()),
              ).then((result) {
                if (result is DateTime) {
                  setState(() {
                    _selectedMonth = DateFormat('MMM yyyy').format(result);
                    _currentPage = 1;
                  });
                }
                _loadTransactions();
              });
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
        : Column(
            children: [
              _buildFilterChips(),
              _buildAdvancedFilters(_getMonths(_allTransactions)),
              const SizedBox(height: 8),
              Expanded(child: _buildTransactionList(_allTransactions)),
            ],
          ),
      floatingActionButton: _selectedTxIds.isNotEmpty
        ? FloatingActionButton.extended(
            heroTag: 'bulk_actions_fab',
            onPressed: _showBulkActionsSheet,
            icon: const Icon(Icons.tune_rounded, color: Colors.white),
            label: Text('${_selectedTxIds.length} Selected',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            backgroundColor: AppColors.accent,
            elevation: 8,
          )
        : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  List<String> _getMonths(List<TransactionModel> allTransactions) {
    final months = ['All Time'];
    final Set<String> uniqueMonths = {};
    for (var txn in allTransactions) {
      uniqueMonths.add(DateFormat('MMM yyyy').format(txn.date));
    }
    final sortedMonths = uniqueMonths.toList()..sort((a, b) {
      final dateA = DateFormat('MMM yyyy').parse(a);
      final dateB = DateFormat('MMM yyyy').parse(b);
      return dateB.compareTo(dateA); // Newest first
    });
    months.addAll(sortedMonths);
    return months;
  }

  Widget _buildFilterChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: SizedBox(
        height: 42,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          itemCount: _filters.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final label = _filters[index];
            final isSelected = _selectedFilter == label;
            return FilterChip(
              label: Text(label),
              selected: isSelected,
              onSelected: (_) {
                setState(() {
                  _selectedFilter = label;
                  _currentPage = 1;
                  _isLoading = true;
                });
                _loadTransactions();
              },
              selectedColor: AppColors.accent.withOpacity(0.15),
              backgroundColor: AppColors.surface,
              checkmarkColor: AppColors.accent,
              labelStyle: TextStyle(
                color: isSelected ? AppColors.accent : AppColors.textSecondary,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                fontSize: 13,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: isSelected ? AppColors.accent : Colors.white.withOpacity(0.08),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            );
          },
        ),
      ),
    );
  }

  Widget _buildAdvancedFilters(List<String> months) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Row(
        children: [
          Expanded(
            child: _buildDropdown(
              value: _selectedMonth,
              items: months,
              onChanged: (val) {
                setState(() {
                  _selectedMonth = val!;
                  _currentPage = 1;
                  _isLoading = true;
                });
                _loadTransactions();
              },
              icon: Icons.calendar_month,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildDropdown(
              value: _selectedCategory,
              items: ['All Categories', ...TransactionModel.availableCategories],
              onChanged: (val) {
                setState(() {
                  _selectedCategory = val!;
                  _currentPage = 1;
                  _isLoading = true;
                });
                _loadTransactions();
              },
              icon: Icons.category,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: items.contains(value) ? value : items.first,
          isExpanded: true,
          dropdownColor: AppColors.surface,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.accent),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
          items: items.map((String item) {
            return DropdownMenuItem<String>(
              value: item,
              child: Row(
                children: [
                  Icon(icon, size: 16, color: AppColors.textSecondary.withOpacity(0.5)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(item, overflow: TextOverflow.ellipsis)),
                ],
              ),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildTransactionList(List<TransactionModel> transactions) {
    if (transactions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined,
                color: AppColors.textSecondary.withOpacity(0.4), size: 56),
            const SizedBox(height: 16),
            Text(
              'No matching transactions found',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 15),
            ),
          ],
        ),
      );
    }

    // Pagination Logic
    int totalPages = (transactions.length / _itemsPerPage).ceil();
    if (totalPages == 0) totalPages = 1;
    if (_currentPage > totalPages) _currentPage = totalPages;

    final paginatedList = transactions.skip((_currentPage - 1) * _itemsPerPage).take(_itemsPerPage).toList();

        // Group transactions by date
        final grouped = <String, List<TransactionModel>>{};
        for (final txn in paginatedList) {
          final key = DateFormat('dd MMM yyyy').format(txn.date);
          grouped.putIfAbsent(key, () => []).add(txn);
        }

        final dateKeys = grouped.keys.toList();

        return ListView.builder(
          key: const PageStorageKey('transactions_list_key'),
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: dateKeys.length + 1,
          itemBuilder: (context, index) {
            if (index == dateKeys.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 24.0),
                child: Column(
                  children: [
                    // Row 1: Items per page dropdown
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Transactions per page: ', 
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white.withOpacity(0.1)),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              value: [10, 25, 50, 75, 100].contains(_itemsPerPage) ? _itemsPerPage : 50,
                              dropdownColor: AppColors.surface,
                              icon: const Icon(Icons.arrow_drop_down, color: AppColors.accent),
                              style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
                              items: [10, 25, 50, 75, 100].map((int value) {
                                return DropdownMenuItem<int>(
                                  value: value,
                                  child: Text(value.toString()),
                                );
                              }).toList(),
                              onChanged: (newValue) {
                                if (newValue != null) {
                                  setState(() {
                                    _itemsPerPage = newValue;
                                    _currentPage = 1;
                                  });
                                }
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Row 2: Page Navigation
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left, color: AppColors.accent),
                          onPressed: _currentPage == 1 ? null : () => setState(() => _currentPage--),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: () => _showJumpToPageDialog(context, totalPages),
                          icon: const Icon(Icons.edit, size: 16, color: AppColors.accent),
                          label: Text('Page $_currentPage of $totalPages', 
                            style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.chevron_right, color: AppColors.accent),
                          onPressed: _currentPage >= totalPages ? null : () => setState(() => _currentPage++),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }
            final dateLabel = dateKeys[index];
            final dayTxns = grouped[dateLabel]!;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 20, bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(dateLabel,
                          style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5)),
                      IconButton(
                        icon: const Icon(Icons.swap_vert, size: 20, color: AppColors.accent),
                        onPressed: () => _showReorderDayBottomSheet(context, dayTxns.first.date, dayTxns.first.bankName),
                        tooltip: 'Reorder transactions for this day',
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                ...dayTxns.map((txn) {
                  try {
                    return _buildTransactionTile(txn, key: ValueKey('tile_${txn.id}'));
                  } catch (e) {
                    return ListTile(
                      title: const Text('Error rendering transaction', style: TextStyle(color: Colors.red)),
                      subtitle: Text('Details: $e'),
                      leading: const Icon(Icons.error_outline, color: Colors.red),
                    );
                  }
                }),
              ],
            );
          },
        );
  }

  void _showJumpToPageDialog(BuildContext context, int totalPages) {
    final TextEditingController controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Jump to Page', style: TextStyle(color: AppColors.textPrimary)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Enter page number',
            hintStyle: TextStyle(color: AppColors.textSecondary),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent, width: 2)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              final int? page = int.tryParse(controller.text);
              if (page != null) {
                setState(() {
                  _currentPage = page.clamp(1, totalPages);
                });
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text('Go', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionTile(TransactionModel txn, {Key? key}) {
    final isCredit = txn.type == 'credit';
    final amountColor = isCredit ? AppColors.credit : AppColors.debit;
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 2);
    final timeFormat = DateFormat('hh:mm a');

    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _selectedTxIds.contains(txn.id) ? AppColors.accent.withOpacity(0.1) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _selectedTxIds.contains(txn.id) ? AppColors.accent : Colors.white.withOpacity(0.04)),
      ),
      child: ListTile(
        onTap: () {
          if (_selectedTxIds.isNotEmpty) {
            setState(() {
              if (_selectedTxIds.contains(txn.id)) {
                _selectedTxIds.remove(txn.id);
              } else {
                _selectedTxIds.add(txn.id);
              }
            });
          } else {
            _showTransactionDetails(context, txn);
          }
        },
        onLongPress: () {
          setState(() {
            _selectedTxIds.add(txn.id);
          });
        },
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: amountColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            isCredit ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
            color: amountColor,
            size: 22,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                txn.description,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 15),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            _buildCategoryBadge(txn.category),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    txn.bankName,
                    style: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6.0),
                  child: Text('•', style: TextStyle(color: AppColors.textSecondary)),
                ),
                Flexible(
                  child: Text(
                    txn.assignedTo,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              txn.rawSmsText,
              style: TextStyle(
                  color: AppColors.textSecondary.withOpacity(0.7),
                  fontSize: 11,
                  fontStyle: FontStyle.italic),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        trailing: Text(
          '${isCredit ? '+' : '-'} ${currencyFormat.format(txn.amount)}',
          style: TextStyle(
            color: amountColor,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  void _showTransactionDetails(BuildContext context, TransactionModel txn) {
    final currencyFormat = NumberFormat.currency(symbol: '₹', decimalDigits: 2);
    final dateFormat = DateFormat('dd MMM yyyy');
    final timeFormat = DateFormat('hh:mm a');
    final isCredit = txn.type == 'credit';
    final amountColor = isCredit ? AppColors.credit : AppColors.debit;
    
    final TextEditingController notesController = TextEditingController(text: txn.notes ?? '');
    final TextEditingController amountController = TextEditingController(text: txn.amount.toStringAsFixed(2));
    final TextEditingController balanceController = TextEditingController(text: txn.closingBalance?.toStringAsFixed(2) ?? '');
    bool isSaving = false;

    // Local state for the bottom sheet
    String selectedCategory = txn.category;
    String selectedAssignedTo = txn.assignedTo;
    String selectedBank = txn.bankName;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
              ),
              padding: EdgeInsets.only(
                top: 12,
                left: 24,
                right: 24,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Drag Handle & Delete
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const SizedBox(width: 48), // Balancing spacer
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 24),
                            onPressed: () => _showDeleteConfirmation(context, txn),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Layout: Amount (Large)
                    // Amount Input
                    TextFormField(
                      controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: amountColor,
                        fontSize: 36,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1,
                      ),
                      decoration: InputDecoration(
                        prefixText: isCredit ? '+ ' : '- ',
                        prefixStyle: TextStyle(color: amountColor, fontSize: 36, fontWeight: FontWeight.w900),
                        border: InputBorder.none,
                        hintText: '0.00',
                        hintStyle: TextStyle(color: amountColor.withOpacity(0.3)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isCredit ? 'Credit Transaction' : 'Debit Transaction',
                      style: TextStyle(
                        color: amountColor.withOpacity(0.7),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: TextFormField(
                        controller: balanceController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          prefixText: 'Closing Balance: ₹',
                          prefixStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 16, fontWeight: FontWeight.w600),
                          border: InputBorder.none,
                          hintText: '0.00',
                          hintStyle: TextStyle(color: AppColors.textSecondary.withOpacity(0.3)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Bank & Assignment Dropdowns
                    Row(
                      children: [
                        Expanded(
                          child: _buildEditableDropdown(
                            label: 'Bank',
                            value: selectedBank,
                            items: ['SBI', 'BoB', 'Cash', 'Other'],
                            onChanged: (val) => setModalState(() => selectedBank = val!),
                            icon: Icons.account_balance_outlined,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildEditableDropdown(
                            label: 'Assignment',
                            value: selectedAssignedTo,
                            items: ['Me', 'Mom', 'Dad', 'Unassigned'],
                            onChanged: (val) => setModalState(() => selectedAssignedTo = val!),
                            icon: Icons.person_outline,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Category Dropdown
                    _buildEditableDropdown(
                      label: 'Category',
                      value: TransactionModel.availableCategories.contains(selectedCategory) ? selectedCategory : 'Other',
                      items: TransactionModel.availableCategories,
                      onChanged: (val) => setModalState(() => selectedCategory = val!),
                      icon: Icons.category_outlined,
                    ),
                    const SizedBox(height: 24),

                    // Info Grid
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white.withOpacity(0.05)),
                      ),
                      child: Column(
                        children: [
                          _buildInfoRow('Bank Account', txn.bankName, Icons.account_balance_outlined),
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Divider(color: Colors.white10),
                          ),
                          _buildInfoRow('Date', dateFormat.format(txn.date), Icons.calendar_today_outlined),
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Divider(color: Colors.white10),
                          ),
                          _buildInfoRow('Time', timeFormat.format(txn.date), Icons.access_time_rounded),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Raw Description / SMS
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withOpacity(0.03)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ORIGINAL DETAILS',
                            style: TextStyle(
                              color: AppColors.textSecondary.withOpacity(0.5),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            txn.description,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.5,
                            ),
                          ),
                          if (txn.rawSmsText != txn.description) ...[
                            const SizedBox(height: 8),
                            Text(
                              txn.rawSmsText,
                              style: TextStyle(
                                color: AppColors.textSecondary.withOpacity(0.7),
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Notes Section
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(left: 4, bottom: 8),
                          child: Text(
                            'CUSTOM NOTES',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                        TextField(
                          controller: notesController,
                          maxLines: 2,
                          style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Add notes...',
                            hintStyle: TextStyle(color: AppColors.textSecondary.withOpacity(0.5)),
                            filled: true,
                            fillColor: AppColors.surface,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(color: Colors.white.withOpacity(0.05)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(color: AppColors.accent, width: 1),
                            ),
                            contentPadding: const EdgeInsets.all(16),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: ElevatedButton(
                            onPressed: isSaving ? null : () async {
                              setModalState(() => isSaving = true);
                              try {
                                await _localDbService.updateTransaction(
                                  txn.copyWith(
                                    category: selectedCategory,
                                    assignedTo: selectedAssignedTo,
                                    bankName: selectedBank,
                                    notes: notesController.text,
                                    amount: double.tryParse(amountController.text) ?? txn.amount,
                                    closingBalance: double.tryParse(balanceController.text),
                                  ),
                                );
                                FocusScope.of(context).unfocus();
                                if (context.mounted) {
                                  Navigator.pop(context); // Close bottom sheet
                                  await _loadTransactions(); // Refresh UI without resetting scroll
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Transaction updated successfully!'),
                                        backgroundColor: Colors.green,
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  }
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                                  );
                                }
                              } finally {
                                if (context.mounted) {
                                  setModalState(() => isSaving = false);
                                }
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accent,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              elevation: 0,
                            ),
                            child: isSaving 
                              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              : const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Close Button
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.textSecondary,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text('Close', style: TextStyle(fontSize: 15)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        );
      },
    );
  }

  void _showDeleteConfirmation(BuildContext context, TransactionModel txn) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete Transaction?', style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('Are you sure you want to permanently delete this transaction?', 
          style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              await _localDbService.deleteTransaction(txn.id);
              await _loadTransactions(); // Refresh UI
              if (context.mounted) {
                Navigator.pop(ctx); // Close dialog
                Navigator.pop(context); // Close bottom sheet
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Transaction deleted'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildEditableDropdown({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    required IconData icon,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              color: AppColors.textSecondary.withOpacity(0.5),
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButtonFormField<String>(
              value: items.contains(value) ? value : items.first,
              dropdownColor: AppColors.surface,
              icon: const Icon(Icons.arrow_drop_down, color: AppColors.accent),
              decoration: const InputDecoration(border: InputBorder.none),
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
              items: items.map((String item) {
                return DropdownMenuItem<String>(
                  value: item,
                  child: Text(item),
                );
              }).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPremiumChip(String label, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.textSecondary),
        const SizedBox(width: 12),
        Text(
          label,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  void _showReorderDayBottomSheet(BuildContext context, DateTime day, String bankName) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StreamBuilder<List<TransactionModel>>(
          stream: _localDbService.getAllTransactionsStream(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            
            // Filter transactions for this exact day (do NOT filter by bankName)
            var dayTxns = snapshot.data!.where((tx) => 
              tx.date.year == day.year && 
              tx.date.month == day.month && 
              tx.date.day == day.day
            ).toList()..sort((a, b) => a.date.compareTo(b.date)); // Oldest first for reordering

            if (dayTxns.isEmpty) {
              return Container(
                padding: const EdgeInsets.all(24),
                decoration: const BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: const Text('No transactions to reorder', style: TextStyle(color: Colors.white)),
              );
            }

            return StatefulBuilder(
              builder: (context, setModalState) {
                return Container(
                  height: MediaQuery.of(context).size.height * 0.7,
                  decoration: const BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                  ),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Text('Reorder: ${DateFormat('dd MMM yyyy').format(day)}', 
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                      Text('Bank: $bankName', style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
                      const SizedBox(height: 16),
                      Expanded(
                        child: ReorderableListView.builder(
                          itemCount: dayTxns.length,
                          onReorder: (oldIndex, newIndex) {
                            setModalState(() {
                              if (newIndex > oldIndex) newIndex -= 1;
                              final item = dayTxns.removeAt(oldIndex);
                              dayTxns.insert(newIndex, item);
                            });
                          },
                          itemBuilder: (context, index) {
                            final tx = dayTxns[index];
                            final isCredit = tx.type == 'credit';
                            return ListTile(
                              key: ValueKey(tx.id),
                              leading: Icon(
                                isCredit ? Icons.arrow_downward : Icons.arrow_upward,
                                color: isCredit ? Colors.green : Colors.red,
                              ),
                              title: Text(tx.description, 
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text('₹${tx.amount.toStringAsFixed(2)}', 
                                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                              trailing: const Icon(Icons.drag_handle, color: Colors.white30),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton(
                          onPressed: () async {
                            await _localDbService.updateTransactionTimeAndSync(dayTxns, bankName);
                            if (context.mounted) {
                              Navigator.pop(context);
                              // Refresh after pop to ensure main list is ready to update
                              _loadTransactions();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('New order saved and balances updated!'), backgroundColor: Colors.green),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: const Text('Save New Order', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                );
              }
            );
          }
        );
      },
    );
  }

  Widget _buildCategoryBadge(String category) {
    Color badgeColor;
    switch (category) {
      case 'Groceries': badgeColor = Colors.green; break;
      case 'Dining': badgeColor = Colors.orange; break;
      case 'Shopping': badgeColor = Colors.pink; break;
      case 'Utilities': badgeColor = Colors.blue; break;
      case 'Salary': badgeColor = Colors.purple; break;
      case 'Healthcare': badgeColor = Colors.red; break;
      case 'Transportation': badgeColor = Colors.teal; break;
      case 'Education': badgeColor = Colors.indigo; break;
      case 'Gifts': badgeColor = Colors.amber; break;
      case 'Personal Care': badgeColor = Colors.cyan; break;
      default: badgeColor = AppColors.textSecondary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: badgeColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: badgeColor.withOpacity(0.3)),
      ),
      child: Text(
        category,
        style: TextStyle(
            color: badgeColor, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  // ─── Bulk Actions Sheet ────────────────────────────────────────────────────
  void _showBulkActionsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '${_selectedTxIds.length} Transactions Selected',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            _buildBulkActionTile(
              icon: Icons.person_outline_rounded,
              iconColor: Colors.tealAccent,
              label: 'Assign To…',
              subtitle: 'Change owner for selected transactions',
              onTap: () {
                Navigator.pop(ctx);
                _showBulkAssignDialog();
              },
            ),
            const SizedBox(height: 12),
            _buildBulkActionTile(
              icon: Icons.account_balance_rounded,
              iconColor: AppColors.accent,
              label: 'Change Bank…',
              subtitle: 'Move selected transactions to a different bank',
              onTap: () {
                Navigator.pop(ctx);
                _showBulkUpdateDialog();
              },
            ),
            const SizedBox(height: 12),
            _buildBulkActionTile(
              icon: Icons.delete_outline_rounded,
              iconColor: Colors.redAccent,
              label: 'Delete Selected',
              subtitle: 'Permanently remove selected transactions',
              onTap: () {
                Navigator.pop(ctx);
                _showBulkDeleteDialog();
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() => _selectedTxIds.clear());
                },
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Cancel Selection'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBulkActionTile({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    )),
                  const SizedBox(height: 2),
                  Text(subtitle,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    )),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }

  // ─── Bulk Assign Dialog ───────────────────────────────────────────────────
  void _showBulkAssignDialog() {
    String selectedAssignee = 'Me';
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text('Assign ${_selectedTxIds.length} Transactions',
              style: const TextStyle(color: AppColors.textPrimary)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Assign selected transactions to:',
                  style: TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 16),
                _buildDropdown(
                  value: selectedAssignee,
                  items: const ['Me', 'Mom', 'Dad', 'Unassigned'],
                  onChanged: (val) => setDialogState(() => selectedAssignee = val!),
                  icon: Icons.person_outline,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textSecondary)),
              ),
              ElevatedButton(
                onPressed: () async {
                  await _localDbService.bulkUpdateAssignedTo(
                    _selectedTxIds, selectedAssignee);
                  await _loadTransactions();
                  setState(() => _selectedTxIds.clear());
                  if (mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Bulk assign successful!'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                child: const Text('Assign',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showBulkUpdateDialog() {
    String selectedBank = 'SBI';
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text('Bulk Update Bank (${_selectedTxIds.length})', style: const TextStyle(color: AppColors.textPrimary)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Move selected transactions to:', style: TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 16),
                _buildDropdown(
                  value: selectedBank,
                  items: ['SBI', 'BoB', 'Cash', 'Other'],
                  onChanged: (val) => setDialogState(() => selectedBank = val!),
                  icon: Icons.account_balance,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
              ),
              ElevatedButton(
                onPressed: () async {
                  await _localDbService.bulkUpdateBank(_selectedTxIds, selectedBank);
                  await _loadTransactions(); // Refresh UI
                  setState(() {
                    _selectedTxIds.clear();
                  });
                  if (mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Bulk update successful!'), backgroundColor: Colors.green),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                child: const Text('Save', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        }
      ),
    );
  }

  void _showBulkDeleteDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Delete ${_selectedTxIds.length} Transactions?', style: const TextStyle(color: AppColors.textPrimary)),
        content: const Text('Are you sure you want to permanently delete all selected transactions?', 
          style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () async {
              await _localDbService.bulkDeleteTransactions(_selectedTxIds);
              await _loadTransactions(); // Refresh UI
              setState(() {
                _selectedTxIds.clear();
              });
              if (mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Bulk deletion successful!'), backgroundColor: Colors.green),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete All', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

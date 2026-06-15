import 'package:flutter/material.dart';
import '../models/transaction_model.dart';
import '../services/categorization_service.dart';
import '../services/local_db_service.dart';
import '../theme/app_colors.dart';

class CategorizationRulesScreen extends StatefulWidget {
  const CategorizationRulesScreen({super.key});

  @override
  State<CategorizationRulesScreen> createState() => _CategorizationRulesScreenState();
}

class _CategorizationRulesScreenState extends State<CategorizationRulesScreen> {
  final LocalDbService _db = LocalDbService();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Auto-Categorization Rules',
            style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          Expanded(
            child: StreamBuilder<List<CategorizationRule>>(
              stream: _db.categorizationRulesStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator(color: AppColors.accent));
                }
                final rules = (snapshot.data ?? []).where((r) {
                  if (_searchQuery.isEmpty) return true;
                  final q = _searchQuery.toUpperCase();
                  return r.keyword.contains(q) ||
                      (r.category?.toUpperCase().contains(q) ?? false) ||
                      (r.assignedTo?.toUpperCase().contains(q) ?? false);
                }).toList();

                if (rules.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.rule_outlined,
                            color: AppColors.textSecondary.withOpacity(0.4), size: 56),
                        const SizedBox(height: 16),
                        Text(
                          _searchQuery.isEmpty ? 'No rules yet' : 'No matching rules',
                          style: const TextStyle(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  );
                }

                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Row(
                        children: [
                          Icon(Icons.swipe_left_outlined, size: 14, color: AppColors.textSecondary.withOpacity(0.45)),
                          const SizedBox(width: 6),
                          Text('Swipe left to delete a rule',
                            style: TextStyle(color: AppColors.textSecondary.withOpacity(0.45), fontSize: 11)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                        physics: const BouncingScrollPhysics(),
                        itemCount: rules.length,
                        itemBuilder: (context, index) => _buildRuleTile(rules[index]),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showRuleEditor(context),
        backgroundColor: AppColors.accent,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Add Rule', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(color: AppColors.textPrimary),
        onChanged: (v) => setState(() => _searchQuery = v),
        decoration: InputDecoration(
          hintText: 'Search rules...',
          hintStyle: const TextStyle(color: AppColors.textSecondary),
          prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: AppColors.textSecondary),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          filled: true,
          fillColor: AppColors.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildRuleTile(CategorizationRule rule) {
    return Dismissible(
      key: ValueKey(rule.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.15),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.redAccent),
      ),
      confirmDismiss: (_) => _confirmDelete(rule),
      onDismissed: (_) => _db.deleteCategorizationRule(rule.id!),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          onTap: () => _showRuleEditor(context, rule: rule),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.label_outline, color: AppColors.accent, size: 20),
          ),
          title: Text(
            rule.keyword,
            style: const TextStyle(
                color: AppColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 15),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (rule.category != null) _buildTag(rule.category!, Colors.blue),
                if (rule.assignedTo != null) _buildTag(rule.assignedTo!, Colors.purple),
                if (rule.bankName != null) _buildTag(rule.bankName!, Colors.orange),
              ],
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('P${rule.priority}',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: AppColors.textSecondary, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTag(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  Future<bool> _confirmDelete(CategorizationRule rule) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text('Delete Rule?',
                style: TextStyle(color: AppColors.textPrimary)),
            content: Text('Remove the rule for "${rule.keyword}"?',
                style: const TextStyle(color: AppColors.textSecondary)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel',
                      style: TextStyle(color: AppColors.textSecondary))),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Delete',
                      style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
            ],
          ),
        ) ??
        false;
  }

  void _showRuleEditor(BuildContext context, {CategorizationRule? rule}) {
    final isNew = rule == null;
    final keywordController = TextEditingController(text: rule?.keyword ?? '');

    String? selectedCategory = rule?.category;
    String? selectedAssignedTo = rule?.assignedTo;
    String? selectedBankName = rule?.bankName;
    int priority = rule?.priority ?? 100;

    final priorityController =
        TextEditingController(text: priority.toString());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Container(
          decoration: const BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          ),
          padding: EdgeInsets.only(
            top: 12,
            left: 24,
            right: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 32,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  isNew ? 'New Rule' : 'Edit Rule',
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Keyword is matched against the raw SMS/statement text (case-insensitive).',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 24),

                // Keyword
                _buildFieldLabel('KEYWORD'),
                TextField(
                  controller: keywordController,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16),
                  decoration: _inputDecoration('e.g. BLINKIT'),
                ),
                const SizedBox(height: 16),

                // Category
                _buildFieldLabel('SET CATEGORY'),
                _buildNullableDropdown(
                  value: selectedCategory,
                  items: TransactionModel.availableCategories,
                  onChanged: (v) => setSheetState(() => selectedCategory = v),
                  hint: '— no change —',
                ),
                const SizedBox(height: 16),

                // Assigned To
                _buildFieldLabel('SET ASSIGNED TO'),
                _buildNullableDropdown(
                  value: selectedAssignedTo,
                  items: const ['Me', 'Mom', 'Dad', 'Unassigned'],
                  onChanged: (v) => setSheetState(() => selectedAssignedTo = v),
                  hint: '— no change —',
                ),
                const SizedBox(height: 16),

                // Bank
                _buildFieldLabel('SET BANK'),
                _buildNullableDropdown(
                  value: selectedBankName,
                  items: const ['SBI', 'BoB', 'Cash', 'Other'],
                  onChanged: (v) => setSheetState(() => selectedBankName = v),
                  hint: '— no change —',
                ),
                const SizedBox(height: 16),

                // Priority
                _buildFieldLabel('PRIORITY (lower = applied first)'),
                TextField(
                  controller: priorityController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: _inputDecoration('10–100'),
                  onChanged: (v) => priority = int.tryParse(v) ?? 100,
                ),
                const SizedBox(height: 32),

                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: () async {
                      final keyword = keywordController.text.trim().toUpperCase();
                      if (keyword.isEmpty) return;

                      final updated = CategorizationRule(
                        id: rule?.id,
                        keyword: keyword,
                        category: selectedCategory,
                        assignedTo: selectedAssignedTo,
                        bankName: selectedBankName,
                        priority: int.tryParse(priorityController.text) ?? 100,
                      );

                      if (isNew) {
                        await _db.insertCategorizationRule(updated);
                      } else {
                        await _db.updateCategorizationRule(updated);
                      }

                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: Text(
                      isNew ? 'Add Rule' : 'Save Changes',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFieldLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label,
        style: TextStyle(
            color: AppColors.textSecondary.withOpacity(0.6),
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textSecondary),
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  Widget _buildNullableDropdown({
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    required String hint,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: AppColors.surface,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.accent),
          hint: Text(hint,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          style: const TextStyle(
              color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
          items: [
            DropdownMenuItem<String>(
              value: null,
              child: Text(hint,
                  style: const TextStyle(color: AppColors.textSecondary)),
            ),
            ...items.map((s) => DropdownMenuItem(value: s, child: Text(s))),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'screens/dashboard_screen.dart';
import 'screens/transactions_screen.dart';
import 'screens/analytics_screen.dart';
import 'screens/add_transaction_screen.dart';
import 'models/txn_filter_request.dart';
import 'services/native_sms_queue.dart';
import 'services/transaction_import_service.dart';
import 'theme/app_colors.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Family Expense Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  final NativeSmsQueue _smsQueue = NativeSmsQueue();
  late final TransactionImportService _importer =
      TransactionImportService(nativeQueue: _smsQueue);
  StreamSubscription<int>? _captureSubscription;

  /// Amounts start hidden on every launch, the way a banking app does, and the
  /// reveal lasts only for this session. It lives here rather than in the
  /// dashboard's own state because switching tabs rebuilds that state — the
  /// reveal has to survive a trip to Analytics and back, but not a relaunch.
  final ValueNotifier<bool> _amountsHidden = ValueNotifier<bool>(true);

  /// The filters Analytics last handed off. Held here because the handoff
  /// crosses tabs: Analytics decides what is worth looking at, Transactions
  /// shows the rows.
  TxnFilterRequest? _txnFilter;

  List<Widget> _buildScreens() => [
        DashboardScreen(amountsHidden: _amountsHidden),
        TransactionsScreen(
          // A new request must rebuild the screen from scratch so its initial
          // filters are picked up; without the key it would keep the state it
          // already had and silently ignore the handoff.
          key: ValueKey(_txnFilter),
          initialFilter: _txnFilter?.person,
          initialMonth: _txnFilter?.monthLabel,
          initialCategory: _txnFilter?.category,
        ),
        const AddTransactionScreen(),
        AnalyticsScreen(onViewTransactions: _openTransactions),
      ];

  void _openTransactions(TxnFilterRequest request) {
    setState(() {
      _txnFilter = request;
      _currentIndex = 1;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // The Android receiver captures SMS whether or not the app is running.
    // When it is running, this turns capture into an immediate import.
    _smsQueue.startListening();
    _captureSubscription = _smsQueue.onCaptured.listen((_) => _drainCaptured());

    _autoSync();
  }

  @override
  void dispose() {
    _captureSubscription?.cancel();
    _smsQueue.dispose();
    _amountsHidden.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Messages captured while the app was backgrounded are waiting in the
    // native queue; drain them the moment the user comes back.
    if (state == AppLifecycleState.resumed) _autoSync();
  }

  Future<void> _drainCaptured() async {
    final report = await _importer.drainNativeQueue();
    _announce(report, live: true);
  }

  Future<void> _autoSync() async {
    // Silent and rate-limited: it never prompts for permission and never
    // repeats a scan that just ran. Because imports are idempotent, running it
    // more often than necessary is harmless — it simply finds nothing new.
    final report = await _importer.syncIfDue();
    _announce(report, live: false);
  }

  void _announce(ImportReport? report, {required bool live}) {
    if (!mounted || report == null || report.imported == 0) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(live
            ? '${report.imported} new transaction(s) detected from SMS'
            : '${report.imported} transaction(s) imported automatically from SMS'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildScreens()[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            // Tapping the tab directly means "show me everything" — a filter
            // from a drill-down should not outlive the trip that set it.
            if (index == 1) _txnFilter = null;
            _currentIndex = index;
          });
        },
        backgroundColor: AppColors.surface,
        selectedItemColor: AppColors.accent,
        unselectedItemColor: AppColors.textSecondary,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.list_alt),
            label: 'Transactions',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.add_box),
            label: 'Add',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.pie_chart),
            label: 'Analytics',
          ),
        ],
      ),
    );
  }
}

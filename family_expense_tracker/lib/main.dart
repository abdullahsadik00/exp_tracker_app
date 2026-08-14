import 'dart:async';

import 'package:flutter/material.dart';
import 'screens/dashboard_screen.dart';
import 'screens/transactions_screen.dart';
import 'screens/analytics_screen.dart';
import 'screens/add_transaction_screen.dart';
import 'services/native_sms_queue.dart';
import 'services/transaction_import_service.dart';
import 'theme/app_colors.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  debugPrint('---------------------------------------------------------');
  debugPrint('NOTICE: Offline SQLite Database Initialized.');
  debugPrint('---------------------------------------------------------');
  
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

  final List<Widget> _screens = const [
    DashboardScreen(),
    TransactionsScreen(),
    AddTransactionScreen(),
    AnalyticsScreen(),
  ];

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
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
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




class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text('Settings Screen')),
    );
  }
}

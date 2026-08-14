import 'dart:async';
import 'dart:convert';

import '../models/transaction_model.dart';
import '../utils/stable_hash.dart';
import 'categorization_service.dart';
import 'local_db_service.dart';
import 'native_sms_queue.dart';
import 'sms_parser.dart';
import 'sms_reader.dart';
import 'sms_service.dart';
import 'transaction_fingerprint.dart';

class ImportProgress {
  final String phase;
  final int processed;
  final int total;

  const ImportProgress(this.phase, this.processed, this.total);

  double get fraction => total == 0 ? 0 : processed / total;
}

/// What one synchronisation run did. Every message read is accounted for in
/// exactly one of the counters, so the totals always add up on screen.
class ImportReport {
  final int scanned;
  final int imported;
  final int duplicates;
  final int suppressedByDelete;
  final int unparsed;
  final int ignored;
  final int failedTransactions;
  final int flaggedForReview;
  final int pendingUpgraded;
  final Map<String, int> ignoreReasons;
  final DateTime finishedAt;
  final Duration elapsed;
  final String? error;
  final bool permissionDenied;

  const ImportReport({
    this.scanned = 0,
    this.imported = 0,
    this.duplicates = 0,
    this.suppressedByDelete = 0,
    this.unparsed = 0,
    this.ignored = 0,
    this.failedTransactions = 0,
    this.flaggedForReview = 0,
    this.pendingUpgraded = 0,
    this.ignoreReasons = const {},
    required this.finishedAt,
    this.elapsed = Duration.zero,
    this.error,
    this.permissionDenied = false,
  });

  Map<String, dynamic> toJson() => {
        'scanned': scanned,
        'imported': imported,
        'duplicates': duplicates,
        'suppressedByDelete': suppressedByDelete,
        'unparsed': unparsed,
        'ignored': ignored,
        'failedTransactions': failedTransactions,
        'flaggedForReview': flaggedForReview,
        'pendingUpgraded': pendingUpgraded,
        'ignoreReasons': ignoreReasons,
        'finishedAt': finishedAt.toIso8601String(),
        'elapsedMs': elapsed.inMilliseconds,
        'error': error,
        'permissionDenied': permissionDenied,
      };

  static ImportReport? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return ImportReport(
        scanned: (m['scanned'] as num?)?.toInt() ?? 0,
        imported: (m['imported'] as num?)?.toInt() ?? 0,
        duplicates: (m['duplicates'] as num?)?.toInt() ?? 0,
        suppressedByDelete: (m['suppressedByDelete'] as num?)?.toInt() ?? 0,
        unparsed: (m['unparsed'] as num?)?.toInt() ?? 0,
        ignored: (m['ignored'] as num?)?.toInt() ?? 0,
        failedTransactions: (m['failedTransactions'] as num?)?.toInt() ?? 0,
        flaggedForReview: (m['flaggedForReview'] as num?)?.toInt() ?? 0,
        pendingUpgraded: (m['pendingUpgraded'] as num?)?.toInt() ?? 0,
        ignoreReasons: Map<String, int>.from(
            (m['ignoreReasons'] as Map?)?.cast<String, int>() ?? const {}),
        finishedAt:
            DateTime.tryParse((m['finishedAt'] ?? '').toString()) ?? DateTime.now(),
        elapsed: Duration(milliseconds: (m['elapsedMs'] as num?)?.toInt() ?? 0),
        error: m['error'] as String?,
        permissionDenied: m['permissionDenied'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Turns inbox messages into transactions, exactly once each.
///
/// The safety properties this class is responsible for:
///
/// * **Idempotent** — identity comes from [TransactionFingerprint] and is
///   enforced by a unique index, so running a sync twice, or scanning the whole
///   inbox after already scanning part of it, adds nothing the second time.
/// * **Crash-safe** — all inserts for a run go through one SQLite transaction.
///   An interrupted sync leaves the ledger untouched and simply re-runs.
/// * **Non-destructive** — manual transactions are never edited or deleted by
///   the importer, and a transaction the user deleted stays deleted.
/// * **Serialised** — a second sync started while one is running joins the one
///   in flight instead of racing it.
class TransactionImportService {
  TransactionImportService({
    LocalDbService? db,
    SmsReader? reader,
    SmsParser parser = const SmsParser(),
    NativeSmsQueue? nativeQueue,
  })  : _db = db ?? LocalDbService.instance,
        _reader = reader ?? InboxSmsReader(),
        _parser = parser,
        _nativeQueue = nativeQueue ?? NativeSmsQueue();

  final LocalDbService _db;
  final SmsReader _reader;
  final SmsParser _parser;
  final NativeSmsQueue _nativeQueue;

  static Future<ImportReport>? _inFlight;

  /// True while a sync is running anywhere in the app.
  static bool get isSyncing => _inFlight != null;

  /// Scans the inbox and imports every transaction it can identify.
  ///
  /// Safe to call repeatedly and safe to interrupt.
  Future<ImportReport> sync({
    int maxMessages = 2000,
    void Function(ImportProgress)? onProgress,
  }) {
    // Joining the in-flight run rather than starting a second one keeps the
    // "check then insert" sequences from interleaving.
    final running = _inFlight;
    if (running != null) return running;

    final future = _run(maxMessages: maxMessages, onProgress: onProgress);
    _inFlight = future;
    return future.whenComplete(() {
      _inFlight = null;
    });
  }

  /// Imports whatever the Android broadcast receiver captured while the app was
  /// closed or in the background.
  ///
  /// Ordering matters and is deliberate: the messages are imported and
  /// committed **first**, and only then acknowledged and removed from the
  /// native queue. Crashing in between means they are imported a second time on
  /// the next drain, which the fingerprint index turns into a no-op —
  /// acknowledging first would instead lose the transaction permanently.
  ///
  /// Returns null when there was nothing queued or the platform has no
  /// receiver.
  Future<ImportReport?> drainNativeQueue() async {
    if (!_nativeQueue.isSupported) return null;

    // Sharing the sync lock keeps a drain from interleaving with a full inbox
    // scan, which would let the same message be checked-then-inserted twice.
    if (isSyncing) return null;

    final completer = Completer<ImportReport>();
    _inFlight = completer.future;

    try {
      final queued = await _nativeQueue.pending();
      if (queued.isEmpty) {
        completer.complete(ImportReport(finishedAt: DateTime.now()));
        return null;
      }

      final report =
          await importMessages(queued.map((q) => q.message).toList());

      // Committed — safe to drop them from the queue now.
      await _nativeQueue.acknowledge(queued.map((q) => q.id).toList());

      await _db.setSyncState(
          LocalDbService.kLastSmsCaptureAt, DateTime.now().toIso8601String());

      completer.complete(report);
      return report;
    } catch (e) {
      final failure = ImportReport(
        finishedAt: DateTime.now(),
        error: e.toString(),
      );
      // Nothing is acknowledged on failure, so the messages stay queued and
      // are retried on the next drain.
      completer.complete(failure);
      return failure;
    } finally {
      _inFlight = null;
    }
  }

  /// Syncs without ever showing a permission dialog, and only if enough time
  /// has passed since the last run.
  ///
  /// Called when the app starts and each time it returns to the foreground, so
  /// new transaction SMS are picked up on their own. Silent by design: an
  /// automatic background action must not interrupt the user with a system
  /// prompt, and it must not repeat work that was just done.
  Future<ImportReport?> syncIfDue({
    Duration minInterval = const Duration(minutes: 2),
    int maxMessages = 500,
  }) async {
    if (isSyncing) return null;
    if (!await _ensurePermissionOnce()) return null;

    // Always drain first: it is cheap, covers everything that arrived while the
    // app was closed, and is not rate-limited because it only ever touches
    // messages that have not been imported yet.
    final drained = await drainNativeQueue();

    final last = await _db.lastSmsSyncAt();
    if (last != null && DateTime.now().difference(last) < minInterval) {
      return drained;
    }

    // The full inbox scan still runs periodically. It is the backstop for
    // anything the receiver missed — messages that arrived while the
    // permission was off, or that the native pre-filter rejected.
    final scanned = await sync(maxMessages: maxMessages);
    return _merge(drained, scanned);
  }

  /// Grants the automatic path access without nagging.
  ///
  /// RECEIVE_SMS is a runtime permission, so the broadcast receiver stays inert
  /// until it is granted — and an existing user who only ever granted READ_SMS
  /// does not have it. Since both live in the same permission group, requesting
  /// it is granted silently for those users, and this asks exactly once so a
  /// user who genuinely says no is never prompted again on launch.
  Future<bool> _ensurePermissionOnce() async {
    if (await _reader.hasPermission()) return true;

    final alreadyAsked =
        await _db.getSyncState(LocalDbService.kSmsPermissionPrompted);
    if (alreadyAsked != null) return false;

    await _db.setSyncState(
        LocalDbService.kSmsPermissionPrompted, DateTime.now().toIso8601String());
    return _reader.ensurePermission();
  }

  static ImportReport _merge(ImportReport? a, ImportReport? b) {
    if (a == null) return b ?? ImportReport(finishedAt: DateTime.now());
    if (b == null) return a;
    return ImportReport(
      scanned: a.scanned + b.scanned,
      imported: a.imported + b.imported,
      duplicates: a.duplicates + b.duplicates,
      suppressedByDelete: a.suppressedByDelete + b.suppressedByDelete,
      unparsed: a.unparsed + b.unparsed,
      ignored: a.ignored + b.ignored,
      failedTransactions: a.failedTransactions + b.failedTransactions,
      flaggedForReview: a.flaggedForReview + b.flaggedForReview,
      pendingUpgraded: a.pendingUpgraded + b.pendingUpgraded,
      ignoreReasons: {
        for (final key in {...a.ignoreReasons.keys, ...b.ignoreReasons.keys})
          key: (a.ignoreReasons[key] ?? 0) + (b.ignoreReasons[key] ?? 0)
      },
      finishedAt: b.finishedAt,
      elapsed: a.elapsed + b.elapsed,
      error: a.error ?? b.error,
      permissionDenied: a.permissionDenied || b.permissionDenied,
    );
  }

  Future<ImportReport> _run({
    required int maxMessages,
    void Function(ImportProgress)? onProgress,
  }) async {
    final started = DateTime.now();

    try {
      final granted = await _reader.ensurePermission();
      if (!granted) {
        return ImportReport(
          finishedAt: DateTime.now(),
          elapsed: DateTime.now().difference(started),
          permissionDenied: true,
          error: 'SMS permission was not granted.',
        );
      }

      onProgress?.call(const ImportProgress('Reading inbox', 0, 0));
      final messages = await _reader.read(count: maxMessages);

      final report = await importMessages(messages, onProgress: onProgress);

      await _db.setSyncState(
          LocalDbService.kLastSmsSyncAt, DateTime.now().toIso8601String());
      await _db.setSyncState(
          LocalDbService.kLastSmsSyncReport, jsonEncode(report.toJson()));

      return report;
    } catch (e) {
      return ImportReport(
        finishedAt: DateTime.now(),
        elapsed: DateTime.now().difference(started),
        error: e.toString(),
      );
    }
  }

  /// The pure half of the import: takes messages, writes transactions.
  /// Exposed separately so tests can drive it without a device inbox.
  Future<ImportReport> importMessages(
    List<RawSms> messages, {
    void Function(ImportProgress)? onProgress,
  }) async {
    final started = DateTime.now();

    final rules = await _db.getCategorizationRules();
    final categorizer = CategorizationService(rules);

    final candidates = <TransactionModel>[];
    final logEntries = <Map<String, dynamic>>[];
    final ignoreReasons = <String, int>{};

    int unparsed = 0;
    int ignored = 0;
    int failedTxns = 0;

    for (var i = 0; i < messages.length; i++) {
      if (i % 50 == 0) {
        onProgress?.call(ImportProgress('Parsing', i, messages.length));
      }

      final msg = messages[i];
      final smsHash = stableHash(
          '${msg.sender ?? ''}|${normalizeForHash(msg.body)}|'
          '${msg.receivedAt.millisecondsSinceEpoch}');

      final parsed = _parser.parse(
        body: msg.body,
        sender: msg.sender,
        receivedAt: msg.receivedAt,
      );

      if (!parsed.isTransaction) {
        final reason = parsed.rejectReason ?? SmsRejectReason.notFinancial;
        ignoreReasons[reason] = (ignoreReasons[reason] ?? 0) + 1;

        // A message that plainly came from a bank but could not be read is a
        // parser gap, not noise — those get surfaced to the user. Everything
        // else (OTPs, promos) is simply not financial.
        final looksFinancial = _looksFinancial(msg.body) &&
            (reason == SmsRejectReason.noAmount ||
                reason == SmsRejectReason.noDirection);
        if (looksFinancial) {
          unparsed++;
        } else {
          ignored++;
        }

        logEntries.add({
          'sms_hash': smsHash,
          'sender': msg.sender,
          'body': msg.body,
          'received_at': msg.receivedAt.toIso8601String(),
          'outcome': looksFinancial ? 'unparsed' : 'ignored',
          'reason': reason,
          'txn_id': null,
        });
        continue;
      }

      final tx = _toTransaction(parsed, msg, categorizer);
      if (parsed.status == TxnStatus.failed) failedTxns++;
      candidates.add(tx);

      logEntries.add({
        'sms_hash': smsHash,
        'sender': msg.sender,
        'body': msg.body,
        'received_at': msg.receivedAt.toIso8601String(),
        // Provisional; corrected below once we know whether it was inserted.
        'outcome': 'parsed',
        'reason': parsed.reviewReason,
        'txn_id': tx.id,
      });
    }

    onProgress?.call(
        ImportProgress('Checking for duplicates', messages.length, messages.length));

    final prepared = await _resolveAgainstExisting(candidates);

    onProgress?.call(
        ImportProgress('Saving', messages.length, messages.length));

    final result = await _db.insertTransactionsDetailed(prepared.toInsert);

    // Now that outcomes are known, correct the log for the parsed messages.
    final insertedIds = <String>{};
    for (final tx in prepared.toInsert) {
      insertedIds.add(tx.id);
    }
    for (final entry in logEntries) {
      if (entry['outcome'] != 'parsed') continue;
      entry['outcome'] =
          insertedIds.contains(entry['txn_id']) ? 'imported' : 'duplicate';
    }
    await _db.writeImportLog(logEntries);

    return ImportReport(
      scanned: messages.length,
      imported: result.added,
      // Duplicates caught up-front plus those the unique index rejected.
      duplicates: prepared.knownDuplicates + result.duplicates,
      suppressedByDelete: prepared.suppressed + result.suppressedByTombstone,
      unparsed: unparsed,
      ignored: ignored,
      failedTransactions: failedTxns,
      flaggedForReview: prepared.toInsert.where((t) => t.needsReview).length,
      pendingUpgraded: prepared.pendingUpgraded,
      ignoreReasons: ignoreReasons,
      finishedAt: DateTime.now(),
      elapsed: DateTime.now().difference(started),
    );
  }

  /// Bank-shaped wording that should have yielded a transaction. Used only to
  /// decide whether a rejection is worth showing the user.
  static final RegExp _financialHint = RegExp(
      r'\bdebited\b|\bcredited\b|\bwithdrawn\b|\bdeposited\b|\bupi\b|'
      r'\ba\/c\b|\btxn\b|\btransaction\b',
      caseSensitive: false);

  static bool _looksFinancial(String body) => _financialHint.hasMatch(body);

  TransactionModel _toTransaction(
    ParsedSms parsed,
    RawSms msg,
    CategorizationService categorizer,
  ) {
    final analysis = categorizer.analyzeTransaction(msg.body, parsed.type!);

    // The parser's bank comes from the sender id and is more reliable than a
    // keyword rule; the rules stay as the fallback so existing user
    // configuration keeps working.
    final bank = parsed.bank ?? analysis['bankName']!;
    final description = parsed.merchant ?? analysis['description']!;

    final fingerprint = TransactionFingerprint.build(
      bank: bank,
      type: parsed.type!,
      amountPaise: parsed.amountPaise!,
      dateTime: parsed.dateTime,
      accountTail: parsed.accountTail,
      referenceId: parsed.referenceId,
      upiTransactionId: parsed.upiTransactionId,
      rawText: msg.body,
      description: description,
    );

    return TransactionModel(
      // Derived from the fingerprint so the id is stable across re-imports too.
      id: 'sms_${stableHash(fingerprint)}',
      amountPaise: parsed.amountPaise!,
      type: parsed.type!,
      bankName: bank,
      assignedTo: analysis['assignedTo']!,
      category: analysis['category']!,
      description: description,
      date: parsed.dateTime,
      rawSmsText: msg.body,
      source: TxnSource.sms,
      fingerprint: fingerprint,
      merchant: parsed.merchant,
      referenceId: parsed.referenceId,
      upiTransactionId: parsed.upiTransactionId,
      accountTail: parsed.accountTail,
      smsSender: msg.sender,
      status: parsed.status,
      txnKind: parsed.kind,
      needsReview: parsed.needsReview,
      reviewReason: parsed.reviewReason,
      smsBalancePaise: parsed.balancePaise,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  Future<_PreparedBatch> _resolveAgainstExisting(
      List<TransactionModel> candidates) async {
    final toInsert = <TransactionModel>[];
    final seenInBatch = <String>{};
    int knownDuplicates = 0;
    int suppressed = 0;
    int pendingUpgraded = 0;

    for (final candidate in candidates) {
      final fp = candidate.fingerprint!;

      // The same message can appear twice in one read (carrier redelivery).
      if (!seenInBatch.add(fp)) {
        knownDuplicates++;
        continue;
      }

      final existing = await _db.findByFingerprint(fp);
      if (existing != null) {
        // A pending authorisation that has now settled: update in place rather
        // than adding a second row for the same money.
        if (existing.status == TxnStatus.pending &&
            candidate.status == TxnStatus.posted) {
          await _db.setTransactionStatus(existing.id, TxnStatus.posted);
          pendingUpgraded++;
        }
        knownDuplicates++;
        continue;
      }

      // Near-matches are flagged, never dropped: two ₹50 fares minutes apart
      // are two real transactions, and silently discarding one would corrupt
      // the balance in the direction that is hardest to notice.
      //
      // Both the stored rows and the rest of this batch have to be checked. On
      // the first-ever sync the whole inbox arrives at once and nothing is
      // stored yet, so a database-only check would find nothing.
      final soft = await _db.findSoftDuplicates(candidate);
      final softInBatch = toInsert.where((t) => _looksLikeSame(t, candidate));

      if (soft.isNotEmpty || softInBatch.isNotEmpty) {
        toInsert.add(candidate.copyWith(
          needsReview: true,
          reviewReason: 'Looks like a possible duplicate of another '
              '${candidate.type} of the same amount around the same time.',
        ));
        continue;
      }

      toInsert.add(candidate);
    }

    return _PreparedBatch(
      toInsert: toInsert,
      knownDuplicates: knownDuplicates,
      suppressed: suppressed,
      pendingUpgraded: pendingUpgraded,
    );
  }

  /// Same account, direction and amount within a few minutes — suspicious
  /// enough to flag, not conclusive enough to merge.
  static bool _looksLikeSame(TransactionModel a, TransactionModel b) {
    return a.amountPaise == b.amountPaise &&
        a.type == b.type &&
        a.bankName == b.bankName &&
        a.date.difference(b.date).abs() <= const Duration(minutes: 5);
  }

  /// The report from the most recent completed sync, if any.
  Future<ImportReport?> lastReport() async =>
      ImportReport.fromJsonString(
          await _db.getSyncState(LocalDbService.kLastSmsSyncReport));
}

class _PreparedBatch {
  final List<TransactionModel> toInsert;
  final int knownDuplicates;
  final int suppressed;
  final int pendingUpgraded;

  const _PreparedBatch({
    required this.toInsert,
    required this.knownDuplicates,
    required this.suppressed,
    required this.pendingUpgraded,
  });
}

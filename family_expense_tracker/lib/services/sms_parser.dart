import '../models/transaction_model.dart';
import '../utils/money.dart';

/// Why a message was not turned into a transaction. Surfaced in the import
/// report so "nothing was imported" is always explainable.
class SmsRejectReason {
  static const String notFinancial = 'not_financial';
  static const String otp = 'otp';
  static const String promotional = 'promotional';
  static const String paymentRequest = 'payment_request';
  static const String futureOrMandate = 'future_or_mandate';
  static const String balanceEnquiry = 'balance_enquiry';
  static const String noAmount = 'no_amount';
  static const String noDirection = 'no_direction';
}

/// The outcome of parsing one SMS. Immutable and free of any plugin or
/// database dependency so the whole parser can be exercised in plain unit
/// tests.
class ParsedSms {
  final bool isTransaction;
  final String? rejectReason;

  /// 'credit' or 'debit', matching [TransactionModel.type].
  final String? type;

  final int? amountPaise;

  /// Transaction time. Taken from the message body when the body states one,
  /// otherwise the time the SMS was received.
  final DateTime dateTime;
  final bool dateFromBody;

  final String? merchant;
  final String? bank;
  final String? accountTail;
  final String? referenceId;
  final String? upiTransactionId;

  /// Bank-reported available balance found in the message, in paise.
  final int? balancePaise;

  final String status; // TxnStatus.*
  final String kind; // TxnKind.*

  final bool needsReview;
  final String? reviewReason;

  /// Extra transaction-looking amounts found beyond the primary one. Non-zero
  /// means the message probably describes more than one movement.
  final int extraAmountCount;

  const ParsedSms({
    required this.isTransaction,
    required this.dateTime,
    this.rejectReason,
    this.type,
    this.amountPaise,
    this.dateFromBody = false,
    this.merchant,
    this.bank,
    this.accountTail,
    this.referenceId,
    this.upiTransactionId,
    this.balancePaise,
    this.status = TxnStatus.posted,
    this.kind = TxnKind.normal,
    this.needsReview = false,
    this.reviewReason,
    this.extraAmountCount = 0,
  });

  factory ParsedSms.rejected(String reason, DateTime receivedAt) =>
      ParsedSms(isTransaction: false, rejectReason: reason, dateTime: receivedAt);
}

class _Span {
  final int start;
  final int end;
  final String text;
  const _Span(this.start, this.end, this.text);
}

/// Parses Indian bank / wallet / card transaction SMS into structured data.
///
/// The parser is deliberately conservative: when it cannot work something out
/// it says so (via [ParsedSms.needsReview] or a reject reason) rather than
/// guessing, because a wrong amount silently corrupts the balance forever
/// while a flagged row only costs the user one tap.
class SmsParser {
  const SmsParser();

  // ─── Vocabulary ────────────────────────────────────────────────────────────

  static final RegExp _otp = RegExp(
      r'\botp\b|one[\s-]?time\s?password|verification code|do not share|'
      r'\bnever share\b',
      caseSensitive: false);

  static final RegExp _promotional = RegExp(
      r'pre[\s-]?approved|apply now|avail (?:a |an )?loan|loan offer|'
      r'interest rate|%\s*p\.?a\.?|limited period|hurry|t&c apply|'
      r'download the app|refer and earn|lucky draw|exciting offer|'
      r'get up to|save up to|flat \d+% ?off',
      caseSensitive: false);

  static final RegExp _paymentRequest = RegExp(
      r'has requested|is requesting|collect request|payment request|'
      r'requesting money|to pay, click|approve the request',
      caseSensitive: false);

  /// Announcements about money that has not moved yet. Importing these would
  /// double-count once the real alert arrives.
  static final RegExp _future = RegExp(
      r'will be (?:debited|credited|deducted|charged)|'
      r'is due (?:on|by)|due date|shall be debited|'
      r'e-?mandate|auto\s?pay (?:is )?(?:set|scheduled)|standing instruction',
      caseSensitive: false);

  static final RegExp _failure = RegExp(
      r'\bfail(?:ed|ure)?\b|\bdeclin(?:e|ed)\b|unsuccessful|'
      r'could not be (?:processed|completed)|not processed|\brejected\b|'
      r'insufficient (?:balance|funds)|timed out|\bcancelled\b',
      caseSensitive: false);

  static final RegExp _pending = RegExp(
      r'\bpending\b|under process|being processed|\binitiated\b|awaiting',
      caseSensitive: false);

  static const List<String> _creditVerbs = [
    'credited', 'credit', 'deposited', 'received', 'refunded', 'refund',
    'reversed', 'reversal', 'cashback', 'added to',
  ];

  static const List<String> _debitVerbs = [
    'debited', 'debit', 'withdrawn', 'withdrawal', 'spent', 'paid',
    'sent', 'purchase', 'charged', 'deducted', 'transferred',
  ];

  /// Sender-id fragment -> canonical bank name. Longest fragment wins, so
  /// 'BARODA' is tested before 'BOB'.
  static const Map<String, String> _bankBySignature = {
    'SBIINB': 'SBI', 'SBIUPI': 'SBI', 'SBIPSG': 'SBI', 'SBICRD': 'SBI',
    'ATMSBI': 'SBI', 'SBIBNK': 'SBI', 'SBI': 'SBI',
    'BARODA': 'BoB', 'BOBSMS': 'BoB', 'BOBTXN': 'BoB', 'BOBIBK': 'BoB',
    'BARB': 'BoB', 'BOB': 'BoB',
    'HDFCBK': 'HDFC', 'HDFCBN': 'HDFC', 'HDFC': 'HDFC',
    'ICICIB': 'ICICI', 'ICICIT': 'ICICI', 'ICICI': 'ICICI',
    'AXISBK': 'Axis', 'AXISB': 'Axis', 'AXIS': 'Axis',
    'KOTAKB': 'Kotak', 'KOTAK': 'Kotak', 'KMBL': 'Kotak',
    'PNBSMS': 'PNB', 'PNB': 'PNB',
    'CANBNK': 'Canara', 'CANARA': 'Canara',
    'UNIONB': 'Union', 'UNION BANK': 'Union',
    'IDFCFB': 'IDFC', 'IDFC': 'IDFC',
    'YESBNK': 'Yes', 'INDUSB': 'IndusInd', 'INDUSIND': 'IndusInd',
    'AUBANK': 'AU', 'BOIIND': 'BOI', 'CENTBK': 'Central',
    'IDBIBK': 'IDBI', 'FEDBNK': 'Federal', 'RBLBNK': 'RBL',
    'PAYTMB': 'Paytm', 'PAYTM': 'Paytm', 'PHONEPE': 'PhonePe',
    'AMZNPAY': 'AmazonPay', 'MOBIKWIK': 'MobiKwik',
  };

  // ─── Entry point ───────────────────────────────────────────────────────────

  ParsedSms parse({
    required String body,
    String? sender,
    required DateTime receivedAt,
  }) {
    if (body.trim().isEmpty) {
      return ParsedSms.rejected(SmsRejectReason.notFinancial, receivedAt);
    }

    if (_otp.hasMatch(body)) {
      return ParsedSms.rejected(SmsRejectReason.otp, receivedAt);
    }
    if (_paymentRequest.hasMatch(body)) {
      return ParsedSms.rejected(SmsRejectReason.paymentRequest, receivedAt);
    }
    if (_promotional.hasMatch(body)) {
      return ParsedSms.rejected(SmsRejectReason.promotional, receivedAt);
    }
    if (_future.hasMatch(body)) {
      return ParsedSms.rejected(SmsRejectReason.futureOrMandate, receivedAt);
    }

    final balanceSpans = _balanceSpans(body);
    final balancePaise =
        balanceSpans.isEmpty ? null : Money.parsePaise(balanceSpans.first.text);

    final amounts = _amountSpans(body, balanceSpans);
    if (amounts.isEmpty) {
      // A message that only states a balance is an enquiry, not a movement.
      final reason = balanceSpans.isNotEmpty
          ? SmsRejectReason.balanceEnquiry
          : SmsRejectReason.noAmount;
      return ParsedSms.rejected(reason, receivedAt);
    }

    final primary = amounts.first;
    final amountPaise = Money.parsePaise(primary.text);
    if (amountPaise == null || amountPaise <= 0) {
      return ParsedSms.rejected(SmsRejectReason.noAmount, receivedAt);
    }

    final isFailed = _failure.hasMatch(body);
    final kind = _kind(body);

    var type = _direction(body, primary.start);
    var directionAssumed = false;
    if (type == null) {
      // Decline notices often state no verb at all ("your transaction of
      // Rs.5,000 was declined"). They are still worth recording — they explain
      // a gap the user would otherwise hunt for — and since a failed
      // transaction contributes nothing to the balance, assuming "debit" here
      // cannot move any number. It is flagged all the same.
      if (isFailed) {
        type = 'debit';
        directionAssumed = true;
      } else {
        // A message quoting money with no movement verb is a balance or
        // statement notice, not a transaction.
        return ParsedSms.rejected(
          _balanceWord.hasMatch(body)
              ? SmsRejectReason.balanceEnquiry
              : SmsRejectReason.noDirection,
          receivedAt,
        );
      }
    }

    // "Reversed" and "refunded" both contain failure-adjacent language but
    // describe money genuinely moving back, so they override the failed flag.
    final treatAsFailed =
        isFailed && kind != TxnKind.reversal && kind != TxnKind.refund;

    final status = treatAsFailed
        ? TxnStatus.failed
        : (_pending.hasMatch(body) ? TxnStatus.pending : TxnStatus.posted);

    final bodyDate = _dateFromBody(body, receivedAt);

    // Distinct additional amounts suggest more than one movement in one SMS
    // (or a fee bundled with a payment). Flag rather than silently pick one.
    final distinctExtras = amounts
        .skip(1)
        .map((s) => Money.parsePaise(s.text))
        .where((p) => p != null && p != amountPaise)
        .length;

    String? reviewReason;
    if (distinctExtras > 0) {
      reviewReason = 'Message contains $distinctExtras other amount(s) — it may '
          'describe more than one transaction.';
    } else if (treatAsFailed) {
      reviewReason = 'Bank reported this transaction as failed or declined.';
    } else if (directionAssumed) {
      reviewReason =
          'The message did not say whether money went in or out; assumed a debit.';
    }

    return ParsedSms(
      isTransaction: true,
      type: type,
      amountPaise: amountPaise,
      dateTime: bodyDate ?? receivedAt,
      dateFromBody: bodyDate != null,
      merchant: _merchant(body),
      bank: _bank(body, sender),
      accountTail: _accountTail(body),
      referenceId: _referenceId(body),
      upiTransactionId: _upiId(body),
      balancePaise: balancePaise,
      status: status,
      kind: kind,
      needsReview: reviewReason != null,
      reviewReason: reviewReason,
      extraAmountCount: distinctExtras,
    );
  }

  // ─── Amounts ───────────────────────────────────────────────────────────────

  /// "Avl Bal 18500.00" — an explicit balance qualifier, currency optional.
  static final RegExp _balanceQualified = RegExp(
      r'(?:avl|avlbl|avail|available|clear|closing|updated|current|total)\s*'
      r'bal(?:ance)?\b[^0-9\u20B9]{0,10}(?:rs\.?|inr|\u20B9)?\s*'
      r'([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      caseSensitive: false);

  /// "...balance Rs.18,500.00" — no qualifier, so a currency marker is
  /// required. Without that requirement "declined due to insufficient balance
  /// on 15-01-26" reads as a balance of ₹15, which would then be trusted as
  /// the bank's own figure during reconciliation.
  static final RegExp _balanceWithCurrency = RegExp(
      r'\bbal(?:ance)?\b[^0-9\u20B9]{0,18}(?:rs\.?|inr|\u20B9)\s*'
      r'([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      caseSensitive: false);

  static final RegExp _balanceWord =
      RegExp(r'\bbal(?:ance)?\b', caseSensitive: false);

  /// Spans covering "Avl Bal Rs 1,234.00" style figures. These must never be
  /// mistaken for the transaction amount — doing so is the single most damaging
  /// parsing error possible here.
  List<_Span> _balanceSpans(String body) {
    final spans = <_Span>[];
    for (final re in [_balanceQualified, _balanceWithCurrency]) {
      for (final m in re.allMatches(body)) {
        if (spans.any((s) => m.start < s.end && m.end > s.start)) continue;
        spans.add(_Span(m.start, m.end, m.group(1)!));
      }
    }
    spans.sort((a, b) => a.start.compareTo(b.start));
    return spans;
  }

  static final RegExp _currencyLed = RegExp(
      r'(?:rs\.?|inr|\u20B9)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      caseSensitive: false);

  static final RegExp _currencyTrailed = RegExp(
      r'([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?:rs\.?|inr|rupees)\b',
      caseSensitive: false);

  static final RegExp _verbLed = RegExp(
      r'(?:debited|credited|withdrawn|deposited|paid|received|spent|sent|'
      r'transferred|charged|refunded|reversed)\s*'
      r'(?:by|for|with|of|amt|amount)?\s*:?\s*'
      r'([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      caseSensitive: false);

  /// Candidate transaction amounts, in document order, with balance figures
  /// removed.
  List<_Span> _amountSpans(String body, List<_Span> balances) {
    bool overlapsBalance(int start, int end) =>
        balances.any((b) => start < b.end && end > b.start);

    final found = <_Span>[];
    void collect(RegExp re) {
      for (final m in re.allMatches(body)) {
        final gStart = body.indexOf(m.group(1)!, m.start);
        if (gStart < 0) continue;
        final gEnd = gStart + m.group(1)!.length;
        if (overlapsBalance(gStart, gEnd)) continue;
        if (found.any((f) => f.start == gStart)) continue;
        found.add(_Span(gStart, gEnd, m.group(1)!));
      }
    }

    collect(_currencyLed);
    collect(_currencyTrailed);
    // Only fall back to verb-adjacent bare numbers when no currency-marked
    // amount exists; otherwise a reference number can be picked up as money.
    if (found.isEmpty) collect(_verbLed);

    found.sort((a, b) => a.start.compareTo(b.start));
    return found;
  }

  // ─── Direction ─────────────────────────────────────────────────────────────

  /// Chooses credit vs debit by the verb *nearest the amount*.
  ///
  /// Many alerts legitimately contain both words — "Rs.500 debited from A/c
  /// XX12 and credited to beneficiary" — so first-match-wins gets it backwards
  /// roughly half the time. Proximity to the amount is what actually
  /// disambiguates them.
  String? _direction(String body, int amountStart) {
    final lower = body.toLowerCase();

    int bestDistance = 1 << 30;
    String? best;

    void consider(String verb, String type) {
      var from = 0;
      while (true) {
        final idx = lower.indexOf(verb, from);
        if (idx < 0) break;
        final distance = (idx - amountStart).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          best = type;
        }
        from = idx + verb.length;
      }
    }

    for (final v in _creditVerbs) {
      consider(v, 'credit');
    }
    for (final v in _debitVerbs) {
      consider(v, 'debit');
    }

    return best;
  }

  String _kind(String body) {
    final lower = body.toLowerCase();
    if (lower.contains('revers')) return TxnKind.reversal;
    if (lower.contains('refund')) return TxnKind.refund;
    if (RegExp(r'\batm\b|cash w(?:it)?hdr|cash wdl').hasMatch(lower)) {
      return TxnKind.atm;
    }
    if (RegExp(r'\bcharge[sd]?\b|\bfee\b|penalty|levied|\bgst\b')
        .hasMatch(lower)) {
      return TxnKind.fee;
    }
    return TxnKind.normal;
  }

  // ─── Identifiers ───────────────────────────────────────────────────────────

  static final List<RegExp> _refPatterns = [
    RegExp(r'\butr\b\s*[:.\-]?\s*([A-Za-z0-9]{6,25})', caseSensitive: false),
    RegExp(r'ref(?:erence)?\s*(?:no|num|number|id)?\s*[:.\-]?\s*([A-Za-z0-9]{4,25})',
        caseSensitive: false),
    RegExp(r'(?:txn|transaction)\s*(?:id|no|ref)?\s*[:.\-]?\s*([A-Za-z0-9]{4,25})',
        caseSensitive: false),
    RegExp(r'\b(?:imps|neft|rtgs)\b[\s:\-/]*(?:ref\s*(?:no)?\s*[:.\-]?\s*)?([A-Za-z0-9]{6,25})',
        caseSensitive: false),
  ];

  String? _referenceId(String body) {
    for (final re in _refPatterns) {
      final m = re.firstMatch(body);
      final v = m?.group(1);
      if (v != null && v.length >= 4 && RegExp(r'\d').hasMatch(v)) {
        return v.toUpperCase();
      }
    }
    return null;
  }

  static final RegExp _upiLabelled = RegExp(
      r'upi\s*(?:ref(?:erence)?\s*(?:no|id)?)?\s*[:.\-/]?\s*(\d{9,18})',
      caseSensitive: false);
  static final RegExp _upiBare = RegExp(r'(?<!\d)(\d{12})(?!\d)');

  String? _upiId(String body) {
    final labelled = _upiLabelled.firstMatch(body);
    if (labelled != null) return labelled.group(1);
    if (body.toLowerCase().contains('upi')) {
      // A bare 12-digit run in a UPI message is the RRN.
      return _upiBare.firstMatch(body)?.group(1);
    }
    return null;
  }

  static final List<RegExp> _tailPatterns = [
    RegExp(r'(?:a\/c|acct|account|\bac\b)\s*(?:no\.?)?\s*[:\-]?\s*[xX*]*\s*(\d{3,6})(?!\d)',
        caseSensitive: false),
    RegExp(r'(?:card|ending(?:\s*with)?)\s*(?:no\.?)?\s*[:\-]?\s*[xX*]*\s*(\d{4})(?!\d)',
        caseSensitive: false),
    RegExp(r'[xX*]{2,}\s*(\d{3,6})(?!\d)'),
  ];

  String? _accountTail(String body) {
    for (final re in _tailPatterns) {
      final v = re.firstMatch(body)?.group(1);
      if (v != null) return v;
    }
    return null;
  }

  String? _bank(String body, String? sender) {
    final haystack = '${sender ?? ''} ${body.toUpperCase()}';
    // Longest signature first so 'BARODA' beats the 'BOB' substring rule.
    final keys = _bankBySignature.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final k in keys) {
      if (haystack.contains(k)) return _bankBySignature[k];
    }
    return null;
  }

  // ─── Merchant ──────────────────────────────────────────────────────────────

  static final List<RegExp> _merchantPatterns = [
    RegExp(r'(?:trf|transfer)\s+to\s+(.+?)(?:\s+ref\s*no|\s+ref\b|\s+on\b|[.\n]|$)',
        caseSensitive: false),
    RegExp(r'transfer from\s+(.+?)(?:\s+ref\s*no|\s+ref\b|[.\n]|$)',
        caseSensitive: false),
    RegExp(r'UPI\/(?:CR|DR|REV|RET|P2A|P2M)\/\d+\/([^/\n]+)',
        caseSensitive: false),
    RegExp(r'\bvpa\s+(\S+)', caseSensitive: false),
    RegExp(r'(?:credited by|received from|from)\s+([A-Za-z][A-Za-z0-9 .&\-]{2,30}?)(?:\s+ref\b|\s+on\b|[.,\n]|$)',
        caseSensitive: false),
    RegExp(r'\b(?:at|to)\s+([A-Za-z0-9][A-Za-z0-9 .&\-*]{2,30}?)\s+on\b',
        caseSensitive: false),
    RegExp(r'\binfo\s*[:\-]\s*([^.\n]{2,40})', caseSensitive: false),
  ];

  String? _merchant(String body) {
    for (final re in _merchantPatterns) {
      final raw = re.firstMatch(body)?.group(1);
      final cleaned = _cleanMerchant(raw);
      if (cleaned != null) return cleaned;
    }
    return null;
  }

  static String? _cleanMerchant(String? raw) {
    if (raw == null) return null;
    var s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'^[-:*.\s]+|[-:*.,\s]+$'), '');
    if (s.length < 2) return null;
    // A pure number is a reference we mis-grabbed, not a payee name.
    if (RegExp(r'^\d+$').hasMatch(s)) return null;
    if (s.length > 40) s = '${s.substring(0, 40)}...';
    return s;
  }

  // ─── Dates ─────────────────────────────────────────────────────────────────

  static const Map<String, int> _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  static final RegExp _dmyNumeric =
      RegExp(r'(?<!\d)(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})(?!\d)');
  static final RegExp _dmyAlpha = RegExp(
      r'(?<!\w)(\d{1,2})[-\s]?([A-Za-z]{3})[-\s]?(\d{2,4})(?!\d)',
      caseSensitive: false);
  static final RegExp _iso = RegExp(r'(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)');
  static final RegExp _time =
      RegExp(r'(?<!\d)(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?', caseSensitive: false);

  /// Extracts the transaction date the bank stated, falling back to null when
  /// the body has none or the result is implausible.
  ///
  /// Using the stated date matters for late-delivered SMS: a message received
  /// on the 3rd about a payment made on the 1st belongs in the 1st's month, and
  /// the fingerprint must be the same either way.
  DateTime? _dateFromBody(String body, DateTime receivedAt) {
    int? y, mo, d;

    final isoM = _iso.firstMatch(body);
    final alphaM = _dmyAlpha.firstMatch(body);
    final numM = _dmyNumeric.firstMatch(body);

    if (isoM != null) {
      y = int.parse(isoM.group(1)!);
      mo = int.parse(isoM.group(2)!);
      d = int.parse(isoM.group(3)!);
    } else if (alphaM != null) {
      final mon = _months[alphaM.group(2)!.toLowerCase()];
      if (mon != null) {
        d = int.parse(alphaM.group(1)!);
        mo = mon;
        y = _expandYear(int.parse(alphaM.group(3)!));
      }
    }

    if (y == null && numM != null) {
      // Indian bank SMS are dd/mm/yy. If the first field cannot be a day but
      // the second can, it is an mm/dd source instead.
      var a = int.parse(numM.group(1)!);
      var b = int.parse(numM.group(2)!);
      if (a > 31 || (a > 12 && b > 12)) return null;
      if (a > 12 && b <= 12) {
        d = a;
        mo = b;
      } else if (b > 12) {
        d = b;
        mo = a;
      } else {
        d = a;
        mo = b;
      }
      y = _expandYear(int.parse(numM.group(3)!));
    }

    if (y == null || mo == null || d == null) return null;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;

    int hh = 0, mm = 0, ss = 0;
    final t = _time.firstMatch(body);
    if (t != null) {
      hh = int.parse(t.group(1)!);
      mm = int.parse(t.group(2)!);
      ss = int.tryParse(t.group(3) ?? '0') ?? 0;
      final ampm = t.group(4)?.toLowerCase();
      if (ampm == 'pm' && hh < 12) hh += 12;
      if (ampm == 'am' && hh == 12) hh = 0;
      if (hh > 23 || mm > 59 || ss > 59) {
        hh = 0;
        mm = 0;
        ss = 0;
      }
    } else {
      // No time stated. Keep the received time-of-day when the day matches so
      // same-day ordering is preserved; otherwise use midday, which keeps the
      // row inside the right calendar day in every Indian timezone offset.
      if (receivedAt.year == y &&
          receivedAt.month == mo &&
          receivedAt.day == d) {
        hh = receivedAt.hour;
        mm = receivedAt.minute;
        ss = receivedAt.second;
      } else {
        hh = 12;
      }
    }

    final parsed = DateTime(y, mo, d, hh, mm, ss);
    // Reject nonsense: a real alert is never about the future, and a body date
    // years away from delivery means we matched a card expiry or a phone number.
    if (parsed.isAfter(receivedAt.add(const Duration(days: 2)))) return null;
    if (receivedAt.difference(parsed).inDays > 400) return null;
    // Guard against DateTime's rollover for impossible days (31 Feb -> 3 Mar).
    if (parsed.day != d || parsed.month != mo) return null;

    return parsed;
  }

  static int _expandYear(int raw) => raw < 100 ? 2000 + raw : raw;
}

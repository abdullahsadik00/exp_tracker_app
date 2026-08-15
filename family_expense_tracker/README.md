# Family Expense Tracker

A privacy-first, **fully offline** personal and family finance tracker built with Flutter. It turns bank SMS alerts and account statements (PDF / Excel) into a clean, categorized ledger — and layers smart analytics on top: spending anomalies, month-end forecasting, recurring-payment detection, and inter-account transfer reconciliation.

All data lives in a local SQLite database on the device. Nothing is uploaded to any server.

---

## Highlights

- 📥 **Automatic SMS import** — scans bank SMS (SBI / Bank of Baroda) and extracts amount, type, date, and counterparty.
- 📄 **Statement parsing** — imports transactions from **PDF** and **Excel** e-statements (Excel decoding runs in a background isolate to keep the UI smooth).
- 🏷️ **Smart auto-categorization** — a user-editable, priority-based rules engine maps merchants/keywords to categories, family members, and banks.
- 👨‍👩‍👧 **Family attribution** — every transaction is assigned to *Me / Mom / Dad* for per-member contribution breakdowns.
- 🔁 **Transfer detection** — automatically surfaces self-transfers between your own accounts (same amount, opposite direction, within 48 hours) so they don't distort spending totals.
- 📊 **Analytics** — monthly trends, category insights, spending anomalies (≥1.5× the 3-month average), month-end burn-rate forecasts, and recurring-payment discovery.
- 💸 **Budgets** — per-category monthly budgets with live progress.
- 🧮 **Running balance ledger** — per-bank closing balances are recomputed incrementally on every change.
- 📤 **Export & backup** — share your data as **CSV** or back up/restore the full ledger as **JSON**.

---

## Screens

| Screen | Purpose |
| --- | --- |
| **Dashboard** | At-a-glance stats, per-member & per-bank flow, SMS sync, export/backup/restore. |
| **Transactions** | Browse, filter, multi-select, and bulk-edit (bank / assignee / delete). |
| **Add Transaction** | Manual entry. |
| **Analytics** | Yearly trend, category breakdown, and entry point to deep insights. |
| **Category Insights** | Per-category averages, peak/low months, 6-month trend, family split, drill-down. |
| **Categorization Rules** | Create, edit, and prioritize the auto-categorization rules. |
| **Transfer Review** | Confirm or dismiss detected self-transfers. |
| **PDF / Excel Statement** | Import transactions from statement files. |

---

## Tech Stack

- **Framework:** Flutter (Dart SDK `^3.11.4`), Material 3, dark theme.
- **Local storage:** `sqflite` (SQLite).
- **Charts:** `fl_chart`.
- **Statement parsing:** `syncfusion_flutter_pdf`, `excel`.
- **Device integration:** `flutter_sms_inbox`, `permission_handler`, `file_picker`.
- **Sharing / export:** `share_plus`, `csv`, `path_provider`.
- **Formatting:** `intl`.

---

## Project Structure

```
family_expense_tracker/
├── lib/
│   ├── main.dart                 # App entry point, root MaterialApp & bottom navigation
│   ├── models/                   # Plain data models (TransactionModel, BudgetModel)
│   ├── services/                 # Business logic & data access (no UI)
│   │   ├── local_db_service.dart          # SQLite: schema, CRUD, queries, ledger sync, backup
│   │   ├── categorization_service.dart     # Rules engine + description cleanup
│   │   ├── sms_service.dart                # Bank-SMS reading & parsing
│   │   ├── pdf_parser_service.dart         # PDF statement parsing
│   │   ├── excel_parser_service.dart       # Excel statement parsing (background isolate)
│   │   ├── spending_analysis_service.dart  # Category stats, trends, family distribution
│   │   └── export_service.dart             # CSV export
│   ├── screens/                  # One file per screen (UI)
│   ├── widgets/                  # Reusable UI components
│   └── theme/                    # App color palette
├── android/ · ios/               # Platform projects
└── pubspec.yaml
```

The codebase follows a clear **layered separation**: `models` (data) → `services` (logic & persistence) → `screens` / `widgets` (presentation). UI never talks to SQLite directly; it goes through `LocalDbService` and the other services.

> **Note on repository layout:** the Flutter project lives in `family_expense_tracker/`, one level below the git root (`exp_tracker_app/`). Run all Flutter commands from inside `family_expense_tracker/`.

---

## Getting Started

### Prerequisites

- Flutter SDK (Dart `^3.11.4`)
- Android Studio / Xcode for device builds

### Setup

```bash
git clone <repo-url>
cd exp_tracker_app/family_expense_tracker

flutter pub get
flutter run
```

### Permissions

- **Android:** `READ_SMS` (declared in `AndroidManifest.xml`) is requested at runtime for the SMS-import feature. The app is fully usable without granting it — you can add transactions manually or via statement import.

---

## How It Works

### Auto-Categorization

`CategorizationService` matches each transaction's raw text against an ordered list of `CategorizationRule`s. Rules are tiered by `priority` (lower runs first):

| Priority | Purpose | Example |
| --- | --- | --- |
| 10 | Bank detection | `BARODA → BoB` |
| 20 | Person assignment | `NILOFAR → Mom` |
| 30 | Category | `BLINKIT → Groceries` |

The first match for each field (bank / assignee / category) wins, and any uncategorized transaction falls back to sensible defaults. Rules are fully editable in-app via the **Categorization Rules** screen and persisted in SQLite, so categorization improves over time without code changes.

Transactions no rule recognised are listed under **No rule matched** on the Sync & Reconciliation screen. They import cleanly, so nothing else flags them — they never reach the review queue or the unparsed list — and every future message of the same shape lands the same way until a rule exists. The list is really a list of rules that are missing; adding one and re-applying it fixes the past rows too.

### Transfer Detection

Money you move between your own accounts is income on one side and an expense on the other — counting both would double-count. `LocalDbService.getPotentialTransferPairs()` finds candidate pairs (equal amount, opposite type, different banks, within ~48h) and the **Transfer Review** screen lets you confirm or dismiss them. Confirmed transfers are excluded from spending/income analytics.

### Running Balance Ledger

Each transaction stores a `closingBalance`. After any insert/update/delete, `syncLedgerBalances()` recomputes that bank's balances from its opening balance forward, so the ledger stays consistent. The figure is shown under each row's amount in the transactions list.

A balance is only ever as right as the opening balance it starts from, and plenty of bank alerts quote no balance at all — so there is often nothing to check that starting figure against. Typing the real balance into **Balance after this** on any transaction offers to fix that: `previewAnchorFromTransaction()` works out what the account's opening balance would have to be for that row to read the stated figure, and applying it shifts the opening balance so every balance in the account — and the dashboard total — follows.

Only the opening balance moves; no transaction is edited, so the arithmetic between any two rows is unchanged. It is offered rather than applied, because a mismatch is usually evidence of a missing or duplicated transaction and worth seeing before it is smoothed over.

### Data Safety

- **Backup:** exports the full ledger to a timestamped JSON file and opens the system share sheet.
- **Restore:** merges a JSON backup back in (upsert by id) and re-syncs balances.
- **Export:** writes a CSV of all transactions for use in spreadsheets.

---

## Roadmap

- [ ] Unit & widget test coverage
- [ ] Support for additional banks
- [ ] Consolidate 6-month vs. 12-month trend windows in Category Insights
- [ ] Optional encrypted backups

---

## License

This is a private project and is not published to pub.dev. All rights reserved.

## Author

**Sadik Shaikh** · abdullahsadik00@gmail.com

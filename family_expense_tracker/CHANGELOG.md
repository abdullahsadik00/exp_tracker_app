# Changelog

All notable changes to this project are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **A balance typed on a transaction can now correct the whole account.** Many bank alerts quote no balance, so the ledger had nothing to check its opening balance against and the "Bank-reported Balance" field changed nothing on screen. Entering what the account actually held after a transaction now offers to shift that account's opening balance to match, which updates every balance in the account and the dashboard total. Only the opening balance moves — no transaction is edited — and it is confirmed rather than applied silently, since a mismatch is usually evidence of a missing or duplicated transaction.
- **The running balance is shown under each transaction.** `closingBalance` had been computed and stored on every row since the ledger was built, but appeared nowhere outside CSV export.

### Fixed
- **A recorded balance can be cleared again.** `TransactionModel.copyWith` treated a null `smsBalancePaise` as "leave unchanged", and `Money.parsePaise('')` returns null, so emptying the balance field was a no-op — a wrong figure could be corrected but never removed. Added an explicit `clearSmsBalance` flag.
- **Setting an opening balance no longer wipes the account's tail digits.** `setOpeningBalance()` wrote the `accounts` row with `ConflictAlgorithm.replace` while naming only three columns, nulling `account_tail` (and `opening_date`, when not passed) every time. It now carries the existing values forward.
- **CSV export no longer fails to compile.** `ExportService` used a non-existent `Csv().encode()` API; replaced with `const ListToCsvConverter().convert()` from the `csv` package.
- **Bulk bank reassignment now keeps both ledgers correct.** `LocalDbService.bulkUpdateBank()` previously re-synced only the destination bank's running balances, leaving the source bank's `closingBalance` chain stale. It now re-syncs every affected bank (source and destination), and short-circuits on an empty selection.

### Changed
- **Hardened raw SQL.** All eight `rawQuery` calls that interpolated the current month string directly into SQL now use bound `?` parameters instead. Behavior is unchanged; the queries are safer and more idiomatic.
- **Wired up `ExportService`.** Added an **Export to CSV** action to the Dashboard overflow menu, with empty-state and error handling.
- **Wired up `SpendingAnalysisService`.** The Category Insights screen now delegates its average / peak / lowest-month and family-split calculations to the shared service instead of duplicating the logic inline.
- **Documentation.** Replaced the default Flutter boilerplate `README.md` with full project documentation, and added this changelog.

### Removed
- Removed the unused `SettingsScreen` placeholder from `main.dart`.
- Removed a misleading startup log claiming the SQLite database was initialized at launch (it is lazy-initialized on first access), and the no-op `cycle()` helper in `SpendingAnalysisService`.

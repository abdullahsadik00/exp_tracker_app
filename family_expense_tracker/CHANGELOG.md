# Changelog

All notable changes to this project are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed
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

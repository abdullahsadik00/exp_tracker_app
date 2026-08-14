package com.example.family_expense_tracker

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/**
 * Durable hand-off queue between the SMS broadcast receiver and the Flutter
 * isolate.
 *
 * The receiver may fire when the app process is dead, so the captured message
 * has to survive on its own until Dart can come and collect it. It lives in a
 * small dedicated SQLite database rather than in the app's transaction database
 * on purpose: two processes/isolates writing the ledger concurrently is exactly
 * the kind of race that corrupts a balance, so native code never touches it.
 * Everything the receiver captures is imported later, by the one isolate that
 * owns the ledger, through the same idempotent path as a manual sync.
 */
class SmsQueueStore(context: Context) :
    SQLiteOpenHelper(context.applicationContext, DB_NAME, null, DB_VERSION) {

    companion object {
        private const val DB_NAME = "sms_capture_queue.db"
        private const val DB_VERSION = 1
        private const val TABLE = "pending_sms"

        /** Newest N messages are kept if Dart never comes to drain them. */
        private const val MAX_ROWS = 1000
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE $TABLE(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sender TEXT,
                body TEXT NOT NULL,
                received_at INTEGER NOT NULL,
                captured_at INTEGER NOT NULL
            )
            """.trimIndent()
        )
        // The platform can deliver the same broadcast more than once, and a
        // re-delivered message must not become a second queue entry. Dart
        // de-duplicates again downstream; this simply keeps the queue honest.
        db.execSQL(
            "CREATE UNIQUE INDEX idx_pending_identity " +
                "ON $TABLE (sender, body, received_at)"
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Only version 1 exists. A future migration goes here; dropping the
        // queue would silently lose captured transactions, so never do that.
    }

    /** Returns true if the message was newly queued. */
    fun enqueue(sender: String?, body: String, receivedAt: Long): Boolean {
        val values = ContentValues().apply {
            put("sender", sender)
            put("body", body)
            put("received_at", receivedAt)
            put("captured_at", System.currentTimeMillis())
        }

        val db = writableDatabase
        // CONFLICT_IGNORE makes a duplicate delivery a no-op rather than an error.
        val rowId = db.insertWithOnConflict(
            TABLE, null, values, SQLiteDatabase.CONFLICT_IGNORE
        )
        if (rowId != -1L) prune(db)
        return rowId != -1L
    }

    /** Oldest-first, so transactions are imported in the order they happened. */
    fun peek(limit: Int = 200): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        readableDatabase.query(
            TABLE,
            arrayOf("id", "sender", "body", "received_at"),
            null, null, null, null,
            "received_at ASC, id ASC",
            limit.toString()
        ).use { cursor ->
            while (cursor.moveToNext()) {
                out.add(
                    mapOf(
                        "id" to cursor.getLong(0),
                        "sender" to cursor.getString(1),
                        "body" to cursor.getString(2),
                        "receivedAt" to cursor.getLong(3)
                    )
                )
            }
        }
        return out
    }

    /**
     * Removes messages Dart has finished importing.
     *
     * Called only after the import has committed. If the process dies in
     * between, the messages are simply imported again on the next drain and the
     * fingerprint index turns that into a no-op — losing them would be the
     * unrecoverable failure, so the ordering is deliberate.
     */
    fun acknowledge(ids: List<Long>) {
        if (ids.isEmpty()) return
        val placeholders = ids.joinToString(",") { "?" }
        writableDatabase.delete(
            TABLE,
            "id IN ($placeholders)",
            ids.map { it.toString() }.toTypedArray()
        )
    }

    fun count(): Int {
        readableDatabase.rawQuery("SELECT COUNT(*) FROM $TABLE", null).use { c ->
            return if (c.moveToFirst()) c.getInt(0) else 0
        }
    }

    private fun prune(db: SQLiteDatabase) {
        db.execSQL(
            "DELETE FROM $TABLE WHERE id NOT IN " +
                "(SELECT id FROM $TABLE ORDER BY received_at DESC, id DESC LIMIT $MAX_ROWS)"
        )
    }
}

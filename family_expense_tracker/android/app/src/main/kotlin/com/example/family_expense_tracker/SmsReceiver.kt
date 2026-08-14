package com.example.family_expense_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

/**
 * Captures incoming SMS the moment they arrive, whether or not the app is
 * running.
 *
 * This receiver does as little as possible: reassemble the message, drop the
 * obviously non-financial ones, and hand the rest to [SmsQueueStore]. It never
 * parses amounts and never touches the transaction database — all of that
 * happens later in Dart, in the single isolate that owns the ledger, so there
 * is exactly one implementation of "what counts as a transaction" and one
 * writer of the balance.
 */
class SmsReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "SmsReceiver"

        /**
         * Cheap pre-filter, applied before anything is written to disk.
         *
         * Deliberately permissive — its job is to keep OTPs and private
         * conversations out of the capture queue, not to decide what is a
         * transaction. Anything it wrongly rejects is still picked up by the
         * full inbox scan that runs on app launch, so a miss here costs
         * timeliness, never correctness.
         */
        private val FINANCIAL_HINT = Regex(
            "\\bdebited?\\b|\\bcredited?\\b|\\bwithdraw|\\bdeposit|\\bupi\\b|" +
                "\\btxn\\b|\\btransaction\\b|\\ba/c\\b|\\bacct\\b|\\bspent\\b|" +
                "\\bpaid\\b|\\brefund|\\brs\\.?\\b|\\binr\\b|₹",
            RegexOption.IGNORE_CASE
        )

        /** Never queue a message that is plainly a one-time password. */
        private val OTP = Regex(
            "\\botp\\b|one[\\s-]?time\\s?password|verification code|do not share",
            RegexOption.IGNORE_CASE
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        // Reassembly and the disk write must not run on the main thread, and
        // onReceive's process may be killed the moment it returns — goAsync
        // keeps the process alive until the work is finished.
        val pending = goAsync()
        val appContext = context.applicationContext

        Thread {
            try {
                captureMessages(appContext, intent)
            } catch (t: Throwable) {
                // A crash here would kill the user's messaging pipeline, so
                // failure is swallowed. The inbox scan on next launch is the
                // backstop that keeps the ledger complete.
                Log.e(TAG, "Failed to capture incoming SMS", t)
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun captureMessages(context: Context, intent: Intent) {
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (parts.isEmpty()) return

        // A long SMS arrives as several PDUs that each hold one fragment of the
        // text. Concatenating them is what makes the amount and the reference
        // number — often split across the fragment boundary — readable at all.
        val bodies = LinkedHashMap<String, StringBuilder>()
        val timestamps = HashMap<String, Long>()

        for (part in parts) {
            val sender = part.originatingAddress ?: part.displayOriginatingAddress ?: ""
            val text = part.messageBody ?: continue
            val existing = bodies[sender]
            if (existing == null) {
                bodies[sender] = StringBuilder(text)
                timestamps[sender] = part.timestampMillis
            } else {
                existing.append(text)
            }
        }

        val store = SmsQueueStore(context)
        var queued = 0

        try {
            for ((sender, builder) in bodies) {
                val body = builder.toString()
                if (body.isBlank()) continue
                if (OTP.containsMatchIn(body)) continue
                if (!FINANCIAL_HINT.containsMatchIn(body)) continue

                val timestamp = timestamps[sender] ?: System.currentTimeMillis()
                if (store.enqueue(sender, body, timestamp)) queued++
            }
        } finally {
            store.close()
        }

        // If the Flutter engine happens to be alive, import immediately;
        // otherwise the queue simply waits for the next launch.
        if (queued > 0) {
            SmsQueueBridge.notifyDart(queued)
        }
    }
}

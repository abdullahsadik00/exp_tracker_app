package com.example.family_expense_tracker

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel over [SmsQueueStore].
 *
 * Dart pulls from the queue and acknowledges what it has committed; native code
 * never pushes transactions into the ledger itself. That keeps the write path
 * single-threaded and single-isolate, which is what lets the balance stay
 * exactly derivable from the transaction table.
 */
class SmsQueueBridge(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.example.family_expense_tracker/sms_queue"

        /**
         * Set while a Flutter engine is attached. Held statically so the
         * broadcast receiver — which has no reference to the activity — can
         * nudge Dart when the app happens to be running.
         */
        @Volatile
        private var channel: MethodChannel? = null

        fun attach(methodChannel: MethodChannel) {
            channel = methodChannel
        }

        fun detach() {
            channel = null
        }

        /**
         * Tells Dart that new messages are waiting. Best-effort by design: when
         * the process was started purely to handle the broadcast there is no
         * engine to talk to, and the queue is drained on next launch instead.
         */
        fun notifyDart(count: Int) {
            val target = channel ?: return
            // Method channels must be used on the main thread; onReceive work
            // happens on a background thread.
            Handler(Looper.getMainLooper()).post {
                try {
                    target.invokeMethod("onSmsCaptured", count)
                } catch (_: Throwable) {
                    // The engine can detach between the null check and this
                    // call. Losing the nudge is harmless — the queue persists.
                }
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val store = SmsQueueStore(context)
        try {
            when (call.method) {
                "peek" -> {
                    val limit = call.argument<Int>("limit") ?: 200
                    result.success(store.peek(limit))
                }

                "acknowledge" -> {
                    val ids = call.argument<List<Number>>("ids")?.map { it.toLong() }
                    store.acknowledge(ids ?: emptyList())
                    result.success(null)
                }

                "count" -> result.success(store.count())

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("SMS_QUEUE_ERROR", t.message, null)
        } finally {
            store.close()
        }
    }
}

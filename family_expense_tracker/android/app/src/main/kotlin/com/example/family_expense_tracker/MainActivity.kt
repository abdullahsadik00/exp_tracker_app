package com.example.family_expense_tracker

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var smsQueueChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SmsQueueBridge.CHANNEL
        )
        channel.setMethodCallHandler(SmsQueueBridge(applicationContext))

        // Registered statically so the SMS broadcast receiver can signal Dart
        // while the app is running. When it is not running, the receiver still
        // queues to disk and this is simply absent.
        SmsQueueBridge.attach(channel)
        smsQueueChannel = channel
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        SmsQueueBridge.detach()
        smsQueueChannel?.setMethodCallHandler(null)
        smsQueueChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

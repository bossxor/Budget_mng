package com.bossxor.jumeoni

import android.content.Intent
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jumeoni/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isListenerEnabled" ->
                        result.success(NotificationManagerCompat.getEnabledListenerPackages(this).contains(packageName))
                    "openListenerSettings" -> {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }
                    "setSecure" -> {
                        val on = call.arguments as? Boolean ?: false
                        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

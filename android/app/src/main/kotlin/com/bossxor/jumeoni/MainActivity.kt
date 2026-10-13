package com.bossxor.jumeoni

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    companion object {
        const val QUICK_ADD = "com.bossxor.jumeoni.QUICK_ADD"
    }

    private var channel: MethodChannel? = null
    // 앱 아이콘 바로가기로 열렸을 때 Dart가 가져갈 동작. 한 번 가져가면 비운다.
    private var pendingAction: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingAction = actionOf(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val a = actionOf(intent) ?: return
        // 이미 떠 있는 앱이면 바로 알리고, 아직 화면이 준비 전이면 보관한다.
        val ch = channel
        if (ch != null) ch.invokeMethod("launchAction", a) else pendingAction = a
    }

    private fun actionOf(i: Intent?): String? =
        if (i?.action == QUICK_ADD) "quick_add" else null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jumeoni/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
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
                "takeLaunchAction" -> {
                    result.success(pendingAction)
                    pendingAction = null
                }
                else -> result.notImplemented()
            }
        }
    }
}

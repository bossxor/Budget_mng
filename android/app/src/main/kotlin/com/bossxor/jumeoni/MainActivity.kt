package com.bossxor.jumeoni

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.result.contract.ActivityResultContracts
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
        const val REVIEW = "com.bossxor.jumeoni.REVIEW"
        const val HISTORY = "com.bossxor.jumeoni.HISTORY"
        const val QUICK_ADD = "com.bossxor.jumeoni.QUICK_ADD"
    }

    private var permissionResult: MethodChannel.Result? = null
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        permissionResult?.success(granted)
        permissionResult = null
    }
    private fun requestNotifications(result: MethodChannel.Result, once: Boolean) {
        ResultNotifications.channels(this)
        val prefs = getSharedPreferences("result_notifications", MODE_PRIVATE)
        if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            if (!once) startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            result.success(true)
        } else if (!prefs.getBoolean("asked", false)) {
            if (permissionResult != null) { result.success(false); return }
            prefs.edit().putBoolean("asked", true).apply()
            permissionResult = result
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            if (!once) startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            result.success(false)
        }
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
        pendingAction = a
        // 이미 떠 있는 앱이면 바로 알리고, 아직 화면이 준비 전이면 보관한다.
        val ch = channel
        if (ch != null) ch.invokeMethod("launchAction", a)
    }

    private fun actionOf(i: Intent?): String? =
        when (i?.action) { QUICK_ADD -> "quick_add"; REVIEW -> "review"; HISTORY -> "history"; else -> null }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jumeoni/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationsOnce" -> requestNotifications(result, true)
                "requestNotifications" -> requestNotifications(result, false)
                "ingestResult" -> {
                    ResultNotifications.post(this, call.arguments as? Map<*, *>)
                    result.success(null)
                }
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
                "listApps" -> {
                    // 런처에 보이는 앱만 (이름, 패키지). 직접 추가할 금융 앱을 고르는 용도.
                    val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val apps = packageManager.queryIntentActivities(i, 0)
                        .map { mapOf("name" to it.loadLabel(packageManager).toString(), "package" to it.activityInfo.packageName) }
                        .filter { it["package"] != packageName }
                        .distinctBy { it["package"] }
                        .sortedBy { it["name"] }
                    result.success(apps)
                }
                "updateWidgets" -> {
                    BudgetWidget.updateAll(this)
                    result.success(null)
                }
                "pinWidget" -> result.success(BudgetWidget.pin(this))
                "takeLaunchAction" -> {
                    result.success(pendingAction)
                    pendingAction = null
                }
                else -> result.notImplemented()
            }
        }
    }
}

package com.bossxor.jumeoni

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.widget.RemoteViews
import org.json.JSONObject
import java.text.NumberFormat
import java.util.Calendar
import java.util.Locale

class BudgetWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        updateAll(context)
        // 월 변경과 재부팅 후에도 Dart의 동일한 집계로 새 스냅샷을 만든다.
        IngestRunner.run(context)
    }

    companion object {
        fun pin(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < 26) return false
            val manager = AppWidgetManager.getInstance(context)
            if (!manager.isRequestPinAppWidgetSupported) return false
            return manager.requestPinAppWidget(ComponentName(context, BudgetWidget::class.java), null, null)
        }

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, BudgetWidget::class.java))
            if (ids.isEmpty()) return
            val views = RemoteViews(context.packageName, R.layout.budget_widget)
            val now = Calendar.getInstance()
            val month = now.get(Calendar.MONTH) + 1
            views.setTextViewText(R.id.widget_title, "주머니 · ${month}월")
            views.setTextViewText(R.id.widget_spent, "앱을 열어 확인하세요")
            views.setTextViewText(R.id.widget_budget, "이번 달 지출 · 예산")
            views.setTextViewText(R.id.widget_updated, "앱에서 새로고침할 수 있어요")
            try {
                SQLiteDatabase.openDatabase(context.getDatabasePath("budget.db").path, null,
                    SQLiteDatabase.OPEN_READONLY).use { db ->
                    val values = mutableMapOf<String, String>()
                    db.rawQuery("SELECT k,v FROM kv WHERE k IN ('lock_hash','widget_snapshot')", null).use { cursor ->
                        while (cursor.moveToNext()) values[cursor.getString(0)] = cursor.getString(1) ?: ""
                    }
                    if (!values["lock_hash"].isNullOrBlank()) {
                        views.setTextViewText(R.id.widget_spent, "금액 숨김")
                        views.setTextViewText(R.id.widget_budget, "앱 잠금 사용 중 · 앱에서 확인")
                        views.setTextViewText(R.id.widget_updated, "")
                    } else {
                        val data = JSONObject(values["widget_snapshot"] ?: "{}")
                        if (data.optInt("year") == now.get(Calendar.YEAR) && data.optInt("month") == month) {
                            val fmt = NumberFormat.getIntegerInstance(Locale.KOREA)
                            val spent = data.getLong("spent")
                            views.setTextViewText(R.id.widget_spent, "${fmt.format(spent)}원")
                            val detail = if (data.isNull("limit")) "전체 예산을 설정해 보세요" else {
                                val left = data.getLong("limit") - spent
                                if (left >= 0) "예산 ${fmt.format(left)}원 남음" else "예산 ${fmt.format(-left)}원 초과"
                            }
                            views.setTextViewText(R.id.widget_budget, detail)
                            val at = Calendar.getInstance().apply { timeInMillis = data.getLong("updatedAt") }
                            views.setTextViewText(R.id.widget_updated,
                                "${at.get(Calendar.MONTH) + 1}/${at.get(Calendar.DAY_OF_MONTH)} " +
                                String.format(Locale.KOREA, "%02d:%02d 업데이트", at.get(Calendar.HOUR_OF_DAY), at.get(Calendar.MINUTE)))
                        }
                    }
                }
            } catch (_: Exception) { /* 초기 설정 전에는 안내 문구를 유지한다. */ }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            views.setOnClickPendingIntent(R.id.widget_root, PendingIntent.getActivity(context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), flags))
            views.setOnClickPendingIntent(R.id.widget_add, PendingIntent.getActivity(context, 1,
                Intent(context, MainActivity::class.java).setAction(MainActivity.QUICK_ADD)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), flags))
            manager.updateAppWidget(ids, views)
        }
    }
}

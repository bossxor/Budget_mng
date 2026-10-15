package com.bossxor.jumeoni

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

object ResultNotifications {
    fun channels(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel("ingest_saved", "거래 반영 완료", NotificationManager.IMPORTANCE_LOW))
            manager.createNotificationChannel(NotificationChannel("ingest_review", "확인이 필요한 내역", NotificationManager.IMPORTANCE_DEFAULT))
        }
    }
    fun post(context: Context, data: Map<*, *>?) {
        val saved = (data?.get("saved") as? Number)?.toInt() ?: 0
        val review = (data?.get("review") as? Number)?.toInt() ?: 0
        if (saved <= 0 && review <= 0) return
        channels(context)
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return
        fun show(id: Int, channel: String, title: String, text: String, action: String) {
            val pending = PendingIntent.getActivity(context, id,
                Intent(context, MainActivity::class.java).setAction(action).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val notification = NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_tile_add).setContentTitle(title).setContentText(text)
                .setAutoCancel(true).setOnlyAlertOnce(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setContentIntent(pending).build()
            try { manager.notify(id, notification) } catch (_: SecurityException) { }
        }
        if (saved > 0) show(2101, "ingest_saved", "거래 ${saved}건이 반영되었습니다",
            "가계부에 자동으로 기록했어요. 눌러서 내역을 확인하세요.", MainActivity.HISTORY)
        if (review > 0) show(2102, "ingest_review", "내역 ${review}건 확인이 필요합니다",
            "미분류·중복 의심·인식 못 한 알림을 눌러서 검토해 주세요.", MainActivity.REVIEW)
    }
}

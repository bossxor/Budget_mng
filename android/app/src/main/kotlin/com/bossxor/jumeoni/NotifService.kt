package com.bossxor.jumeoni

import android.app.Notification
import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * 금융 알림 원문을 앱 DB(raw_notification)에 쌓는다. 파싱은 Dart 쪽에서 앱이 열릴 때 처리한다.
 * 개인 대화가 저장되지 않도록 패키지/제목/키워드로 먼저 거른다.
 */
class NotifService : NotificationListenerService() {

    companion object {
        private val BANK_APPS = setOf(
            "com.kakaobank.channel",   // 카카오뱅크
            "viva.republica.toss",     // 토스
        )
        private val SMS_APPS = setOf(
            "com.samsung.android.messaging",
            "com.google.android.apps.messaging",
            "com.android.mms",
        )
        private const val KAKAO = "com.kakao.talk"
        // 카카오톡은 이 제목(채팅방/채널명)의 알림만 저장한다.
        private val KAKAO_TITLES = setOf("삼성카드")
        private val FINANCE_WORDS = Regex("입금|출금|승인|취소|결제|원")
    }

    /** 문자 앱은 MessagingStyle이라 EXTRA_TEXT가 비는 경우가 있어 메시지 목록에서 읽는다. */
    private fun messagingText(extras: android.os.Bundle): String? {
        @Suppress("DEPRECATION")
        val arr = extras.getParcelableArray(Notification.EXTRA_MESSAGES) ?: return null
        val msgs = Notification.MessagingStyle.Message.getMessagesFromBundleArray(arr)
        return msgs.lastOrNull()?.text?.toString()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val pkg = sbn.packageName
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString()
            ?: messagingText(extras)
            ?: return
        if (text.isBlank()) return

        val allowed = when (pkg) {
            in BANK_APPS -> true
            in SMS_APPS -> FINANCE_WORDS.containsMatchIn(text)
            KAKAO -> title in KAKAO_TITLES
            else -> false
        }
        if (!allowed) return

        // 문자 알림은 제목이 발신자라 본문 첫 줄에 붙지 않는다. 본문만 저장.
        try {
            val db = SQLiteDatabase.openOrCreateDatabase(getDatabasePath("budget.db"), null)
            db.use {
                it.execSQL(
                    """CREATE TABLE IF NOT EXISTS raw_notification(
                        id INTEGER PRIMARY KEY AUTOINCREMENT, package TEXT, title TEXT, text TEXT,
                        posted_at INTEGER, state INTEGER DEFAULT 0, UNIQUE(package, text, posted_at))"""
                )
                val v = ContentValues().apply {
                    put("package", pkg)
                    put("title", title)
                    put("text", text)
                    put("posted_at", sbn.postTime)
                    put("state", 0)
                }
                it.insertWithOnConflict("raw_notification", null, v, SQLiteDatabase.CONFLICT_IGNORE)
            }
        } catch (_: Exception) {
            // 수집 실패가 서비스를 죽이지 않게 한다.
        }
    }
}

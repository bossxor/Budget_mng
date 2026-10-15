package com.bossxor.jumeoni

import android.app.Notification
import android.content.ContentValues
import android.content.pm.ApplicationInfo
import android.database.sqlite.SQLiteDatabase
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * 금융 알림 원문을 앱 DB(raw_notification)에 쌓고, 바로 Dart 파서를 돌려 거래로 바꿔 둔다.
 * 개인 대화가 저장되지 않도록 패키지/제목/키워드로 먼저 거른다.
 */
class NotifService : NotificationListenerService() {

    companion object {
        private val BANK_APPS = setOf(
            "com.nonghyup.nhallonebank",
            "com.kakaobank.channel",   // 카카오뱅크
            "viva.republica.toss",     // 토스
        )
        private val SMS_APPS = setOf(
            "com.samsung.android.messaging",
            "com.google.android.apps.messaging",
            "com.android.mms",
        )
        private const val KAKAO = "com.kakao.talk"
        private const val SHELL = "com.android.shell" // 디버그 빌드에서만 테스트용으로 허용
        // 카카오톡은 이 제목(채팅방/채널명)의 알림만 저장한다.
        private val KAKAO_TITLES = setOf("삼성카드")
        // 금액 알림만 저장한다: 금융 키워드가 있고 광고/수신거부 문구가 없어야 한다.
        private val FINANCE_WORDS = Regex("입금|출금|승인|취소|결제|이체|송금|잔액")
        private val AD_WORDS = Regex("\\(광고\\)|수신거부|알림\\s*끄기|무료수신|인증번호|인증코드|OTP")
    }

    private val debuggable: Boolean
        get() = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /** 설정에서 사용자가 직접 추가한 앱 (kv.extra_packages, 쉼표 구분). */
    private fun extraPackages(): Set<String> = try {
        SQLiteDatabase.openDatabase(getDatabasePath("budget.db").path, null, SQLiteDatabase.OPEN_READONLY).use {
            it.rawQuery("SELECT v FROM kv WHERE k='extra_packages'", null).use { c ->
                if (c.moveToFirst()) c.getString(0).split(",").map { s -> s.trim() }.filter { s -> s.isNotEmpty() }.toSet()
                else emptySet()
            }
        }
    } catch (_: Exception) { emptySet() }

    /** 문자 앱은 MessagingStyle이라 EXTRA_TEXT가 비는 경우가 있어 메시지 목록에서 읽는다. */
    private fun messagingText(extras: android.os.Bundle): String? {
        @Suppress("DEPRECATION")
        val arr = extras.getParcelableArray(Notification.EXTRA_MESSAGES) ?: return null
        val msgs = Notification.MessagingStyle.Message.getMessagesFromBundleArray(arr)
        return msgs.lastOrNull()?.text?.toString()
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        // 설치/재연결 시 현재 알림창에 남은 거래도 원래 수신 시각으로 수집한다.
        try { activeNotifications?.forEach { onNotificationPosted(it) } } catch (_: Exception) { }
    }

    private fun looksLikeTransaction(text: String): Boolean {
        val value = text.replace("입출금 알림", "")
        if (Regex("\\(광고\\)|수신거부|알림\\s*끄기|인증번호|인증코드|OTP|요청|예정|예약|실패|거절|해주세요|부탁", RegexOption.IGNORE_CASE).containsMatchIn(value)) return false
        return Regex("(?:입금|출금|결제|승인)(?:완료|액)?\\s*[:：]?\\s*[\\d,]+\\s*원|[\\d,]+\\s*원(?:이|을)?\\s*(?:입금|출금|결제|승인)").containsMatchIn(value)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName || (sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        val pkg = sbn.packageName
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = listOf(
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
            extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
            messagingText(extras)
        ).firstOrNull { !it.isNullOrBlank() } ?: return
        if (text.isBlank()) return

        val whole = "$title\n$text"
        val financial = FINANCE_WORDS.containsMatchIn(whole) && !AD_WORDS.containsMatchIn(whole)
        val allowed = when (pkg) {
            in BANK_APPS, in SMS_APPS -> financial
            in extraPackages() -> financial
            KAKAO -> title in KAKAO_TITLES && !AD_WORDS.containsMatchIn(whole)
            SHELL -> debuggable
            else -> looksLikeTransaction(whole)
        }
        if (!allowed) return

        try {
            val inserted = SQLiteDatabase.openOrCreateDatabase(getDatabasePath("budget.db"), null).use {
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
            // 새로 저장된 알림이면 앱을 열지 않아도 바로 거래로 변환한다.
            if (inserted != -1L) IngestRunner.run(this)
        } catch (_: Exception) {
            // 수집 실패가 서비스를 죽이지 않게 한다. 원문은 다음에 앱을 열 때 처리된다.
        }
    }
}

import 'dart:convert';

import 'package:crypto/crypto.dart';

const bankNotificationApps = {
  'com.nonghyup.nhallonebank',
  'com.kakaobank.channel',
  'viva.republica.toss',
};
const smsNotificationApps = {
  'com.samsung.android.messaging',
  'com.google.android.apps.messaging',
  'com.android.mms',
};

bool protectedNotificationSource(
  String package,
  String title,
  Set<String> extras,
) =>
    bankNotificationApps.contains(package) ||
    smsNotificationApps.contains(package) ||
    extras.contains(package) ||
    (package == 'com.kakao.talk' && title == '삼성카드');

/// 템플릿 이름만 믿지 않고 실제 발신 앱도 함께 검사한다.
bool trustedNotification(String package, String title, String source) =>
    switch (package) {
      'com.nonghyup.nhallonebank' => source == 'nhallone',
      'com.kakaobank.channel' => source == 'kakaobank',
      'viva.republica.toss' => source == 'toss',
      'com.kakao.talk' => title == '삼성카드' && source == 'card',
      _ =>
        smsNotificationApps.contains(package) &&
            (source == 'sms' || source == 'card'),
    };

String notificationKey(
  String package,
  String title,
  String text,
  int postedAt,
) => sha256
    .convert(utf8.encode('$package\u0000$title\u0000$text\u0000$postedAt'))
    .toString();

String normalizedNotificationSnippet(String text) {
  final normalized = text
      .replaceAll(RegExp(r'\d+'), '#')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return normalized.length > 300 ? normalized.substring(0, 300) : normalized;
}

String confirmedTxFilter([String prefix = '']) =>
    "COALESCE(${prefix}status,'ok') NOT IN ('candidate','rejected')";

const notificationReasons = {
  'chat': '친구/개인 대화예요',
  'ad': '광고/이벤트예요',
  'otp': '인증·예정·요청 알림이에요',
  'duplicate': '이미 기록된 거래예요',
  'own_transfer': '내 통장끼리 옮긴 거예요',
  'other': '기타',
};

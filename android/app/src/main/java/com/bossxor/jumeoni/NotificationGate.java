package com.bossxor.jumeoni;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/** 금융 출처 보호는 원문 저장 전에도 적용한다. Android API 없이 검증 가능한 정책. */
public final class NotificationGate {
    public static final Set<String> BANK_APPS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
        "com.nonghyup.nhallonebank", "com.kakaobank.channel", "viva.republica.toss")));
    public static final Set<String> SMS_APPS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
        "com.samsung.android.messaging", "com.google.android.apps.messaging", "com.android.mms")));
    private NotificationGate() {}
    public static boolean isProtected(String pkg, String title, Set<String> extras) {
        return BANK_APPS.contains(pkg) || SMS_APPS.contains(pkg) || extras.contains(pkg)
            || ("com.kakao.talk".equals(pkg) && "삼성카드".equals(title));
    }
}

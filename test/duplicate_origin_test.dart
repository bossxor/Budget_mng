import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/app_state.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/ui/notification_review.dart';
import 'package:jumeoni/ui/theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  testWidgets('같은 거래 후보에 계좌와 원래 알림 원문이 보인다', (tester) async {
    late Database db;
    late Repo repo;
    late AppState state;
    late NotificationReview review;
    late Map<String, ({String package, String text})> origins;
    // sqflite ffi는 실제 비동기라서 위젯 테스트 안에서는 runAsync로 감싼다.
    await tester.runAsync(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      repo = await Repo.fromDb(db);
      state = AppState(repo);
      final now = DateTime.now().millisecondsSinceEpoch;
      // 이미 기록된 입금: 카카오뱅크 알림에서 만들어진 내역과 직접 입력한 내역
      final rawId = await db.insert('raw_notification', {
        'package': 'com.kakaobank.channel',
        'title': '입금 30,000원',
        'text': '홍길동 → 내 입출금통장',
        'posted_at': now,
        'state': 1,
      });
      Future<void> tx(String id, int? raw, String source) => db.insert('tx', {
            'id': id, 'type': 'income', 'amount': 30000, 'counterparty': '홍길동',
            'occurred_at': now, 'account': '카카오뱅크 0001', 'source': source,
            'status': 'ok', 'raw_id': raw, 'dir': 'in', 'updated_at': now,
          });
      await tx('old1', rawId, 'kakaobank');
      await tx('old2', null, 'manual');
      // 새로 들어온 확인 대기 알림
      await db.insert('raw_notification', {
        'package': 'com.example.chat',
        'title': '민수',
        'text': '30,000원 입금했어 ㅎㅎ',
        'posted_at': now + 1000,
      });
      await repo.processPending();
      review = (await repo.notificationReview((await repo.reviewList())
          .where((t) => t.status == 'candidate')
          .single
          .id))!;
      origins = await repo.txOrigins(['old1', 'old2']);
    });
    expect(origins.keys, ['old1']);
    expect(origins['old1']!.text, '입금 30,000원 홍길동 → 내 입출금통장');

    await tester.runAsync(() => tester.pumpWidget(MaterialApp(
        theme: Dsn.theme(Brightness.light, (t) => t),
        home: NotificationReviewScreen(state, review))));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('아니에요'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이미 기록된 거래예요'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.textContaining('홍길동 → 내 입출금통장'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('홍길동 → 내 입출금통장'), findsOneWidget);
    expect(find.textContaining('카카오뱅크 0001 · 카카오뱅크'), findsOneWidget);
    expect(find.textContaining('카카오뱅크 0001 · 직접 입력'), findsOneWidget);
    state.dispose();
    await tester.runAsync(() => db.close());
  });
}

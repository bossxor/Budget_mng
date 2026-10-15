import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/app_state.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/ui/notification_review.dart';
import 'package:jumeoni/ui/theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repo repo;
  late AppState state;
  late NotificationReview review;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    repo = await Repo.fromDb(db);
    state = AppState(repo);
    await db.insert('raw_notification', {
      'package': 'com.example.chat',
      'title': '민수',
      'text': '30,000원 입금했어 ㅎㅎ',
      'posted_at': DateTime.now().millisecondsSinceEpoch,
    });
    await repo.processPending();
    review = (await repo.notificationReview(
      (await repo.reviewList()).single.id,
    ))!;
  });
  tearDown(() async {
    state.dispose();
    await db.close();
  });
  for (final reject in [false, true]) {
    testWidgets(
      reject ? '개인 대화 거절은 이유와 숨김을 저장한다' : '후보 원문을 보여 주고 승인하면 합계에 반영한다',
      (tester) async {
        await tester.runAsync(
          () => tester.pumpWidget(
            MaterialApp(
              theme: Dsn.theme(Brightness.light, (t) => t),
              home: NotificationReviewScreen(state, review),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('30,000원 입금했어'), findsOneWidget);
        expect(
          (await tester.runAsync(() => repo.summary(DateTime.now())))!.income,
          0,
        );
        if (reject) {
          await tester.tap(find.text('아니에요'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('친구/개인 대화예요'));
          await tester.pumpAndSettle();
          await tester.runAsync(() => tester.tap(find.text('이유를 반영하고 학습')));
        } else {
          await tester.runAsync(() => tester.tap(find.text('맞아요, 거래예요')));
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 800)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          (await tester.runAsync(() => repo.summary(DateTime.now())))!.income,
          reject ? 0 : 30000,
        );
        expect(
          (await tester.runAsync(() => db.query('notif_feedback')))!
              .single['verdict'],
          reject ? 'no' : 'fixed',
        );
        if (reject)
          expect(
            await tester.runAsync(() => repo.notificationMuteRules()),
            hasLength(1),
          );
      },
    );
  }
}

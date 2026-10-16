import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/app_state.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/ui/notification_review.dart';
import 'package:jumeoni/ui/auto_posting_screen.dart';
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
      'package': 'com.example.finance',
      'title': '시험 알림',
      'text': '출금: 10000원\n계좌: 시험통장\n내용: 시험커피',
      'posted_at': DateTime.now().millisecondsSinceEpoch,
    });
    await repo.processPending();
    final row = (await db.query('tx')).single;
    await db.update(
      'tx',
      {'category': '카페'},
      where: 'id=?',
      whereArgs: [row['id']],
    );
    review = (await repo.notificationReview(row['id'] as String))!;
  });
  tearDown(() async {
    state.dispose();
    await db.close();
  });
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    await t.pumpAndSettle();
  }

  testWidgets('안내형 확인에서 범위를 확인한 뒤 직접 자동 반영을 지정한다', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: Dsn.theme(Brightness.light, (v) => v),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute(
                  builder: (_) => NotificationReviewScreen(state, review),
                ),
              ),
              child: const Text('시험 내역 열기'),
            ),
          ),
        ),
      ),
    );
    await t.runAsync(() => t.tap(find.text('시험 내역 열기')));
    await settle(t);
    await t.scrollUntilVisible(
      find.text('이 패턴은 지금부터 자동 반영'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(NotificationReviewScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await t.ensureVisible(find.text('이 패턴은 지금부터 자동 반영'));
    await t.pumpAndSettle();
    await t.runAsync(() => t.tap(find.text('이 패턴은 지금부터 자동 반영')));
    await t.pumpAndSettle();
    expect(find.text('이 패턴만 자동 반영할까요?'), findsOneWidget);
    await t.runAsync(() => t.tap(find.text('이 패턴만 자동 반영')));
    await settle(t);
    expect(find.text('시험 내역 열기'), findsOneWidget);
    final patterns = (await t.runAsync(() => repo.autoPatterns()))!;
    expect(patterns.single.enabled, true);
    expect(patterns.single.checked, 1);
    expect(t.takeException(), isNull);
  });
  testWidgets('설정에서 일시중지하면 확인 건수는 보존한다', (t) async {
    final p = (await t.runAsync(
      () => repo.observeAutoProposal(review, type: 'expense', category: '카페'),
    ))!;
    await t.runAsync(
      () => repo.confirmNotification(
        review,
        category: '카페',
        enableAutoPatternKey: p.key,
      ),
    );
    await t.runAsync(
      () => t.pumpWidget(
        MaterialApp(
          theme: Dsn.theme(Brightness.light, (v) => v),
          home: AutoPostingScreen(state),
        ),
      ),
    );
    await settle(t);
    await t.scrollUntilVisible(find.text('자동 반영 일시중지'), 100);
    await t.runAsync(() => t.tap(find.text('자동 반영 일시중지')));
    await settle(t);
    final paused = (await t.runAsync(() => repo.autoProgress(p.key)))!;
    expect(paused.paused, true);
    expect(paused.checked, 1);
    expect(t.takeException(), isNull);
  });
}

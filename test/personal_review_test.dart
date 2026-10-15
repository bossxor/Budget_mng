import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/app_state.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/ui/screens.dart';
import 'package:jumeoni/ui/theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ObservedState extends AppState {
  _ObservedState(super.repo);
  Completer<void>? completed;
  @override
  Future<void> refresh() async {
    await super.refresh();
    if (completed != null && !completed!.isCompleted) completed!.complete();
  }
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late _ObservedState state;
  late TxRow tx;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    state = _ObservedState(await Repo.fromDb(db));
    for (var i = 0; i < 3; i++) {
      await db.insert('tx', {
        'id': 'tx$i',
        'type': 'expense',
        'amount': 300000,
        'merchant': '정기저축',
        'account': '생활비',
        'dir': 'out',
        'occurred_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'ok',
        'source': 'bank',
      });
      if (i < 2) {
        await state.repo.classifyTx('tx$i', type: 'transfer', category: '적금');
      }
    }
    await state.refresh();
    tx = state.rows.firstWhere((r) => r.id == 'tx2');
  });
  tearDown(() async {
    state.dispose();
    await db.close();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Dsn.theme(Brightness.light, (t) => t),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showEditSheet(context, state, tx),
              child: const Text('거래 열기'),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('거래 열기'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  Future<void> settleSave(WidgetTester tester) async {
    for (var i = 0; i < 100 && !state.completed!.isCompleted; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pumpAndSettle();
    expect(state.completed!.isCompleted, true, reason: '화면 저장과 새로고침이 끝나야 한다');
  }

  testWidgets('추천을 확인하고 승인한 뒤 화면을 떠나도 학습을 되돌릴 수 있다', (tester) async {
    await open(tester);
    expect(find.text('분류 도우미'), findsOneWidget);
    expect(find.text('적금으로 보입니다'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('직접 확인한 2건'), 100);
    expect(find.textContaining('직접 확인한 2건'), findsOneWidget);
    state.completed = Completer<void>();
    await tester.tap(find.text('맞아요, 반영하고 학습'));
    await settleSave(tester);
    expect(find.text('거래 열기'), findsOneWidget);
    expect(find.text('분류를 반영하고 학습했어요.'), findsOneWidget);
    expect(await tester.runAsync(() => state.repo.personalExampleCount()), 3);
    state.completed = Completer<void>();
    await tester.tap(find.text('되돌리기'));
    await settleSave(tester);
    expect(await tester.runAsync(() => state.repo.personalExampleCount()), 2);
    expect(state.rows.firstWhere((r) => r.id == 'tx2').type, 'expense');
    expect(tester.takeException(), isNull);
  });

  testWidgets('다른 분류를 고르면 추천 대신 수정한 정답을 배운다', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    await tester.tap(find.text('다른 분류예요'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('이체 목적'));
    await tester.tap(find.text('적금').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('카드대금').last);
    await tester.pumpAndSettle();
    state.completed = Completer<void>();
    await tester.tap(find.text('이 분류로 반영하고 학습'));
    await settleSave(tester);
    expect(state.rows.firstWhere((r) => r.id == 'tx2').category, '카드대금');
    expect(await tester.runAsync(() => state.repo.personalExampleCount()), 3);
    expect(tester.takeException(), isNull);
  });
}

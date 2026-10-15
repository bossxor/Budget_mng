import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/app_state.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/data/budget_repo.dart';
import 'package:jumeoni/ui/screens.dart';
import 'package:jumeoni/ui/theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late AppState state;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    state = AppState(await Repo.fromDb(db));
    state.lastBackupAt = DateTime.now();
    state.month = DateTime(2026, 9);
  });
  tearDown(() async { state.dispose(); await db.close(); });

  Future<void> showHome(WidgetTester tester) => tester.pumpWidget(MaterialApp(
    theme: Dsn.theme(Brightness.light, (t) => t),
    home: Scaffold(body: HomeScreen(state, goHistory: () {})),
  ));

  testWidgets('누락 거래 추가를 취소하면 경고를 보존한다', (tester) async {
    await tester.runAsync(() async {
      await db.insert('gap_alert', {
      'id': 'gap', 'account': 'test', 'amount': 5000,
      'at': DateTime.now().millisecondsSinceEpoch, 'resolved': 0,
    });
      state.gaps = await state.repo.gaps();
    });
    await showHome(tester);
    await tester.tap(find.text('추가'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('저장'))).pop();
    await tester.pumpAndSettle();
    final gaps = await tester.runAsync(() => state.repo.gaps());
    expect(gaps, hasLength(1));
    expect(find.text('알림이 빠진 것 같아요'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('좁은 화면에서도 큰 지출 금액과 선택한 월을 표시한다', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state.summary = MonthSummary(1234567890, 0, {}, 0);
    await showHome(tester);
    await tester.pumpAndSettle();
    expect(find.text('9월 쓴 돈'), findsOneWidget);
    expect(find.text('1,234,567,890원'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('큰 글자와 작은 화면에서도 예산 안내가 넘치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state.month = DateTime.now();
    state.summary = MonthSummary(1300000, 3000000, {}, 0);
    state.budgetLines = [BudgetLine(null, 1500000, 1300000)];
    state.rows = [TxRow('test', 'expense', 1300000, '지출', '식비',
      DateTime.now().subtract(const Duration(minutes: 1)), null, 'ok', null)];
    await tester.pumpWidget(MaterialApp(
      theme: Dsn.theme(Brightness.dark, (t) => t),
      home: MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: Scaffold(body: HomeScreen(state, goHistory: () {}))),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('선택한 달 예산'), 150);
    expect(tester.takeException(), isNull);
  });
  testWidgets('저장 버튼은 시스템 하단 바 위에 놓인다', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(onPressed: () => showManualEntry(context, state),
        child: const Text('입력 열기'))))));
    await tester.tap(find.text('입력 열기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(find.widgetWithText(FilledButton, '저장')).dy, lessThanOrEqualTo(766));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    tester.view.padding = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('저장'));
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(find.widgetWithText(FilledButton, '저장')).dy, lessThanOrEqualTo(500));
    expect(tester.takeException(), isNull);
  });
}

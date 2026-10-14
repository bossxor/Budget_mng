import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/budget_repo.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/data/settlement_repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  BudgetForecast? forecast(DateTime date, int spent, {int limit = 1000000, DateTime? month}) =>
    BudgetForecast.calculate(month: month ?? date, now: date, limit: limit, spent: spent);
  test('예상: 경과일, 월말, 윤년, 지난달과 월초', () {
    expect(forecast(DateTime(2026, 10, 10), 400000)!.projected, 1240000);
    expect(forecast(DateTime(2026, 10, 10), 400000)!.excess, 240000);
    expect(forecast(DateTime(2026, 10, 31), 900000)!.excess, 0);
    expect(forecast(DateTime(2028, 2, 10), 100000)!.projected, 290000);
    expect(forecast(DateTime(2026, 10, 2), 400000), isNull);
    expect(forecast(DateTime(2026, 10, 14), 0), isNull);
    expect(forecast(DateTime(2026, 10, 14), -1000), isNull);
    expect(forecast(DateTime(2026, 10, 14), 1000, limit: 0), isNull);
    expect(forecast(DateTime(2026, 10, 14), 1000, month: DateTime(2026, 9)), isNull);
  });
  sqfliteFfiInit();
  test('위젯: 정산 몫, 환불, 미래 거래 제외와 예산 삭제를 반영한다', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    final repo = await Repo.fromDb(db);
    final now = DateTime(2026, 10, 14, 12);
    await repo.budget.setBudget(null, 100000);
    await repo.addManual(type: 'expense', amount: 60000, title: '모임', at: DateTime(2026, 10, 5));
    final meal = (await repo.monthTx(now)).single;
    await repo.settlements.create(title: '모임', txIds: [meal.id],
      shares: [ShareInput(null, 20000), ShareInput('친구', 40000)]);
    await repo.addManual(type: 'expense', amount: -5000, title: '환불', at: DateTime(2026, 10, 6));
    await repo.addManual(type: 'expense', amount: 90000, title: '미래', at: DateTime(2026, 10, 30));
    await repo.addManual(type: 'transfer', amount: 10000, title: '이체', at: DateTime(2026, 10, 6));
    await repo.writeWidgetSnapshot(now: now);
    var data = jsonDecode((await repo.getKv('widget_snapshot'))!) as Map<String, dynamic>;
    expect(data['spent'], 15000);
    expect(data['limit'], 100000);
    expect(data['month'], 10);
    await repo.budget.setBudget(null, null);
    await repo.writeWidgetSnapshot(now: now);
    data = jsonDecode((await repo.getKv('widget_snapshot'))!);
    expect(data['limit'], isNull);
    await repo.writeWidgetSnapshot(now: DateTime(2026, 11, 1));
    data = jsonDecode((await repo.getKv('widget_snapshot'))!);
    expect(data['month'], 11);
    expect(data['spent'], 0);
  });
}

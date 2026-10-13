import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repo repo;
  final now = DateTime(2026, 10, 14, 12);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    repo = await Repo.fromDb(db);
  });

  var n = 0;
  Future<void> spend(String merchant, int amount, DateTime at) => db.insert('tx', {
        'id': 'b${n++}',
        'type': 'expense',
        'amount': amount,
        'merchant': merchant,
        'occurred_at': at.millisecondsSinceEpoch,
        'status': 'ok',
      });

  test('예산 저장, 삭제, 사용률 정렬', () async {
    await repo.budget.setBudget(null, 1000000);
    await repo.budget.setBudget('카페', 50000);
    await repo.budget.setBudget('식비', 300000);
    final st = await repo.budget.status(400000, {'카페': 60000, '식비': 150000});
    expect(st.first.category, isNull);
    expect(st.first.left, 600000);
    expect(st[1].category, '카페'); // 120%로 가장 높음
    expect(st[1].ratio, closeTo(1.2, 0.001));
    expect(st[2].category, '식비');

    await repo.budget.setBudget('카페', 0);
    await repo.budget.setBudget(null, null);
    expect((await repo.budget.budgets()).keys, ['식비']);
  });

  test('고정지출: 같은 가맹점, 5% 이내 금액, 3개월 연속', () async {
    for (final m in [7, 8, 9, 10]) {
      await spend('넷플릭스', 17000, DateTime(2026, m, 5));
    }
    // 금액이 크게 달라지면 반복으로 보지 않는다.
    await spend('쿠팡', 30000, DateTime(2026, 8, 3));
    await spend('쿠팡', 90000, DateTime(2026, 9, 3));
    await spend('쿠팡', 15000, DateTime(2026, 10, 3));
    // 두 달뿐이면 아직 아니다.
    await spend('헬스장', 50000, DateTime(2026, 9, 20));
    await spend('헬스장', 50000, DateTime(2026, 10, 20));
    // 지난달까지 이어졌으면 이번 달 결제 전이어도 잡는다. 금액 4% 차이.
    await spend('통신비', 55000, DateTime(2026, 7, 25));
    await spend('통신비', 55000, DateTime(2026, 8, 25));
    await spend('통신비', 57000, DateTime(2026, 9, 25));

    final r = await repo.budget.recurring(now: now);
    expect(r.map((x) => x.name).toSet(), {'넷플릭스', '통신비'});
    final net = r.firstWhere((x) => x.name == '넷플릭스');
    expect(net.months, 4);
    expect(net.nextDate, DateTime(2026, 11, 5));
    final tel = r.firstWhere((x) => x.name == '통신비');
    expect(tel.amount, 57000);
    expect(tel.nextDate, DateTime(2026, 10, 25));
  });

  test('다음 예상일은 짧은 달의 말일로 맞춘다', () async {
    await spend('보험', 30000, DateTime(2025, 11, 30));
    await spend('보험', 30000, DateTime(2025, 12, 31));
    await spend('보험', 30000, DateTime(2026, 1, 31));
    final r = await repo.budget.recurring(now: DateTime(2026, 2, 3));
    expect(r.single.nextDate, DateTime(2026, 2, 28));
  });
}

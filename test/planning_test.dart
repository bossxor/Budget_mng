import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repo repo;
  final now = DateTime.now();
  final month = DateTime(now.year, now.month);
  int at(int day, [int h = 10, int m = 0]) =>
      DateTime(month.year, month.month, day, h, m).millisecondsSinceEpoch;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    repo = await Repo.fromDb(db);
    await db.insert('account',
        {'key': '입출금통장(0001)', 'label': '생활비 통장', 'role': 'living'});
    await db.insert('account',
        {'key': '26주적금(0002)', 'label': '26주 적금', 'role': 'saving'});
  });

  var n = 0;
  Future<void> transfer(String dir, int amount, String account, String cp,
      int time) async {
    await db.insert('tx', {
      'id': 't${n++}',
      'type': 'transfer',
      'dir': dir,
      'amount': amount,
      'counterparty': cp,
      'account': account,
      'occurred_at': time,
      'status': 'ok',
    });
  }

  test('저축 통장으로 가는 이체는 저축, 같은 이체의 양쪽 알림은 한 번만 센다', () async {
    await transfer('out', 66000, '입출금통장(0001)', '26주적금(0002)', at(5));
    await transfer('in', 66000, '26주적금(0002)', '입출금통장(0001)', at(5, 10, 1));
    await transfer('out', 20000, '입출금통장(0001)', '다른 내 계좌', at(6));
    final s = await repo.planning.savings(month);
    expect(s.saved, 66000);
    expect(s.withdrawn, 0);
  });

  test('저축 통장에서 빠져나간 돈은 인출로 차감', () async {
    await transfer('out', 100000, '입출금통장(0001)', '26주적금(0002)', at(2));
    await transfer('out', 30000, '26주적금(0002)', '입출금통장(0001)', at(8));
    final s = await repo.planning.savings(month);
    expect(s.saved, 100000);
    expect(s.withdrawn, 30000);
    expect(s.net, 70000);
  });

  test('배분 계획 이행 여부와 지연 판정', () async {
    await repo.planning.addPlan('입출금통장(0001)', '26주적금(0002)', 66000, 10);
    await repo.planning.addPlan('입출금통장(0001)', '여행비 통장', 200000, 10);
    await transfer('out', 66000, '입출금통장(0001)', '26주적금(0002)', at(3));

    final late = await repo.planning
        .status(month, now: DateTime(month.year, month.month, 20));
    final saving = late.firstWhere((s) => s.plan.toKey == '26주적금(0002)');
    final travel = late.firstWhere((s) => s.plan.toKey == '여행비 통장');
    expect(saving.done, isTrue);
    expect(saving.overdue, isFalse);
    expect(travel.done, isFalse);
    expect(travel.overdue, isTrue);
    expect(travel.remaining, 200000);

    final early = await repo.planning
        .status(month, now: DateTime(month.year, month.month, 5));
    expect(early.firstWhere((s) => s.plan.toKey == '여행비 통장').overdue, isFalse);
  });

  test('목표/카드 결제통장 설정이 저장된다', () async {
    await repo.setAccountGoal('26주적금(0002)',
        goalAmount: 1000000,
        goalDate: DateTime(2027, 6, 1),
        monthlyTarget: 66000);
    final a = (await repo.accounts()).firstWhere((x) => x.key == '26주적금(0002)');
    expect(a.goalAmount, 1000000);
    expect(a.monthlyTarget, 66000);
    expect(a.goalDate!.year, 2027);
  });
}

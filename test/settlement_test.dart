import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/data/settlement_repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Repo repo;
  final month = DateTime.now();
  final thisMonth = DateTime(month.year, month.month);

  setUp(() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    repo = await Repo.fromDb(db);
  });

  Future<TxRow> tx(String type, int amount, String title, {int day = 1}) async {
    await repo.addManual(
        type: type,
        amount: amount,
        title: title,
        at: DateTime(thisMonth.year, thisMonth.month, day, 12));
    final rows = await repo.monthTx(thisMonth);
    return rows.firstWhere((t) => t.title == title);
  }

  test('내 몫만 지출로 잡히고 정산 입금은 수입에서 빠진다', () async {
    final a = await tx('expense', 150000, '1차 고깃집', day: 2);
    final b = await tx('expense', 80000, '2차 호프', day: 2);
    final d1 = await tx('income', 57500, '김민수', day: 3);
    final d2 = await tx('income', 57500, '이지훈', day: 3);
    await tx('income', 30000, '용돈', day: 4);

    final id = await repo.settlements.create(
      title: '1·2차 회식',
      txIds: [a.id, b.id],
      shares: [
        ShareInput(null, 57500),
        ShareInput('김민수', 57500),
        ShareInput('이지훈', 57500),
        ShareInput('박서연', 57500),
      ],
    );

    var s = await repo.summary(thisMonth);
    expect(s.expense, 57500); // 230,000이 아니라 내 몫만
    expect(s.income, 57500 + 57500 + 30000); // 아직 연결 전

    var st = (await repo.settlements.get(id))!;
    expect(st.total, 230000);
    expect(st.toReceive, 172500);
    expect(st.status, 'open');

    // 입금 연결: 김민수, 이지훈
    final kim = st.shares.firstWhere((x) => x.name == '김민수');
    final lee = st.shares.firstWhere((x) => x.name == '이지훈');
    final c1 = (await repo.settlements.candidates('김민수'))
        .firstWhere((c) => c.tx.id == d1.id);
    expect(c1.nameMatch, isTrue);
    await repo.settlements.pay(kim, c1, 57500);
    final c2 = (await repo.settlements.candidates('이지훈'))
        .firstWhere((c) => c.tx.id == d2.id);
    await repo.settlements.pay(lee, c2, 57500);

    st = (await repo.settlements.get(id))!;
    expect(st.received, 115000);
    expect(st.outstanding, 57500);
    expect(st.status, 'partial');

    s = await repo.summary(thisMonth);
    expect(s.income, 30000); // 정산 입금은 수입이 아니다
    expect(s.expense, 57500);
  });

  test('한 번에 합쳐 보낸 입금을 두 정산에 나눠 연결', () async {
    final e1 = await tx('expense', 20000, '점심', day: 5);
    final e2 = await tx('expense', 30000, '저녁', day: 6);
    final dep = await tx('income', 25000, '박서연', day: 7);
    final s1 = await repo.settlements.create(
        title: '점심', txIds: [e1.id], shares: [ShareInput(null, 10000), ShareInput('박서연', 10000)]);
    final s2 = await repo.settlements.create(
        title: '저녁', txIds: [e2.id], shares: [ShareInput(null, 15000), ShareInput('박서연', 15000)]);

    final sh1 = (await repo.settlements.get(s1))!.others.first;
    final sh2 = (await repo.settlements.get(s2))!.others.first;
    var cand = (await repo.settlements.candidates('박서연')).firstWhere((c) => c.tx.id == dep.id);
    await repo.settlements.pay(sh1, cand, 10000);
    cand = (await repo.settlements.candidates('박서연')).firstWhere((c) => c.tx.id == dep.id);
    expect(cand.free, 15000);
    await repo.settlements.pay(sh2, cand, 15000);

    expect((await repo.settlements.get(s1))!.status, 'done');
    expect((await repo.settlements.get(s2))!.status, 'done');
    expect((await repo.summary(thisMonth)).income, 0);
  });

  test('이름이 다른 입금을 연결하면 별칭이 학습된다', () async {
    final e = await tx('expense', 40000, '택시', day: 8);
    final dep = await tx('income', 20000, '박서연엄마', day: 9);
    final id = await repo.settlements.create(
        title: '택시', txIds: [e.id], shares: [ShareInput(null, 20000), ShareInput('박서연', 20000)]);
    final sh = (await repo.settlements.get(id))!.others.first;
    final cand = (await repo.settlements.candidates('박서연')).firstWhere((c) => c.tx.id == dep.id);
    await repo.settlements.pay(sh, cand, 20000);
    final p = (await repo.settlements.people()).firstWhere((x) => x.name == '박서연');
    expect(p.aliases, contains('박서연엄마'));
  });

  test('정산을 지우면 지출과 입금이 원래대로 돌아온다', () async {
    final e = await tx('expense', 40000, '술집', day: 10);
    final id = await repo.settlements.create(
        title: '술집', txIds: [e.id], shares: [ShareInput(null, 20000), ShareInput('박서연', 20000)]);
    expect((await repo.summary(thisMonth)).expense, 20000);
    await repo.settlements.delete(id);
    expect((await repo.summary(thisMonth)).expense, 40000);
  });

  test('입금 추천: 이름 일치 우선, 이름이 달라도 금액이 유일하게 맞으면 추천', () async {
    final e = await tx('expense', 90000, '회식', day: 11);
    await tx('income', 30000, '박서연', day: 12);
    await tx('income', 45000, '누군가', day: 12);
    await repo.settlements.create(title: '회식', txIds: [e.id], shares: [
      ShareInput(null, 15000),
      ShareInput('박서연', 30000),
      ShareInput('김철수', 45000),
    ]);
    final sug = await repo.settlements.suggestions();
    expect(sug.length, 2);
    final seo = sug.firstWhere((x) => x.share.name == '박서연');
    expect(seo.byName, isTrue);
    expect(seo.amount, 30000);
    final kim = sug.firstWhere((x) => x.share.name == '김철수');
    expect(kim.byName, isFalse);
    expect(kim.deposit.tx.title, '누군가');
  });

  test('이미 연결한 입금은 다시 추천하지 않는다', () async {
    final e = await tx('expense', 20000, '커피', day: 13);
    await tx('income', 10000, '이지훈', day: 13);
    await repo.settlements.create(title: '커피', txIds: [e.id], shares: [
      ShareInput(null, 10000),
      ShareInput('이지훈', 10000),
    ]);
    final g = (await repo.settlements.suggestions()).single;
    await repo.settlements.pay(g.share, g.deposit, g.amount);
    expect(await repo.settlements.suggestions(), isEmpty);
  });
}

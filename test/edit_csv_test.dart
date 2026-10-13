import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/extras.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/data/settlement_repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Repo repo;
  final month = DateTime(2026, 10);

  setUp(() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    repo = await Repo.fromDb(db);
  });

  Future<TxRow> add(String type, int amount, String title, int day) async {
    await repo.addManual(
        type: type, amount: amount, title: title, at: DateTime(2026, 10, day, 12));
    return (await repo.monthTx(month)).firstWhere((t) => t.title == title);
  }

  test('거래 수정: 이름, 금액, 날짜, 메모. 메모는 검색된다', () async {
    final t = await add('expense', 5000, '편의점', 3);
    await repo.updateTx(t.id,
        title: '편의점 간식', amount: 6500, at: DateTime(2026, 10, 4, 9), note: '야근 간식');
    final u = (await repo.monthTx(month)).single;
    expect(u.title, '편의점 간식');
    expect(u.amount, 6500);
    expect(u.occurredAt, DateTime(2026, 10, 4, 9));
    expect(u.note, '야근 간식');
    expect((await repo.tags.search(text: '야근')).single.id, t.id);

    await repo.updateTx(t.id, note: '  ');
    expect((await repo.monthTx(month)).single.note, isNull);
    // 검토 표시(memo)는 그대로 둔다.
    expect((await repo.summary(month)).expense, 6500);
  });

  test('CSV: BOM, 쉼표/따옴표 이스케이프, 정산 몫 반영', () async {
    final a = await add('expense', 40000, '고기, "1차"', 5);
    await add('income', 2000000, '월급', 1);
    await repo.updateTx(a.id, note: '팀 회식');
    await repo.settlements.create(
        title: '회식', txIds: [a.id], shares: [ShareInput(null, 20000), ShareInput('김민수', 20000)]);

    final csv = await exportCsv(repo, month: month);
    expect(csv.startsWith('﻿날짜,유형,금액,가계부 반영,내용,카테고리,계좌,메모'), isTrue);
    final lines = csv.trim().split('\r\n');
    expect(lines.length, 3);
    expect(lines[1], startsWith('2026-10-01 12:00,입금,2000000,2000000,월급'));
    expect(lines[2], '2026-10-05 12:00,지출,40000,20000,"고기, ""1차""",,현금,팀 회식');

    // 다른 달만 고르면 비어 있다.
    final none = await exportCsv(repo, month: DateTime(2026, 9));
    expect(none.trim().split('\r\n').length, 1);
    // 전체 기간
    expect((await exportCsv(repo)).trim().split('\r\n').length, 3);
  });
}

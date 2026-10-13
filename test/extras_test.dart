import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/backup.dart';
import 'package:jumeoni/data/report.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repo repo;
  final now = DateTime.now();
  final month = DateTime(now.year, now.month);
  int at(int day, [int h = 12]) =>
      DateTime(month.year, month.month, day, h).millisecondsSinceEpoch;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    repo = await Repo.fromDb(db);
  });

  Future<void> raw(String title, String text, int postedAt,
      {String pkg = 'com.kakaobank.channel'}) async {
    await db.insert('raw_notification',
        {'package': pkg, 'title': title, 'text': text, 'posted_at': postedAt, 'state': 0});
  }

  test('잔액이 이어지지 않으면 누락 알림이 생긴다', () async {
    await raw('입금 1,000원', '김철수 → 입출금통장(0001)\n잔액 11,000원', at(2, 9));
    await raw('입금 500원', '김철수 → 입출금통장(0001)\n잔액 11,500원', at(3, 9)); // 정상
    await raw('입금 500원', '이영희 → 입출금통장(0001)\n잔액 20,000원', at(4, 9)); // 8,000원 빠짐
    expect(await repo.processPending(), 3);
    final g = await repo.gaps();
    expect(g.length, 1);
    expect(g.first.amount, 8000);
    expect(g.first.account, '입출금통장(0001)');
    await repo.resolveGap(g.first.id);
    expect(await repo.gaps(), isEmpty);
  });

  test('같은 알림을 두 번 처리하지 않는다 (선점)', () async {
    await raw('입금 1,000원', '김철수 → 입출금통장(0001)\n잔액 11,000원', at(2, 9));
    final a = repo.processPending();
    final b = repo.processPending();
    expect((await a) + (await b), 1);
    expect(await db.query('tx'), hasLength(1));
  });

  test('분할된 결제는 카테고리별로 집계된다', () async {
    await repo.addManual(
        type: 'expense', amount: 80000, title: '쿠팡', category: '쇼핑', at: DateTime(month.year, month.month, 5, 12));
    final t = (await repo.monthTx(month)).single;
    await repo.saveSplits(t.id, [
      TxSplit('생활', 50000),
      TxSplit('식비', 30000),
    ]);
    final s = await repo.summary(month);
    expect(s.expense, 80000);
    expect(s.byCategory['생활'], 50000);
    expect(s.byCategory['식비'], 30000);
    expect(s.byCategory.containsKey('쇼핑'), isFalse);
    await repo.saveSplits(t.id, []);
    expect((await repo.summary(month)).byCategory['쇼핑'], 80000);
  });

  test('태그와 검색', () async {
    await repo.addManual(type: 'expense', amount: 12000, title: '제주 흑돼지', category: '식비', at: DateTime(month.year, month.month, 6, 12));
    await repo.addManual(type: 'expense', amount: 3000, title: '편의점', at: DateTime(month.year, month.month, 7, 12));
    final rows = await repo.monthTx(month);
    final jeju = rows.firstWhere((t) => t.title == '제주 흑돼지');
    await repo.tags.setTags(jeju.id, ['#제주여행', ' ', '맛집']);
    expect(await repo.tags.tagsOf(jeju.id), ['맛집', '제주여행']);
    expect((await repo.tags.allTags()).keys, containsAll(['제주여행', '맛집']));

    expect((await repo.tags.search(tag: '제주여행')).single.title, '제주 흑돼지');
    expect((await repo.tags.search(text: '흑돼지')).length, 1);
    expect((await repo.tags.search(text: '맛집')).length, 1); // 태그 텍스트로도 검색
    expect((await repo.tags.search(minAmount: 5000)).length, 1);
    expect((await repo.tags.search(maxAmount: 5000)).single.title, '편의점');
  });

  test('월말 결산: 전월 대비와 가맹점 Top', () async {
    final prev = DateTime(month.year, month.month - 1, 10, 12);
    await repo.addManual(type: 'expense', amount: 50000, title: '스타벅스', at: prev);
    await repo.addManual(type: 'expense', amount: 30000, title: '스타벅스', at: DateTime(month.year, month.month, 3, 9));
    await repo.addManual(type: 'expense', amount: 90000, title: '마트', category: '생활', at: DateTime(month.year, month.month, 4, 9));
    await repo.addManual(type: 'income', amount: 1000000, title: '월급', at: DateTime(month.year, month.month, 1, 9));
    final r = await buildReport(repo, month);
    expect(r.expense, 120000);
    expect(r.prevExpense, 50000);
    expect(r.expenseDelta, 70000);
    expect(r.income, 1000000);
    expect(r.topMerchants.first.name, '마트');
    expect(r.biggestDayAmount, 90000);
    final cafe = r.categories.firstWhere((c) => c.category == '카페');
    expect(cafe.previous, 50000);
    expect(cafe.delta, -20000);
  });

  test('원문 보관 기간이 지난 처리 완료 알림만 지운다', () async {
    final old = DateTime.now().subtract(const Duration(days: 200)).millisecondsSinceEpoch;
    await db.insert('raw_notification',
        {'package': 'p', 'title': '', 'text': 'old-done', 'posted_at': old, 'state': 1});
    await db.insert('raw_notification',
        {'package': 'p', 'title': '', 'text': 'old-pending', 'posted_at': old, 'state': 0});
    await db.insert('raw_notification', {
      'package': 'p',
      'title': '',
      'text': 'new',
      'posted_at': DateTime.now().millisecondsSinceEpoch,
      'state': 1
    });
    expect(await repo.purgeRaw(90), 1);
    expect(await repo.purgeRaw(0), 0); // 무기한
    final left = (await db.query('raw_notification')).map((r) => r['text']).toSet();
    expect(left, {'old-pending', 'new'});
  });

  test('암호화 백업을 복원하면 데이터가 병합되고 PIN은 빠진다', () async {
    await repo.addManual(type: 'expense', amount: 4500, title: '커피', at: DateTime(month.year, month.month, 2, 8));
    await repo.setKv('font', 'nanum');
    await repo.setKv('lock_hash', 'SECRET');
    final data = await exportData(db);
    expect(data.toString().contains('SECRET'), isFalse);
    final file = await encryptBackup(data, 'correct horse');

    // 같은 파일 형식이어야 하고 잘못된 암호는 거부된다.
    expect(() => decryptBackup(file, 'wrong'), throwsA(isA<BackupError>()));
    expect(() => decryptBackup(Uint8List.fromList([1, 2, 3]), 'x'), throwsA(isA<BackupError>()));

    final db2 = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    final repo2 = await Repo.fromDb(db2);
    final restored = await decryptBackup(file, 'correct horse');
    expect(await importData(db2, restored), 1);
    expect((await repo2.monthTx(month)).single.title, '커피');
    expect(await repo2.getKv('font'), 'nanum');
    expect(await repo2.getKv('lock_hash'), isNull);
    // 다시 복원해도 중복되지 않는다.
    expect(await importData(db2, restored), 0);
    expect(await repo2.monthTx(month), hasLength(1));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
void main() {
  sqfliteFfiInit();
  test('수집 결과는 반영 완료와 검토/인식 실패를 나누고 재처리는 조용하다', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    final repo = await Repo.fromDb(db);
    await repo.setKv('extra_packages', 'com.example.bank');
    final at = DateTime(2026, 10, 15, 12).millisecondsSinceEpoch;
    await db.insert('raw_notification', {'package': 'com.kakaobank.channel',
      'title': '입금 1,000원', 'text': '김철수 → 입출금통장(0001)\n잔액 11,000원', 'posted_at': at});
    await db.insert('raw_notification', {'package': 'com.example.bank',
      'title': '', 'text': '출금 3,500원 분류없는거래처', 'posted_at': at + 600000});
    await db.insert('raw_notification', {'package': 'com.example.bank',
      'title': '', 'text': '입금 알림을 확인해주세요', 'posted_at': at + 1200000});
    var saved = 0, review = 0;
    await repo.runBackgroundIngest(onComplete: (s, r) { saved = s; review = r; });
    expect(saved, 1);
    expect(review, 2);
    var called = false;
    expect(await repo.runBackgroundIngest(onComplete: (_, _) => called = true), 0);
    expect(called, isFalse);
  });
}

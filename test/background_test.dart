import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('백그라운드 처리는 거래를 만들고 시각과 건수를 남긴다', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    final repo = await Repo.fromDb(db);
    final t0 = DateTime(2026, 10, 14, 9, 0);

    expect(await repo.getKv('bg_last_run'), isNull);

    await db.insert('raw_notification', {
      'package': 'com.kakaobank.channel',
      'title': '입금 1,000원',
      'text': '김철수 → 입출금통장(0001)\n잔액 11,000원',
      'posted_at': t0.millisecondsSinceEpoch,
      'state': 0,
    });
    expect(await repo.runBackgroundIngest(now: t0), 1);
    expect(await repo.getKv('bg_last_run'), '${t0.millisecondsSinceEpoch}');
    expect(await repo.getKv('bg_last_saved'), '1');
    expect(await repo.getKv('bg_total_saved'), '1');
    expect(await db.query('tx'), hasLength(1));

    // 처리할 게 없어도 실행 기록은 갱신되고 누계는 유지된다.
    final t1 = t0.add(const Duration(minutes: 5));
    expect(await repo.runBackgroundIngest(now: t1), 0);
    expect(await repo.getKv('bg_last_run'), '${t1.millisecondsSinceEpoch}');
    expect(await repo.getKv('bg_last_saved'), '0');
    expect(await repo.getKv('bg_total_saved'), '1');
  });
}

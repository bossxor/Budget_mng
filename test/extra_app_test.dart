import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('직접 추가한 앱의 알림은 템플릿 없이 금액/방향만 짐작해 저장한다', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    final repo = await Repo.fromDb(db);
    await repo.setKv('extra_packages', 'com.example.bank');
    var t = 1;
    Future<void> add(String pkg, String text) => db.insert('raw_notification',
        {'package': pkg, 'title': '', 'text': text, 'posted_at': t++, 'state': 0});
    await add('com.example.bank', '[예시은행] 입금 12,000원 홍길동');
    await add('com.example.bank', '[예시은행] 출금 3,500원 GS25');
    await add('com.example.bank', '[예시은행] 승인취소 3,500원 GS25'); // 방향 불명 -> 남김
    await add('com.other.app', '[타앱] 입금 9,000원'); // 추가 안 한 앱 -> 남김
    expect(await repo.processPending(), 2);
    final tx = await db.query('tx', columns: ['type', 'amount'], orderBy: 'amount');
    expect(tx.map((r) => '${r['type']}:${r['amount']}'),
        ['expense:3500', 'income:12000']);
    expect((await db.query('raw_notification', where: 'state=2')).length, 2);
  });
}

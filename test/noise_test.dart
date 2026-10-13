import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('광고/비금융 실패 원문만 지우고 금융 알림은 남긴다', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    final repo = await Repo.fromDb(db);
    Future<void> add(String text, int state) => db.insert('raw_notification', {
          'package': 'p',
          'title': '',
          'text': text,
          'posted_at': text.hashCode,
          'state': state,
        });
    await add('(광고) 클릭 시 1,000P 증정 결제 혜택', 2); // 광고 -> 삭제
    await add('앱에서 확인해 보세요 * 알림끄기 : 설정', 2); // 마케팅 -> 삭제
    await add('오늘 날씨가 좋아요', 2); // 금융 키워드 없음 -> 삭제
    await add('입금 5,000원 미등록 포맷', 2); // 금융 알림인데 파서가 못 읽음 -> 남김
    await add('출금 3,000원', 1); // 처리 완료 -> 건드리지 않음
    expect(await repo.purgeNoise(), 3);
    final left = (await db.query('raw_notification', columns: ['text']))
        .map((r) => r['text'])
        .toSet();
    expect(left, {'입금 5,000원 미등록 포맷', '출금 3,000원'});
  });
}

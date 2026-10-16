import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/data/backup.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repo repo;
  var seq = 0;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    repo = await Repo.fromDb(db);
    seq = 0;
  });
  tearDown(() async => db.close());
  Future<NotificationReview> receive({
    String package = 'com.example.finance',
    String account = '테스트통장',
    String party = '시험상점',
    int amount = 10000,
  }) async {
    final id = await db.insert('raw_notification', {
      'package': package,
      'title': '테스트 알림',
      'text': '출금: $amount원\n계좌: $account\n내용: $party',
      'posted_at': DateTime.now().millisecondsSinceEpoch + seq++ * 600000,
    });
    await repo.processPending();
    return (await repo.notificationReview(
      (await db.query('tx', where: 'raw_id=?', whereArgs: [id])).single['id']
          as String,
    ))!;
  }

  Future<String> teach({bool wrong = false}) async {
    final r = await receive();
    final p = (await repo.observeAutoProposal(
      r,
      type: 'expense',
      category: '생활',
    ))!;
    await repo.confirmNotification(
      r,
      type: 'expense',
      category: '생활',
      amount: wrong ? r.tx.amount + 1 : null,
    );
    return p.key;
  }

  test('최근 10건 중 9건 일치·최근 5건 연속 일치 후에만 제안한다', () async {
    final key = await teach(wrong: true);
    for (var i = 0; i < 8; i++) {
      await teach();
    }
    expect((await repo.autoProgress(key)).ready, false);
    await expectLater(repo.setAutoPosting(key, true), throwsStateError);
    await teach();
    final progress = await repo.autoProgress(key);
    expect(progress.checked, 10);
    expect(progress.correct, 9);
    expect(progress.streak, 9);
    expect(progress.ready, true);
    expect(progress.enabled, false);
    await repo.setAutoPosting(key, true);
    expect((await repo.autoProgress(key)).enabled, true);
  });
  test('마지막 답변이 틀리면 9/10이어도 보류하고 최근 10건 창을 이동한다', () async {
    final key = await teach();
    for (var i = 0; i < 8; i++) {
      await teach();
    }
    await teach(wrong: true);
    expect((await repo.autoProgress(key)).correct, 9);
    expect((await repo.autoProgress(key)).ready, false);
    for (var i = 0; i < 5; i++) {
      await teach();
    }
    expect((await repo.autoProgress(key)).ready, true);
  });
  test('직접 지정은 현재 거래 승인과 원자적으로 처리하고 새 금액을 그대로 읽는다', () async {
    final r = await receive();
    final p = (await repo.observeAutoProposal(
      r,
      type: 'expense',
      category: '생활',
    ))!;
    await expectLater(
      repo.setAutoPosting(p.key, true, manual: true),
      throwsStateError,
    );
    await repo.confirmNotification(
      r,
      type: 'expense',
      category: '생활',
      enableAutoPatternKey: p.key,
    );
    expect((await repo.autoProgress(p.key)).enabled, true);
    final samples = await repo.personalExampleCount();
    final next = await receive(amount: 23000);
    expect(next.tx.status, 'ok');
    expect(next.tx.amount, 23000);
    expect(next.tx.category, '생활');
    expect(await repo.personalExampleCount(), samples);
    expect((await repo.autoProgress(p.key)).checked, 1);
    expect((await repo.personalSuggestions()).containsKey(next.tx.id), false);
    expect(
      await db.query(
        'notif_feedback',
        where: 'tx_id=?',
        whereArgs: [next.tx.id],
      ),
      isEmpty,
    );
    expect(await repo.tryAutoPost(next.tx.id), false);
  });
  test('출처·통장·문구가 달라지면 자동 반영하지 않는다', () async {
    final key = await teach();
    await repo.setAutoPosting(key, true, manual: true);
    expect(
      (await receive(package: 'com.example.other')).tx.status,
      'candidate',
    );
    expect((await receive(account: '다른테스트통장')).tx.status, 'candidate');
    expect((await receive(party: '다른시험상점')).tx.status, 'candidate');
  });
  test('자동 반영을 되돌리면 후보로 복귀하고 패턴을 멈춘다', () async {
    final key = await teach();
    await repo.setAutoPosting(key, true, manual: true);
    final r = await receive();
    expect(r.tx.status, 'ok');
    expect(await repo.undoClassification(r.tx.id), true);
    expect((await repo.notificationReview(r.tx.id))!.tx.status, 'candidate');
    expect((await repo.autoProgress(key)).enabled, false);
    expect((await receive()).tx.status, 'candidate');
  });
  test('자동 반영 내역 수정·삭제는 패턴을 멈춘다', () async {
    final key = await teach();
    await repo.setAutoPosting(key, true, manual: true);
    final r = await receive();
    await repo.updateTx(r.tx.id, amount: 8000);
    expect((await repo.autoProgress(key)).enabled, false);
    await repo.setAutoPosting(key, true, manual: true);
    final next = await receive();
    await repo.delete(next.tx.id);
    expect((await repo.autoProgress(key)).enabled, false);
  });
  test('승인 되돌리기는 관찰 결과를 오답으로 바꾸고 반복 열기는 중복 집계하지 않는다', () async {
    final r = await receive();
    final p = (await repo.observeAutoProposal(
      r,
      type: 'expense',
      category: '생활',
    ))!;
    await repo.observeAutoProposal(r, type: 'expense', category: '생활');
    await repo.confirmNotification(r, type: 'expense', category: '생활');
    expect((await repo.autoProgress(p.key)).checked, 1);
    expect((await repo.autoProgress(p.key)).correct, 1);
    expect(await repo.undoClassification(r.tx.id), true);
    expect((await repo.autoProgress(p.key)).correct, 0);
  });
  test('백업은 학습과 패턴을 유지하고 복원된 자동 반영은 일시중지한다', () async {
    final key = await teach();
    await repo.setAutoPosting(key, true, manual: true);
    final backup = await exportData(db);
    final other = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final restored = await Repo.fromDb(other);
      await importData(other, backup);
      final p = await restored.autoProgress(key);
      expect(p.enabled, false);
      expect(p.checked, 1);
      expect(p.correct, 1);
      await Repo.fromDb(other);
      expect(await restored.personalExampleCount(), 1);
    } finally {
      await other.close();
    }
  });
  test('연결 이체가 된 자동 반영도 상대 기록을 보존하며 되돌린다', () async {
    final key = await teach();
    await repo.setAutoPosting(key, true, manual: true);
    await db.insert('tx', {
      'id': 'paired-test',
      'type': 'income',
      'amount': 10000,
      'merchant': '시험입금',
      'counterparty': '테스트통장',
      'account': '시험대상',
      'dir': 'in',
      'status': 'ok',
      'occurred_at': DateTime.now().millisecondsSinceEpoch + 600000,
    });
    final r = await receive();
    expect(r.tx.pairId, 'paired-test');
    expect(await repo.undoClassification(r.tx.id), true);
    final other = (await db.query(
      'tx',
      where: 'id=?',
      whereArgs: ['paired-test'],
    )).single;
    expect(other['type'], 'income');
    expect(other['pair_id'], isNull);
    expect((await repo.notificationReview(r.tx.id))!.tx.status, 'candidate');
    expect((await repo.autoProgress(key)).paused, true);
  });
  test('금액이 포함된 은행 제목과 천 단위 쉼표 변화는 같은 패턴이다', () async {
    Future<NotificationReview> bank(String value) async {
      final id = await db.insert('raw_notification', {
        'package': 'com.kakaobank.channel',
        'title': '입금 $value원',
        'text': '시험입금 → 입출금통장(0001)\n잔액 $value원',
        'posted_at': DateTime.now().millisecondsSinceEpoch + seq++ * 600000,
      });
      await repo.processPending();
      return (await repo.notificationReview(
        (await db.query('tx', where: 'raw_id=?', whereArgs: [id])).single['id']
            as String,
      ))!;
    }

    final r = await bank('1,000');
    final p = (await repo.observeAutoProposal(
      r,
      type: 'income',
      category: '기타수입',
    ))!;
    await repo.confirmNotification(
      r,
      category: '기타수입',
      enableAutoPatternKey: p.key,
    );
    final next = await bank('1,000,000');
    expect(next.tx.autoPosted, true);
    expect(next.tx.amount, 1000000);
  });
  test('확인한 상대 통장을 다음 제안에서 재사용한다', () async {
    await repo.addAccount('시험적금');
    final r = await receive();
    await repo.observeAutoProposal(r, type: 'transfer', category: '적금');
    await repo.confirmNotification(
      r,
      type: 'transfer',
      category: '적금',
      destination: '시험적금',
    );
    final next = await receive();
    expect(await repo.autoDestination(next), '시험적금');
    final p = (await repo.observeAutoProposal(
      next,
      type: 'transfer',
      category: '적금',
      destination: await repo.autoDestination(next),
    ))!;
    await repo.confirmNotification(
      next,
      type: 'transfer',
      category: '적금',
      destination: '시험적금',
    );
    expect((await repo.autoProgress(p.key)).correct, 1);
  });
  test('자동 반영 설정 실패는 거래 승인도 함께 롤백한다', () async {
    final r = await receive();
    await repo.observeAutoProposal(r, type: 'expense', category: '생활');
    await expectLater(
      repo.confirmNotification(
        r,
        category: '생활',
        enableAutoPatternKey: 'invalid-key',
      ),
      throwsStateError,
    );
    expect((await repo.notificationReview(r.tx.id))!.tx.status, 'candidate');
    expect(await db.query('notif_feedback'), isEmpty);
  });
}

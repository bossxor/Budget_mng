import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/core/notification_policy.dart';
import 'package:jumeoni/core/notification_classifier.dart';
import 'package:jumeoni/data/settlement_repo.dart';
import 'package:jumeoni/data/backup.dart';
import 'package:jumeoni/data/extras.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repo repo;
  final now = DateTime.now();
  var sequence = 0;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    repo = await Repo.fromDb(db);
    sequence = 0;
  });
  tearDown(() async => db.close());
  Future<NotificationReview> receive({
    String package = 'com.example.chat',
    String title = '민수',
    String text = '30,000원 입금했어',
  }) async {
    final raw = await db.insert('raw_notification', {
      'package': package,
      'title': title,
      'text': text,
      'posted_at': now.millisecondsSinceEpoch + sequence++ * 600000,
      'state': 0,
    });
    await repo.processPending();
    final row = (await db.query(
      'tx',
      where: 'raw_id=?',
      whereArgs: [raw],
    )).single;
    return (await repo.notificationReview(row['id'] as String))!;
  }

  test('메신저 숫자 입금은 후보이고 수입·위젯 원천·CSV·정산에 섞이지 않는다', () async {
    final r = await receive();
    expect(r.tx.status, 'candidate');
    expect(r.original, contains('30,000원 입금했어'));
    final summary = await repo.summary(now);
    expect(summary.income, 0);
    expect(summary.expense, 0);
    expect(summary.reviewCount, 1);
    expect(await repo.monthTx(now), isEmpty);
    expect(await repo.settlements.candidates('민수'), isEmpty);
    expect(await exportCsv(repo), isNot(contains('30000')));
    expect((await repo.reviewList()).single.id, r.tx.id);
    await expectLater(repo.updateTx(r.tx.id, amount: 100), throwsStateError);
    await expectLater(repo.delete(r.tx.id), throwsStateError);
    await expectLater(repo.classifyTx(r.tx.id), throwsStateError);
  });

  test('템플릿을 흉내 낸 메신저는 후보, 실제 은행 앱 템플릿만 확정한다', () async {
    const title = '입금 1,000원', text = '김철수 → 입출금통장(0001)\n잔액 11,000원';
    final fake = await receive(title: title, text: text);
    expect(fake.tx.status, 'candidate');
    final bank = await receive(
      package: 'com.kakaobank.channel',
      title: title,
      text: text,
    );
    expect(bank.tx.status, 'ok');
    expect((await repo.summary(now)).income, 1000);
    final genericBank = await receive(package: 'com.kakaobank.channel');
    expect(genericBank.tx.status, 'candidate');
  });

  test('고쳐서 승인하면 금액·방향·분류와 학습을 함께 반영하고 되돌린다', () async {
    final r = await receive();
    await repo.confirmNotification(
      r,
      amount: 5000,
      type: 'expense',
      party: '실제 거래처',
      category: '식비',
    );
    expect((await repo.summary(now)).expense, 5000);
    expect((await repo.summary(now)).income, 0);
    expect(await repo.personalExampleCount(), 1);
    expect((await db.query('notif_feedback')).single['verdict'], 'fixed');
    await expectLater(repo.confirmNotification(r), throwsStateError);
    expect(await repo.undoClassification(r.tx.id), true);
    expect((await repo.summary(now)).expense, 0);
    expect((await repo.notificationReview(r.tx.id))!.tx.status, 'candidate');
    expect(await repo.personalExampleCount(), 0);
    expect((await db.query('notif_feedback')).single['verdict'], 'undone');
  });

  test('맞아요는 확정하고 정답으로 저장하되 자동 판독을 정답으로 학습하지 않는다', () async {
    final r = await receive();
    expect(await db.query('notif_feedback'), isEmpty);
    await repo.confirmNotification(r);
    expect((await repo.summary(now)).income, 30000);
    expect((await db.query('notif_feedback')).single['verdict'], 'yes');
    expect(await repo.undoClassification(r.tx.id), true);
    expect((await repo.summary(now)).income, 0);
  });

  test('대화방 숨김은 같은 앱·방만 막고 다른 방과 같은 이름의 은행 입금을 보존한다', () async {
    final r = await receive();
    await repo.rejectNotification(r, reason: 'chat', muteScope: 'title');
    expect((await db.query('tx')).single['status'], 'rejected');
    final id = await db.insert('raw_notification', {
      'package': r.package,
      'title': r.title,
      'text': '40,000원 입금했어',
      'posted_at': now.millisecondsSinceEpoch + 123,
      'state': 0,
    });
    expect(await repo.processPending(), 0);
    expect(
      (await db.query(
        'raw_notification',
        where: 'id=?',
        whereArgs: [id],
      )).single['state'],
      5,
    );
    expect((await repo.notificationMuteRules()).single['blocked_count'], 1);
    final other = await receive(title: '영희');
    expect(other.tx.status, 'candidate');
    final bank = await receive(
      package: 'com.kakaobank.channel',
      title: '입금 1,000원',
      text: '민수 → 입출금통장(0001)\n잔액 11,000원',
    );
    expect(bank.tx.status, 'ok');
    final feedback = (await repo.hiddenNotificationFeedback()).single;
    await repo.restoreNotification(feedback['notification_key'] as String);
    expect(await repo.notificationMuteRules(), isEmpty);
    expect((await repo.notificationReview(r.tx.id))!.tx.status, 'candidate');
  });

  test('은행·문자·추가 등록 앱은 사용자가 대화로 거절해도 숨김 규칙을 만들지 않는다', () async {
    await repo.setKv('extra_packages', 'com.example.finance');
    for (final package in [
      'com.nonghyup.nhallonebank',
      'com.samsung.android.messaging',
      'com.example.finance',
    ]) {
      final r = await receive(package: package);
      await repo.rejectNotification(r, reason: 'chat', muteScope: 'app');
    }
    expect(await repo.notificationMuteRules(), isEmpty);
    expect(await repo.hiddenNotificationFeedback(), hasLength(3));
  });

  test('광고·인증 거절을 실제 판독 모델이 사용하고 출처가 다른 실제 입금을 학습으로 막지 않는다', () async {
    for (var i = 0; i < 2; i++) {
      final r = await receive(title: '이벤트', text: '입금 30,000원 혜택 이벤트 당첨 안내');
      await repo.rejectNotification(r, reason: 'ad');
    }
    final next = await receive(title: '이벤트', text: '입금 50,000원 혜택 이벤트 당첨 안내');
    final assessment = await repo.assessNotification(next);
    expect(assessment, isNotNull);
    expect(assessment!.isTransaction, false);
    expect(assessment.support, 2);
    expect(next.tx.status, 'candidate'); // 학습 제안도 사용자 확인을 거친다.
    expect(await repo.notificationMuteRules(), isEmpty);
    expect(
      (await db.query('notif_feedback'))
          .every((r) => !(r['snippet'] as String).contains('30,000')),
      true,
    );
    final other = await receive(
      package: 'com.example.other',
      title: '이벤트',
      text: '입금 50,000원 혜택 이벤트 당첨 안내',
    );
    expect(await repo.assessNotification(other), isNull);
    await repo.restoreNotification(
      (await repo.hiddenNotificationFeedback()).first['notification_key']
          as String,
    );
    expect(await repo.assessNotification(next), isNull);
  });

  test('중복은 기존 내역과 연결하고 거래 아님 학습에 넣지 않는다', () async {
    final a = await receive();
    await repo.confirmNotification(a);
    final b = await receive(package: 'com.example.other');
    expect((await repo.notificationDuplicates(b)).single.id, a.tx.id);
    await expectLater(
      repo.rejectNotification(b, reason: 'duplicate'),
      throwsArgumentError,
    );
    await repo.rejectNotification(b, reason: 'duplicate', duplicateId: a.tx.id);
    expect((await repo.summary(now)).income, 30000);
    final f = (await repo.hiddenNotificationFeedback()).single;
    expect(f['linked_tx_id'], a.tx.id);
    expect(
      await repo.assessNotification((await repo.notificationReview(b.tx.id))!),
      isNull,
    );
  });

  test('내 통장 이체는 거절 대신 목적을 붙여 확정하고 수입에서 뺀다', () async {
    final r = await receive();
    await repo.addAccount('내 적금');
    await repo.confirmNotification(
      r,
      type: 'transfer',
      category: '적금',
      destination: '내 적금',
      reason: 'own_transfer',
    );
    expect((await repo.summary(now)).income, 0);
    expect((await repo.monthTx(now)).single.category, '적금');
    expect((await db.query('notif_feedback')).single['reason'], 'own_transfer');
    expect(await repo.personalExampleCount(), 1);
  });

  test('복원 시 원문 ID가 다른 개인 대화를 가리켜도 잘못된 원문을 보여주지 않는다', () async {
    final r = await receive();
    await repo.rejectNotification(r, reason: 'otp');
    final backup = await exportData(db);
    final target = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final restored = await Repo.fromDb(target);
      await target.insert('raw_notification', {
        'package': 'private.chat',
        'title': '다른 방',
        'text': '다른 사람의 사적인 원문',
        'posted_at': 1,
      });
      await importData(target, backup);
      final view = (await restored.notificationReview(r.tx.id))!;
      expect(view.original, isNull);
      expect(view.package, r.package);
      expect((await target.query('notif_feedback')).single['raw_id'], isNull);
      await restored.restoreNotification(
        (await restored.hiddenNotificationFeedback()).single['notification_key']
            as String,
      );
      expect(
        (await restored.notificationReview(r.tx.id))!.tx.status,
        'candidate',
      );
      expect((await restored.summary(now)).income, 0);
    } finally {
      await target.close();
    }
  });

  test('되돌리기는 다른 거절에서 새로 만든 숨김 규칙을 지우지 않는다', () async {
    final r = await receive();
    await repo.rejectNotification(r, reason: 'chat', muteScope: 'app');
    final f = (await repo.hiddenNotificationFeedback()).single;
    await db.update('notif_mute', {
      'created_at': (f['mute_created_at'] as int) + 1,
    });
    await repo.restoreNotification(f['notification_key'] as String);
    expect(await repo.notificationMuteRules(), hasLength(1));
  });

  test('개인정보 숫자 정규화와 명시적 금융 출처 보호', () {
    expect(
      normalizedNotificationSnippet('계좌 01234567 / 30,000원'),
      '계좌 # / #,#원',
    );
    expect(trustedNotification('com.example.chat', '입금', 'kakaobank'), false);
    expect(protectedNotificationSource('com.kakao.talk', '삼성카드', {}), true);
  });

  test('거래와 광고 양쪽 정답을 훈련하고 모르는 문구·상충 사례는 다시 묻는다', () {
    final model = NotificationClassifier([
      for (var i = 0; i < 3; i++)
        NotificationExample('yes$i', 'bank', '입출금', '입금 #원 급여 지급 완료', true),
      for (var i = 0; i < 3; i++)
        NotificationExample('no$i', 'bank', '이벤트', '입금 #원 이벤트 당첨 혜택 안내', false),
    ]);
    expect(
      model.predict('bank', '입출금', '입금 50,000원 급여 지급 완료')!.isTransaction,
      true,
    );
    expect(
      model.predict('bank', '이벤트', '입금 50,000원 이벤트 당첨 혜택 안내')!.isTransaction,
      false,
    );
    expect(model.predict('bank', '새 알림', '낯선 가맹점 결제 승인'), isNull);
    final conflict = NotificationClassifier([
      const NotificationExample('a', 'chat', '방', '입금 #원 완료', true),
      const NotificationExample('b', 'chat', '방', '입금 #원 완료', false),
    ]);
    expect(conflict.predict('chat', '방', '입금 10,000원 완료'), isNull);
  });

  test('과거 자동 확정된 오탐만 후보로 돌리고 명시적 승인은 보존한다', () async {
    final a = await receive(
      title: '입금 1,000원',
      text: '민수 → 입출금통장(0001)\n잔액 11,000원',
    );
    final b = await receive();
    await repo.confirmNotification(b);
    await db.update('tx', {
      'notification_key': null,
      'notification_package': null,
      'notification_title': null,
      'status': 'ok',
    });
    await db.delete('kv', where: 'k=?', whereArgs: ['notification_review_v1']);
    await repo.prepareNotificationReview();
    expect((await repo.notificationReview(a.tx.id))!.tx.status, 'candidate');
    expect((await repo.notificationReview(b.tx.id))!.tx.status, 'ok');
    expect(await repo.getKv('notification_review_migrated_count'), '1');
    await repo.prepareNotificationReview();
    expect(await repo.getKv('notification_review_migrated_count'), '1');
    expect((await repo.summary(now)).income, 30000);
  });

  test('정산 입금 API에 후보를 직접 전달해도 연결되지 않는다', () async {
    final r = await receive();
    await expectLater(
      repo.settlements.pay(
        ShareView('share', null, '나', 30000, 0),
        DepositCandidate(r.tx, 30000, false),
        30000,
      ),
      throwsStateError,
    );
    expect(await db.query('settlement_payment'), isEmpty);
  });

  test('백업 병합은 최근의 되돌리기를 이전 거절로 덮어쓰지 않는다', () async {
    final r = await receive();
    await repo.rejectNotification(r, reason: 'chat', muteScope: 'title');
    final old = await exportData(db);
    final f = (await repo.hiddenNotificationFeedback()).single;
    await repo.restoreNotification(f['notification_key'] as String);
    await importData(db, old);
    expect((await db.query('notif_feedback')).single['verdict'], 'undone');
    expect((await repo.notificationReview(r.tx.id))!.tx.status, 'candidate');
    expect(await repo.notificationMuteRules(), isEmpty);
  });
}

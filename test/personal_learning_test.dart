import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/core/personal_classifier.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/data/backup.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repo repo;
  final now = DateTime.now().subtract(const Duration(hours: 1));
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    repo = await Repo.fromDb(db);
  });
  tearDown(() async => db.close());
  Future<void> add(
    String id, {
    String party = '정기저축',
    String type = 'expense',
    String? category,
    String? destination,
    int amount = 300000,
    String source = 'bank',
    String direction = 'out',
    String? memo,
  }) async {
    await db.insert('tx', {
      'id': id,
      'type': type,
      'category': category,
      'amount': amount,
      'merchant': party,
      'counterparty': party,
      'account': '생활비',
      'destination': destination,
      'dir': direction,
      'occurred_at': now.millisecondsSinceEpoch,
      'status': 'ok',
      'source': source,
      'memo': memo,
    });
  }

  Future<void> teach(
    String id,
    String type,
    String category, {
    String party = '정기저축',
    String? destination,
  }) async {
    await add(id, party: party, destination: destination);
    await repo.classifyTx(id, type: type, category: category);
  }

  test('여러 분류를 실제 훈련하고 처음 본 문구 변형에도 추천한다', () async {
    for (var i = 0; i < 3; i++) {
      await teach('save$i', 'transfer', '적금', party: '행복적금 자동이체');
      await teach('card$i', 'transfer', '카드대금', party: '삼성카드 대금');
      await teach('coffee$i', 'expense', '카페', party: '동네커피 본점');
    }
    await add('new', party: '행복 적금 자동이체 10월', amount: 350000);
    await repo.refreshPersonalSuggestions();
    final suggestion = (await repo.personalSuggestions())['new']!;
    expect(suggestion.type, 'transfer');
    expect(suggestion.category, '적금');
    expect(suggestion.support, 3);
    expect(
      (await db.query('tx', where: 'id=?', whereArgs: ['new'])).single['type'],
      'expense',
    );
    expect(await repo.personalExampleCount(), 9);
    expect((await repo.reviewList()).map((r) => r.id), contains('new'));
    expect((await repo.summary(now)).reviewCount, 1);
    await repo.approvePersonalSuggestion(suggestion);
    expect(await repo.personalExampleCount(), 10);
    expect(
      (await db.query('tx', where: 'id=?', whereArgs: ['new'])).single['type'],
      'transfer',
    );
    await repo.refreshPersonalSuggestions();
    expect((await repo.personalSuggestions()).containsKey('new'), false);
    expect(await repo.undoClassification('new'), true);
    expect(await repo.personalExampleCount(), 9);
    expect(
      (await db.query('tx', where: 'id=?', whereArgs: ['new'])).single['type'],
      'expense',
    );
  });
  test('추측, 중복 의심, 모르는 상대는 학습하지 않고 새 계좌 이체를 만들지 않는다', () async {
    await teach('a', 'transfer', '적금');
    await teach('b', 'transfer', '적금');
    await add('unknown', party: '처음보는 상대');
    await add('duplicate', memo: '중복 의심');
    await add('new');
    await repo.refreshPersonalSuggestions();
    var suggestions = await repo.personalSuggestions();
    expect(suggestions.keys, contains('new'));
    expect(suggestions.keys, isNot(contains('unknown')));
    expect(suggestions.keys, isNot(contains('duplicate')));
    await repo.refreshPersonalSuggestions();
    expect(await repo.personalExampleCount(), 2);
    expect(await db.query('tx'), hasLength(5));
    expect(
      (await db.query(
        'tx',
        where: 'id=?',
        whereArgs: ['new'],
      )).single['pair_id'],
      isNull,
    );
  });
  test('수정/삭제 후 오래된 추천 승인은 거절하고 학습도 제거한다', () async {
    await teach('a', 'transfer', '적금');
    await teach('b', 'transfer', '적금');
    await add('new');
    await repo.refreshPersonalSuggestions();
    final suggestion = (await repo.personalSuggestions())['new']!;
    await repo.updateTx('new', amount: 999);
    await expectLater(
      repo.approvePersonalSuggestion(suggestion),
      throwsStateError,
    );
    expect(await repo.personalExampleCount(), 2);
    await repo.delete('a');
    expect(await repo.personalExampleCount(), 1);
    await repo.refreshPersonalSuggestions();
    expect(await repo.personalSuggestions(), isEmpty);
  });
  test('후보 알림은 합계에 넣지 않고 판독과 AI 추천을 한 번에 승인한다', () async {
    await teach('a', 'transfer', '적금', party: '행복적금 자동이체');
    await teach('b', 'transfer', '적금', party: '행복적금 자동이체');
    await db.insert('raw_notification', {
      'package': 'com.example.bank',
      'title': '입출금 알림',
      'text': '출금: 350,000원\n계좌: 생활비\n내용: 행복 적금 자동이체 10월',
      'posted_at': now.millisecondsSinceEpoch,
      'state': 0,
    });
    var saved = -1, review = -1;
    expect(
      await repo.runBackgroundIngest(
        onComplete: (s, r) {
          saved = s;
          review = r;
        },
      ),
      1,
    );
    expect(saved, 0);
    expect(review, 1);
    expect(await repo.personalSuggestions(),isEmpty);
    expect((await repo.summary(now)).expense,0);
    final row = (await db.query('tx', where: 'raw_id IS NOT NULL')).single;
    expect(row['type'], 'expense');
    expect(row['status'],'candidate');
    expect(await repo.personalExampleCount(), 2);
    final notification=(await repo.notificationReview(row['id'] as String))!;
    final suggestion=(await repo.proposeNotificationClassification(notification))!;
    expect(suggestion.label.category,'적금');
    await repo.confirmNotification(notification,type:suggestion.label.type,category:suggestion.label.category);
    expect((await repo.summary(now)).expense, 0);
    expect(await repo.personalExampleCount(), 3);
    var called = false;
    await repo.runBackgroundIngest(onComplete: (_, r) => called = true);
    expect(called, false);
  });
  test('수정 정답은 한 건을 교체하고 되돌리기는 이전 학습을 복원한다', () async {
    await teach('a', 'transfer', '적금');
    await repo.classifyTx('a', type: 'expense', category: '생활');
    expect(await repo.personalExampleCount(), 1);
    expect(
      LearningLabel.decode(
        (await db.query('learning_example')).single['label'] as String,
      ).category,
      '생활',
    );
    expect(await repo.undoClassification('a'), true);
    expect(
      LearningLabel.decode(
        (await db.query('learning_example')).single['label'] as String,
      ).category,
      '적금',
    );
    expect(await repo.undoClassification('a'), true);
    expect(await repo.personalExampleCount(), 0);
  });
  test('나중에 이체로 연결되면 예전 지출 승인을 학습에 남기지 않는다', () async {
    await teach('out', 'expense', '생활', party: 'B');
    await db.insert('tx', {
      'id': 'in',
      'type': 'income',
      'amount': 300000,
      'account': 'B',
      'counterparty': '생활비',
      'dir': 'in',
      'status': 'ok',
      'source': 'bank',
      'occurred_at': now.millisecondsSinceEpoch,
    });
    expect(await repo.personalExampleCount(), 1);
    await repo.pairTransfers();
    expect(await repo.personalExampleCount(), 0);
    expect((await db.query('tx')).every((r) => r['type'] == 'transfer'), true);
  });
  test('동일 이체는 한 번 학습하고 통장 용도로 첫 추천 후 승인한다', () async {
    await repo.addAccount('생활비');
    await repo.addAccount('내 적금', role: 'saving');
    await repo.addGuided(
      kind: 'transfer',
      amount: 300000,
      title: '저축',
      account: '생활비',
      destination: '내 적금',
      category: '적금',
      at: now,
    );
    expect(await repo.personalExampleCount(), 1);
    await add('first', type: 'transfer', destination: '내 적금', party: '보내기');
    await repo.refreshPersonalSuggestions();
    final suggestion = (await repo.personalSuggestions())['first']!;
    expect(suggestion.category, '적금');
    expect(suggestion.support, 0);
    expect(suggestion.evidence, contains('아직 학습 결과는 아니에요'));
    await repo.approvePersonalSuggestion(suggestion);
    expect(await repo.personalExampleCount(), 2);
  });
  test('백업 복원/재시작은 승인 자료를 유지하고 초기화는 이력으로 다시 살리지 않는다', () async {
    await teach('a', 'transfer', '적금');
    await teach('b', 'transfer', '적금');
    final backup = await exportData(db);
    final other = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final restored = await Repo.fromDb(other);
      await importData(other, backup);
      expect(await restored.personalExampleCount(), 2);
      await restored.clearPersonalLearning();
      expect(await (await Repo.fromDb(other)).personalExampleCount(), 0);
      await restored.undoClassification('a');
      expect(await restored.personalExampleCount(), 0);
    } finally {
      await other.close();
    }
  });
  test('기존 자동 분류는 제외하고 취소되지 않은 승인 이력만 한 번 이관한다', () async {
    await add('automatic', category: '카페');
    await add('approved', category: '카페');
    final after = {
      'type': 'expense',
      'category': '카페',
      'status': 'ok',
      'memo': null,
      'dir': 'out',
    };
    await db.insert('classification_history', {
      'id': 'old',
      'tx_id': 'approved',
      'after_json': jsonEncode(after),
      'before_json': jsonEncode({...after, 'category': null}),
      'created_at': 1,
      'undone': 0,
    });
    expect(await repo.personalExampleCount(), 1);
    await repo.clearPersonalLearning();
    expect(await (await Repo.fromDb(db)).personalExampleCount(), 0);
  });
  test('상충하는 승인과 입출금 방향은 확신 있는 추천으로 포장하지 않는다', () {
    LearningInput input(String dir) => LearningInput(
      account: 'A',
      destination: '',
      party: '똑같은거래처',
      direction: dir,
      amount: 10000,
      at: now,
    );
    final model = PersonalClassifier([
      for (var i = 0; i < 4; i++)
        LearningExample(
          '$i',
          input('out'),
          LearningLabel('expense', i.isEven ? '식비' : '생활'),
        ),
    ]);
    expect(model.predict(input('out')), isNull);
    expect(model.predict(input('in')), isNull);
    expect(
      model.predict(
        LearningInput(
          account: 'A',
          destination: '',
          party: '출금·결제',
          direction: 'out',
          amount: 10000,
          at: now,
        ),
      ),
      isNull,
    );
  });
  test('오래된 백업 예제는 최신 분류를 덮어쓰거나 잘못된 정답으로 학습되지 않는다', () async {
    await teach('a', 'transfer', '적금');
    final old = await exportData(db);
    await repo.classifyTx('a', type: 'expense', category: '생활');
    await importData(db, old);
    expect((await repo.personalModel()).examples.single.label.category, '생활');
    await db.delete('learning_example');
    await importData(db, old);
    expect(await repo.personalExampleCount(), 0);
    expect((await db.query('tx')).single['category'], '생활');
  });
}

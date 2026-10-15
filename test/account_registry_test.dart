import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/core/bank_accounts.dart';
import 'package:jumeoni/data/repo.dart';
import 'package:jumeoni/data/backup.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late Repo repo;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    repo = await Repo.fromDb(db);
  });
  tearDown(() async => db.close());
  test('여러 은행을 등록하고 번호의 앞자리 0과 중복 별칭은 보존한다', () async {
    final keys = await repo.registerBankAccounts([
      const BankAccountDraft(
        bank: 'nh',
        number: '012-345-678901',
        label: '생활비',
        role: 'living',
      ),
      const BankAccountDraft(
        bank: 'kakao',
        number: '3333-01-1234567',
        label: '생활비',
        role: 'saving',
      ),
    ]);
    expect(keys.toSet(), hasLength(2));
    final rows = await repo.accounts();
    expect(rows.map((a) => a.label), everyElement('생활비'));
    expect(
      rows.firstWhere((a) => a.bankCode == 'nh').accountNumber,
      '012345678901',
    );
    expect(
      rows.firstWhere((a) => a.bankCode == 'nh').maskedIdentity,
      'NH농협은행 · •••• 8901',
    );
    expect(await repo.resolveAccount('농협 012-345-678901'), keys.first);
    expect(await repo.resolveAccount('농협 012-***-678901'), '농협 012-***-678901');
    expect(await repo.resolveAccount('국민 012-345-678901'), '국민 012-345-678901');
    final identity = await repo.identity();
    expect(identity.isOwn('NH농협 012-345-678901'), true);
    expect(identity.isOwn('국민 012-345-678901'), false);
  });
  test('중복 계좌/잘못된 행은 전체 등록을 취소한다', () async {
    await repo.registerBankAccounts([
      const BankAccountDraft(bank: 'nh', number: '12345678901'),
    ]);
    await expectLater(
      repo.registerBankAccounts([
        const BankAccountDraft(bank: 'kakao', number: '3333123456789'),
        const BankAccountDraft(bank: 'nh', number: '123-4567-8901'),
      ]),
      throwsArgumentError,
    );
    expect(await repo.accounts(), hasLength(1));
    await expectLater(
      repo.registerBankAccounts([
        const BankAccountDraft(bank: 'kakao', number: '3333123456789'),
        const BankAccountDraft(bank: 'nh', number: '1234-****-901'),
      ]),
      throwsArgumentError,
    );
    expect(await repo.accounts(), hasLength(1));
    await expectLater(
      repo.registerBankAccounts([
        const BankAccountDraft(bank: 'nh', number: '12345678902'),
        const BankAccountDraft(bank: 'nh', number: '123-4567-8902'),
      ]),
      throwsArgumentError,
    );
  });
  test('기존 통장에 은행 정보를 덧붙여도 거래/잔액/계획은 유지한다', () async {
    await repo.addAccount('생활비');
    await repo.addAccount('적금', role: 'saving');
    await repo.correctBalance('생활비', 1000000, DateTime.now());
    await repo.addGuided(
      kind: 'transfer',
      amount: 300000,
      title: '저축',
      account: '생활비',
      destination: '적금',
      category: '적금',
      at: DateTime.now(),
    );
    await repo.planning.addPlan('생활비', '적금', 300000, 15);
    final keys = await repo.registerBankAccounts([
      const BankAccountDraft(
        bank: 'nh',
        number: '012345678901',
        label: '월급 통장',
        role: 'living',
        existingKey: '생활비',
      ),
    ]);
    expect(keys, ['생활비']);
    final account = (await repo.accounts()).firstWhere((a) => a.key == '생활비');
    expect(account.balance, 1000000);
    expect(account.label, '월급 통장');
    expect((await repo.planning.plans()).single.fromKey, '생활비');
    expect(
      (await repo.monthTx(DateTime.now())).where((r) => r.account == '생활비'),
      hasLength(1),
    );
  });
  test('전체 번호 알림만 등록 통장으로 수집하고 다른 은행/마스킹은 임의 연결하지 않는다', () async {
    final key = (await repo.registerBankAccounts([
      const BankAccountDraft(
        bank: 'nh',
        number: '012345678901',
        label: '농협 생활비',
      ),
    ])).single;
    final now = DateTime.now();
    await db.insert('raw_notification', {
      'package': 'com.example.bank',
      'title': '입출금 알림',
      'text': '입금: 10,000원\n계좌: 농협 012-345-678901\n내용: 급여',
      'posted_at': now.millisecondsSinceEpoch,
      'state': 0,
    });
    await repo.processPending();
    expect((await repo.monthTx(now)).single.account, key);
    expect(await repo.accounts(), hasLength(1));
  });
  test('계좌 연결과 백업에서 은행 정보를 유지하며 다른 실제 계좌끼리는 연결하지 않는다', () async {
    final key = (await repo.registerBankAccounts([
      const BankAccountDraft(bank: 'nh', number: '012345678901'),
    ])).single;
    await repo.addAccount('기존통장');
    await repo.linkAccount(key, '기존통장');
    expect((await repo.accounts()).single.accountNumber, '012345678901');
    expect(await repo.resolveAccount('농협 012345678901'), '기존통장');
    final other = (await repo.registerBankAccounts([
      const BankAccountDraft(bank: 'kb', number: '012345678901'),
    ])).single;
    await expectLater(repo.linkAccount(other, '기존통장'), throwsArgumentError);
    final backup = await exportData(db);
    final restoredDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final restored = await Repo.fromDb(restoredDb);
      await importData(restoredDb, backup);
      expect(await restored.resolveAccount('농협 012345678901'), '기존통장');
      expect(await restored.accounts(), hasLength(2));
    } finally {
      await restoredDb.close();
    }
    await Repo.fromDb(db);
    expect(await repo.accounts(), hasLength(2));
  });
  test('등록한 받는 계좌가 명확하면 첫 알림부터 적금 목적을 확인받는다', () async {
    final keys = await repo.registerBankAccounts([
      const BankAccountDraft(bank: 'nh', number: '012345678901', label: '생활비'),
      const BankAccountDraft(
        bank: 'kakao',
        number: '3333011234567',
        label: '내 적금',
        role: 'saving',
      ),
    ]);
    final now = DateTime.now();
    await db.insert('raw_notification', {
      'package': 'com.example.bank',
      'title': '입출금 알림',
      'text': '출금: 300,000원\n계좌: 농협 012-345-678901\n내용: 카카오뱅크 3333-01-1234567',
      'posted_at': now.millisecondsSinceEpoch,
      'state': 0,
    });
    await repo.processPending();
    final tx = (await repo.monthTx(now)).single;
    expect(tx.type, 'transfer');
    expect(tx.account, keys.first);
    expect(tx.destination, keys.last);
    expect((await repo.summary(now)).expense, 0);
    final suggestion = (await repo.personalSuggestions()).values.single;
    expect(suggestion.category, '적금');
    expect(suggestion.support, 0);
    expect(await repo.personalExampleCount(), 0);
  });
  test('다른 기기에서 같은 계좌를 등록한 백업도 중복 없이 병합하고 학습/계획/되돌리기를 보존한다', () async {
    const drafts = [
      BankAccountDraft(bank: 'nh', number: '012345678901', label: '생활비'),
      BankAccountDraft(
        bank: 'kakao',
        number: '3333011234567',
        label: '내 적금',
        role: 'saving',
      ),
    ];
    final keys = await repo.registerBankAccounts(drafts);
    await repo.addGuided(
      kind: 'transfer',
      amount: 300000,
      title: '저축',
      account: keys.first,
      destination: keys.last,
      category: '적금',
      at: DateTime.now(),
    );
    await repo.planning.addPlan(keys.first, keys.last, 300000, 15);
    final outgoing = collapseTransfers(await repo.monthTx(DateTime.now()))
        .single;
    await repo.classifyTx(outgoing.id, category: '여행저축');
    final backup = await exportData(db);
    final other = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final restored = await Repo.fromDb(other);
      final targetKeys = await restored.registerBankAccounts(drafts);
      expect(await importData(other, backup), 2);
      expect(await importData(other, backup), 0);
      expect(await restored.accounts(), hasLength(2));
      final rows = await restored.monthTx(DateTime.now());
      expect(rows.map((r) => r.account).toSet(), targetKeys.toSet());
      expect(
        (await restored.planning.plans()).single.fromKey,
        targetKeys.first,
      );
      expect(await restored.personalExampleCount(), 1);
      expect(await restored.undoClassification(outgoing.id), true);
      expect(
        (await restored.monthTx(DateTime.now()))
            .every((r) => r.category == '적금'),
        true,
      );
      expect(await restored.personalExampleCount(), 1);
    } finally {
      await other.close();
    }
  });
}

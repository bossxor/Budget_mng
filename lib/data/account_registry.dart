part of 'repo.dart';

Future<void> ensureAccountRegistry(Database db) async {
  final columns = await db.rawQuery('PRAGMA table_info(account)');
  for (final column in ['bank_code', 'account_number']) {
    if (!columns.any((c) => c['name'] == column)) {
      await addColumnSafely(db, 'account', '$column TEXT');
    }
  }
  await db.execute('''CREATE UNIQUE INDEX IF NOT EXISTS account_bank_number
    ON account(bank_code,account_number)
    WHERE bank_code IS NOT NULL AND account_number IS NOT NULL''');
}

extension AccountRegistry on Repo {
  /// 모든 행을 검증하고 한 번에 저장해 일부 통장만 등록되는 상태를 막는다.
  Future<List<String>> registerBankAccounts(
    List<BankAccountDraft> drafts,
  ) async {
    if (drafts.isEmpty) throw ArgumentError('등록할 통장을 추가해 주세요.');
    final prepared = <BankAccountDraft>[];
    final seen = <String>{};
    for (final draft in drafts) {
      if (!bankNames.containsKey(draft.bank)) {
        throw ArgumentError('은행을 선택해 주세요.');
      }
      if (!roles.containsKey(draft.role)) {
        throw ArgumentError('통장 용도를 확인해 주세요.');
      }
      final number = normalizeAccountNumber(draft.number);
      if (!seen.add('${draft.bank}:$number')) {
        throw ArgumentError('목록에 같은 계좌가 두 번 있어요.');
      }
      final label = draft.label.trim();
      if (label.length > 40) throw ArgumentError('통장 별칭은 40자 이내로 입력해 주세요.');
      prepared.add(
        BankAccountDraft(
          bank: draft.bank,
          number: number,
          label: label,
          role: draft.role,
          existingKey: draft.existingKey,
        ),
      );
    }
    return _db.transaction((db) async {
      final aliases = {
        for (final row in await db.query('account_alias'))
          row['alias']: row['canonical'],
      };
      final touched = <String>{};
      final keys = <String>[];
      for (final draft in prepared) {
        final key = draft.existingKey == null
            ? 'bank:${_newId()}'
            : (aliases[draft.existingKey] ?? draft.existingKey) as String;
        if (!touched.add(key)) throw ArgumentError('같은 기존 통장을 두 번 선택했어요.');
        if (draft.existingKey != null &&
            (await db.query(
              'account',
              where: 'key=?',
              whereArgs: [key],
            )).isEmpty) {
          throw ArgumentError('정보를 추가할 기존 통장을 다시 선택해 주세요.');
        }
        final duplicate = await db.query(
          'account',
          where: 'bank_code=? AND account_number=? AND key<>?',
          whereArgs: [draft.bank, draft.number, key],
        );
        if (duplicate.isNotEmpty) {
          throw ArgumentError('이미 등록된 계좌예요. 기존 통장을 선택해 주세요.');
        }
        final values = <String, Object?>{
          'bank_code': draft.bank,
          'account_number': draft.number,
          'role': draft.role,
        };
        if (draft.label.isNotEmpty) values['label'] = draft.label;
        if (draft.existingKey == null) {
          await db.insert('account', {
            'key': key,
            'label': '${bankNames[draft.bank]} 통장',
            ...values,
          });
        } else {
          await db.update('account', values, where: 'key=?', whereArgs: [key]);
        }
        keys.add(key);
      }
      return keys;
    });
  }

  Future<String?> _registeredAccount(String reference) async {
    final identity = parseAccountReference(reference);
    if (identity == null) return null;
    final accounts = await _db.rawQuery(
      '''SELECT key FROM account WHERE bank_code=? AND account_number=?
      AND key NOT IN (SELECT alias FROM account_alias)''',
      [identity.bank, identity.number],
    );
    return accounts.length == 1 ? accounts.single['key'] as String : null;
  }
}

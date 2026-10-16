part of 'repo.dart';

Future<void> ensurePersonalLearning(Database db) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS learning_example(
    tx_id TEXT PRIMARY KEY, input_json TEXT NOT NULL, label TEXT NOT NULL,
    updated_at INTEGER NOT NULL)''');
  await db.execute('''CREATE TABLE IF NOT EXISTS learning_suggestion(
    tx_id TEXT PRIMARY KEY, type TEXT NOT NULL, category TEXT NOT NULL,
    score REAL NOT NULL, support INTEGER NOT NULL, evidence TEXT NOT NULL,
    fingerprint TEXT NOT NULL)''');
  final columns = await db.rawQuery(
    'PRAGMA table_info(classification_history)',
  );
  for (final name in ['sample_before', 'sample_after']) {
    if (!columns.any((c) => c['name'] == name)) {
      await addColumnSafely(db, 'classification_history', '$name TEXT');
    }
  }
}

String _learningFingerprint(Map<String, Object?> row) => jsonEncode([
  for (final key in [
    'id',
    'type',
    'category',
    'amount',
    'merchant',
    'counterparty',
    'account',
    'destination',
    'dir',
    'occurred_at',
    'pair_id',
    'status',
    'memo',
    'deleted_at',
    'notification_key',
    'auto_applied_key',
  ])
    row[key],
]);

class PersonalSuggestion {
  const PersonalSuggestion({
    required this.txId,
    required this.type,
    required this.category,
    required this.evidence,
    required this.support,
    required this.fingerprint,
  });
  final String txId, type, category, evidence, fingerprint;
  final int support;
  factory PersonalSuggestion.fromMap(Map<String, Object?> row) =>
      PersonalSuggestion(
        txId: row['tx_id'] as String,
        type: row['type'] as String,
        category: row['category'] as String,
        evidence: row['evidence'] as String,
        support: row['support'] as int,
        fingerprint: row['fingerprint'] as String,
      );
}

Future<LearningInput> _learningInput(
  DatabaseExecutor db,
  Map<String, Object?> row,
) async {
  final aliases = {
    for (final r in await db.query('account_alias')) r['alias']: r['canonical'],
  };
  final roles = {
    for (final r in await db.query('account')) r['key']: r['role'],
  };
  return _inputWithContext(row, aliases, roles);
}

LearningInput _inputWithContext(
  Map<String, Object?> row,
  Map<Object?, Object?> aliases,
  Map<Object?, Object?> roles,
) {
  final account = (aliases[row['account']] ?? row['account'] ?? '') as String;
  final destination =
      (aliases[row['destination']] ?? row['destination'] ?? '') as String;
  return LearningInput(
    account: account,
    destination: destination,
    party: (row['counterparty'] ?? row['merchant'] ?? '') as String,
    direction:
        (row['dir'] ?? (row['type'] == 'income' ? 'in' : 'out')) as String,
    amount: row['amount'] as int,
    at: DateTime.fromMillisecondsSinceEpoch(row['occurred_at'] as int),
    destinationRole: roles[destination] as String? ?? 'unset',
  );
}

Future<Map<String, Object?>?> _rememberApproval(
  DatabaseExecutor db,
  Map<String, Object?> row,
) async {
  final type = row['type'] as String;
  final category = row['category'] as String?;
  if (!['expense', 'income', 'transfer'].contains(type) ||
      category == null ||
      category.trim().isEmpty ||
      (row['amount'] as int) <= 0 ||
      ['candidate','rejected'].contains(row['status']) ||
      row['auto_applied_key']!=null ||
      (row['pair_id'] != null && row['dir'] == 'in')) {
    return null;
  }
  final input = await _learningInput(db, row);
  if (!LearningLabel(type, category).fits(input.direction)) return null;
  final sample = <String, Object?>{
    'tx_id': row['id'],
    'input_json': jsonEncode(input.toJson()),
    'label': LearningLabel(type, category).key,
    'updated_at': DateTime.now().microsecondsSinceEpoch,
  };
  await db.insert(
    'learning_example',
    sample,
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  return sample;
}

extension PersonalLearning on Repo {
  /// 한 번만 이전의 '직접 수정한 분류'를 이관한다. 자동 분류된 ok 거래는 학습하지 않는다.
  Future<void> migratePersonalApprovals() async {
    await _db.transaction((db) async {
      if ((await db.query(
        'kv',
        where: 'k=?',
        whereArgs: ['personal_learning_migrated'],
      )).isNotEmpty) {
        return;
      }
      final history = await db.rawQuery(
        '''SELECT h.* FROM classification_history h
        WHERE h.undone=0 AND NOT EXISTS (SELECT 1 FROM classification_history newer
          WHERE newer.tx_id=h.tx_id AND newer.undone=0 AND newer.created_at>h.created_at)
        ORDER BY h.created_at DESC LIMIT 500''',
      );
      for (final h in history) {
        final rows = await db.query(
          'tx',
          where: 'id=? AND deleted_at IS NULL',
          whereArgs: [h['tx_id']],
        );
        if (rows.isEmpty) continue;
        final after =
            jsonDecode(h['after_json'] as String) as Map<String, dynamic>;
        if (after.entries.any((e) => rows.first[e.key] != e.value)) continue;
        await _rememberApproval(db, rows.first);
      }
      await db.insert('kv', {
        'k': 'personal_learning_migrated',
        'v': '1',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<PersonalClassifier> personalModel() async {
    await migratePersonalApprovals();
    final rows = await _db.rawQuery(
      '''SELECT e.* FROM learning_example e JOIN tx t ON t.id=e.tx_id
      WHERE t.deleted_at IS NULL AND t.auto_applied_key IS NULL AND ${confirmedTxFilter('t.')} ORDER BY e.updated_at DESC, e.tx_id LIMIT 500''',
    );
    final aliases = {
      for (final r in await _db.query('account_alias'))
        r['alias']: r['canonical'],
    };
    final roles = {
      for (final r in await _db.query('account')) r['key']: r['role'],
    };
    final liveRows = rows.isEmpty
        ? <Map<String, Object?>>[]
        : await _db.query(
            'tx',
            where: 'id IN (${List.filled(rows.length, '?').join(',')})',
            whereArgs: rows.map((r) => r['tx_id']).toList(),
          );
    final liveById = {for (final row in liveRows) row['id']: row};
    final signature = jsonEncode([
      rows,
      liveRows,
      aliases.map((k, v) => MapEntry(k.toString(), v)),
      roles.map((k, v) => MapEntry(k.toString(), v)),
    ]);
    if (_personalSignature == signature && _personalModel != null) {
      return _personalModel!;
    }
    final examples = <LearningExample>[];
    for (final row in rows.reversed) {
      final input =
          jsonDecode(row['input_json'] as String) as Map<String, dynamic>;
      input['account'] = aliases[input['account']] ?? input['account'];
      input['destination'] =
          aliases[input['destination']] ?? input['destination'];
      input['role'] = roles[input['destination']] ?? 'unset';
      final live = liveById[row['tx_id']];
      final label = LearningLabel.decode(row['label'] as String);
      final approvedInput = LearningInput.fromJson(input);
      if (live == null ||
          label.type != live['type'] ||
          label.category != live['category'] ||
          (live['pair_id'] != null && live['dir'] == 'in') ||
          jsonEncode(approvedInput.toJson()) !=
              jsonEncode(_inputWithContext(live, aliases, roles).toJson())) {
        continue;
      }
      examples.add(
        LearningExample(row['tx_id'] as String, approvedInput, label),
      );
    }
    _personalSignature = signature;
    return _personalModel = PersonalClassifier(examples);
  }

  Future<void> refreshPersonalSuggestions() async {
    final model = await personalModel();
    await _db.transaction((db) async {
      // 다시 계산하므로 변경/삭제된 거래의 오래된 제안이 남지 않는다.
      await db.delete('learning_suggestion');
      final rows = await db.rawQuery(
        '''SELECT * FROM tx WHERE deleted_at IS NULL AND ${confirmedTxFilter()}
        AND amount>0 AND auto_applied_key IS NULL AND type IN ('expense','income','transfer') AND source<>'manual'
        AND (pair_id IS NULL OR dir='out') AND (memo IS NULL OR memo<>'중복 의심')
        AND id NOT IN (SELECT tx_id FROM learning_example)
        AND occurred_at>=? ORDER BY occurred_at DESC LIMIT 100''',
        [
          DateTime.now()
              .subtract(const Duration(days: 90))
              .millisecondsSinceEpoch,
        ],
      );
      final aliases = {
        for (final r in await db.query('account_alias'))
          r['alias']: r['canonical'],
      };
      final roles = {
        for (final r in await db.query('account')) r['key']: r['role'],
      };
      for (final row in rows) {
        final input = _inputWithContext(row, aliases, roles);
        var prediction = model.predict(input, excludeId: row['id'] as String);
        // 시작할 때도 사용자가 정한 통장 용도를 근거로 확인을 요청할 수 있다.
        if (prediction == null && row['type'] == 'transfer') {
          final purpose = {
            'saving': '적금',
            'travel': '여행저축',
            'emergency': '비상금',
          }[input.destinationRole];
          if (purpose != null) {
            prediction = PersonalPrediction(
              LearningLabel('transfer', purpose),
              0.5,
              0,
              '받는 통장에 지정한 용도를 바탕으로 추천했어요. 아직 학습 결과는 아니에요.',
            );
          }
        }
        if (prediction == null ||
            (row['pair_id'] != null && prediction.label.type != 'transfer')) {
          continue;
        }
        // 타입이 같아도 처음 보는 모델 추천은 확인하여 학습 정답으로 만든다.
        await db.insert('learning_suggestion', {
          'tx_id': row['id'],
          'type': prediction.label.type,
          'category': prediction.label.category,
          'score': prediction.score,
          'support': prediction.support,
          'evidence': prediction.evidence,
          'fingerprint': _learningFingerprint(row),
        });
      }
    });
  }

  Future<Map<String, PersonalSuggestion>> personalSuggestions() async {
    final rows = await _db.rawQuery(
      '''SELECT s.* FROM learning_suggestion s JOIN tx t
      ON t.id=s.tx_id WHERE t.deleted_at IS NULL''',
    );
    final currentRows = await _db.rawQuery(
      '''SELECT t.* FROM tx t JOIN learning_suggestion s
      ON t.id=s.tx_id WHERE t.deleted_at IS NULL''',
    );
    final transactions = {for (final row in currentRows) row['id']: row};
    final result = <String, PersonalSuggestion>{};
    for (final row in rows) {
      final tx = transactions[row['tx_id']];
      if (tx != null && _learningFingerprint(tx) == row['fingerprint']) {
        final suggestion = PersonalSuggestion.fromMap(row);
        result[suggestion.txId] = suggestion;
      }
    }
    return result;
  }

  Future<void> approvePersonalSuggestion(PersonalSuggestion suggestion) =>
      classifyTx(
        suggestion.txId,
        type: suggestion.type,
        category: suggestion.category,
        expectedSuggestion: suggestion.fingerprint,
        expectedRecommendedType: suggestion.type,
        expectedRecommendedCategory: suggestion.category,
      );

  Future<void> correctPersonalSuggestion(
    PersonalSuggestion suggestion, {
    required String type,
    required String category,
  }) => classifyTx(
    suggestion.txId,
    type: type,
    category: category,
    expectedSuggestion: suggestion.fingerprint,
    expectedRecommendedType: suggestion.type,
    expectedRecommendedCategory: suggestion.category,
  );

  Future<void> keepOriginalClassification(PersonalSuggestion suggestion) async {
    final rows = await _db.query(
      'tx',
      where: 'id=? AND deleted_at IS NULL',
      whereArgs: [suggestion.txId],
    );
    if (rows.isEmpty || rows.single['category'] == null) {
      throw StateError('기억할 분류를 먼저 선택해 주세요.');
    }
    await classifyTx(
      suggestion.txId,
      expectedSuggestion: suggestion.fingerprint,
    );
  }

  Future<int> personalExampleCount() async =>
      (await personalModel()).examples.length;

  Future<void> clearPersonalLearning() async {
    await _db.transaction((db) async {
      await db.delete('learning_example');
      await db.delete('learning_suggestion');
      // 초기화 이전 이력의 되돌리기가 지운 학습 자료를 다시 살리지 않도록 한다.
      await db.update('classification_history', {
        'sample_before': null,
        'sample_after': null,
      });
      await db.insert('kv', {
        'k': 'personal_learning_migrated',
        'v': '1',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _personalModel = null;
    _personalSignature = null;
  }
}

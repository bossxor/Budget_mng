part of 'repo.dart';

Future<void> ensureAutoPosting(Database db) async {
  await db.execute(
    '''CREATE TABLE IF NOT EXISTS auto_pattern(
    pattern_key TEXT PRIMARY KEY, scope_json TEXT NOT NULL, label TEXT NOT NULL,
    type TEXT,category TEXT,destination TEXT,enabled INTEGER DEFAULT 0,updated_at INTEGER NOT NULL)''',
  );
  await db.execute(
    '''CREATE TABLE IF NOT EXISTS auto_observation(
    tx_id TEXT PRIMARY KEY,pattern_key TEXT NOT NULL,fingerprint TEXT NOT NULL,
    proposed_json TEXT NOT NULL,matched INTEGER,decided_at INTEGER,created_at INTEGER NOT NULL)''',
  );
  final columns = await db.rawQuery('PRAGMA table_info(tx)');
  if (!columns.any((r) => r['name'] == 'auto_applied_key')) {
    await addColumnSafely(db, 'tx', 'auto_applied_key TEXT');
  }
  if (!columns.any((r) => r['name'] == 'auto_pair_before')) {
    await addColumnSafely(db, 'tx', 'auto_pair_before TEXT');
  }
}

class AutoPostingProgress {
  AutoPostingProgress(this.pattern, this.checked, this.correct, this.streak);
  final Map<String, Object?> pattern;
  final int checked, correct, streak;
  bool get ready => checked >= 10 && correct >= 9 && streak >= 5;
  bool get enabled => pattern['enabled'] == 1;
  bool get paused => pattern['enabled'] == 2;
  String get key => pattern['pattern_key'] as String;
}

String _autoText(String value) => value
    .replaceAll(RegExp(r'\d[\d,]*'), '#')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Future<void> pauseAutoForTx(DatabaseExecutor db, String id) async {
  final rows = await db.query('tx', where: 'id=?', whereArgs: [id]);
  final keys = <Object?>{if (rows.isNotEmpty) rows.single['auto_applied_key']};
  final observations = await db.query(
    'auto_observation',
    where: 'tx_id=?',
    whereArgs: [id],
  );
  if (observations.isNotEmpty) {
    keys.add(observations.single['pattern_key']);
  }
  await db.update(
    'auto_observation',
    {'matched': 0, 'decided_at': DateTime.now().microsecondsSinceEpoch},
    where: 'tx_id=? AND matched IS NOT NULL',
    whereArgs: [id],
  );
  for (final key in keys.whereType<String>()) {
    await db.update(
      'auto_pattern',
      {'enabled': 2, 'updated_at': DateTime.now().microsecondsSinceEpoch},
      where: 'pattern_key=? AND enabled=1',
      whereArgs: [key],
    );
  }
}

Future<void> recordAutoAnswer(
  DatabaseExecutor db,
  Map<String, Object?> before,
  Map<String, Object?>? after,
) async {
  final rows = await db.query(
    'auto_observation',
    where: 'tx_id=?',
    whereArgs: [before['id']],
  );
  if (rows.isEmpty) return;
  final observation = rows.single;
  if (observation['matched'] != null) return;
  if (observation['fingerprint'] != _learningFingerprint(before)) return;
  final proposed = jsonDecode(
    observation['proposed_json'] as String,
  ) as Map<String, dynamic>;
  final matches =
      after != null &&
      proposed.entries.every(
        (e) => e.key == 'party'
            ? TxRow.fromMap(after).title == e.value
            : after[e.key] == e.value,
      );
  await db.update(
    'auto_observation',
    {
      'matched': matches ? 1 : 0,
      'decided_at': DateTime.now().microsecondsSinceEpoch,
    },
    where: 'tx_id=?',
    whereArgs: [before['id']],
  );
  if (!matches) {
    await pauseAutoForTx(db, before['id'] as String);
  }
  if (after != null) {
    await db.update(
      'auto_pattern',
      {
        'type': after['type'],
        'category': after['category'],
        'destination': after['destination'],
        'label':
            '${before['notification_title'] ?? TxRow.fromMap(after).title} · ${after['category'] ?? '미분류'}',
        'updated_at': DateTime.now().microsecondsSinceEpoch,
      },
      where: 'pattern_key=? AND enabled<>1',
      whereArgs: [observation['pattern_key']],
    );
  }
}

extension AutoPosting on Repo {
  Future<String?> autoDestination(NotificationReview review) async {
    final rows = await _db.query(
      'tx',
      where: 'id=?',
      whereArgs: [review.tx.id],
    );
    if (rows.isEmpty) return null;
    final scope = await _autoScope(_db, rows.single);
    if (scope == null) return null;
    final key = sha256.convert(utf8.encode(jsonEncode(scope))).toString();
    final patterns = await _db.query(
      'auto_pattern',
      where: 'pattern_key=?',
      whereArgs: [key],
    );
    if (patterns.isEmpty || patterns.single['destination'] == null) return null;
    final dest = patterns.single['destination'] as String;
    return (await _db.query(
          'account',
          where: 'key=?',
          whereArgs: [dest],
        )).isEmpty
        ? null
        : dest;
  }

  Future<Map<String, Object?>?> _autoScope(
    DatabaseExecutor db,
    Map<String, Object?> row,
  ) async {
    if (row['notification_package'] == null ||
        row['raw_id'] == null ||
        row['account'] == null) {
      return null;
    }
    final raw = await db.query(
      'raw_notification',
      where: 'id=?',
      whereArgs: [row['raw_id']],
    );
    if (raw.isEmpty) return null;
    final r = raw.single;
    if (notificationKey(
          r['package'] as String,
          r['title'] as String? ?? '',
          r['text'] as String,
          r['posted_at'] as int,
        ) !=
        row['notification_key']) {
      return null;
    }
    Future<String> accountIdentity(Object? key) async {
      if (key == null) return '';
      final accounts = await db.query(
        'account',
        where: 'key=?',
        whereArgs: [key],
      );
      if (accounts.isNotEmpty &&
          accounts.single['bank_code'] != null &&
          accounts.single['account_number'] != null) {
        return '${accounts.single['bank_code']}:${accounts.single['account_number']}';
      }
      return key as String;
    }

    return {
      'package': row['notification_package'],
      'title': bankNotificationApps.contains(row['notification_package'])
          ? _autoText(row['notification_title'] as String? ?? '')
          : row['notification_title'] ?? '',
      'account': await accountIdentity(row['account']),
      'destination': await accountIdentity(row['destination']),
      'dir': row['dir'],
      'party': (row['counterparty'] ?? row['merchant'] ?? '').toString().trim(),
      'snippet': normalizedNotificationSnippet(_autoText(r['text'] as String)),
      'body_hash': sha256
          .convert(utf8.encode(_autoText(r['text'] as String)))
          .toString(),
    };
  }

  /// 화면에 실제 표시한 제안만 기록한다. 기존 승인 이력으로 적중률을 추정하지 않는다.
  Future<AutoPostingProgress?> observeAutoProposal(
    NotificationReview review, {
    required String type,
    String? category,
    String? destination,
  }) async {
    return _db.transaction((db) async {
      final row = await _checkedNotification(db, review);
      final scope = await _autoScope(db, row);
      if (scope == null ||
          !['income', 'expense', 'transfer'].contains(type) ||
          (row['amount'] as int) <= 0 ||
          row['memo'] == '중복 의심' ||
          row['pair_id'] != null) {
        return null;
      }
      final scopeJson = jsonEncode(scope),
          key = sha256.convert(utf8.encode(jsonEncode(scope))).toString();
      await db.insert('auto_pattern', {
        'pattern_key': key,
        'scope_json': scopeJson,
        'label':
            '${review.title.isEmpty ? review.tx.title : review.title} · ${category ?? '미분류'}',
        'type': type,
        'category': category,
        'destination': destination,
        'enabled': 0,
        'updated_at': DateTime.now().microsecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final proposed = {
        'type': type,
        'category': category,
        'amount': row['amount'],
        'party': review.tx.title,
        'destination': type == 'transfer' ? destination : null,
      };
      await db.insert('auto_observation', {
        'tx_id': row['id'],
        'pattern_key': key,
        'fingerprint': review.fingerprint,
        'proposed_json': jsonEncode(proposed),
        'created_at': DateTime.now().microsecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final existing = (await db.query(
        'auto_observation',
        where: 'tx_id=?',
        whereArgs: [row['id']],
      )).single;
      if (existing['matched'] == null &&
          (existing['fingerprint'] != review.fingerprint ||
              existing['proposed_json'] != jsonEncode(proposed))) {
        await db.update(
          'auto_observation',
          {
            'pattern_key': key,
            'fingerprint': review.fingerprint,
            'proposed_json': jsonEncode(proposed),
          },
          where: 'tx_id=?',
          whereArgs: [row['id']],
        );
      }
      return _autoProgress(db, key);
    });
  }

  Future<AutoPostingProgress> _autoProgress(
    DatabaseExecutor db,
    String key,
  ) async {
    final pattern = (await db.query(
      'auto_pattern',
      where: 'pattern_key=?',
      whereArgs: [key],
    )).single;
    final rows = await db.query(
      'auto_observation',
      where: 'pattern_key=? AND matched IS NOT NULL',
      whereArgs: [key],
      orderBy: 'decided_at DESC',
      limit: 10,
    );
    bool correct(Map<String, Object?> r) {
      final p =
          jsonDecode(r['proposed_json'] as String) as Map<String, dynamic>;
      return r['matched'] == 1 &&
          p['type'] == pattern['type'] &&
          p['category'] == pattern['category'];
    }

    var streak = 0;
    for (final r in rows) {
      if (!correct(r)) break;
      streak++;
    }
    return AutoPostingProgress(
      pattern,
      rows.length,
      rows.where(correct).length,
      streak,
    );
  }

  Future<AutoPostingProgress> autoProgress(String key) =>
      _autoProgress(_db, key);
  Future<List<AutoPostingProgress>> autoPatterns() async {
    final rows = await _db.query('auto_pattern', orderBy: 'updated_at DESC');
    return [
      for (final r in rows)
        await _autoProgress(_db, r['pattern_key'] as String),
    ];
  }

  Future<void> setAutoPosting(
    String key,
    bool enabled, {
    bool manual = false,
  }) async {
    await _db.transaction(
      (db) => _setAutoPosting(db, key, enabled, manual: manual),
    );
  }

  Future<void> _setAutoPosting(
    DatabaseExecutor db,
    String key,
    bool enabled, {
    bool manual = false,
  }) async {
    final progress = await _autoProgress(db, key);
    if (enabled && !manual && !progress.ready) {
      throw StateError('자동 반영 제안 기준에 아직 도달하지 않았어요.');
    }
    if (enabled) {
      final decision = await db.query(
        'auto_observation',
        where:
            'pattern_key=? AND matched IS NOT NULL${manual ? '' : ' AND matched=1'}',
        whereArgs: [key],
        orderBy: 'decided_at DESC',
        limit: 1,
      );
      if (decision.isEmpty) throw StateError('이 패턴의 실제 거래를 먼저 한 번 확인해 주세요.');
      final tx = await db.query(
        'tx',
        where: 'id=? AND deleted_at IS NULL AND status=?',
        whereArgs: [decision.single['tx_id'], 'ok'],
      );
      if (tx.isEmpty) throw StateError('최신 거래를 먼저 확인해 주세요.');
      final row = tx.single;
      if (row['category'] == null ||
          !['income', 'expense', 'transfer'].contains(row['type'])) {
        throw StateError('자동 반영할 분류를 먼저 선택해 주세요.');
      }
      await db.update(
        'auto_pattern',
        {
          'type': row['type'],
          'category': row['category'],
          'destination': row['destination'],
        },
        where: 'pattern_key=?',
        whereArgs: [key],
      );
    }
    await db.update(
      'auto_pattern',
      {
        'enabled': enabled ? 1 : 2,
        'updated_at': DateTime.now().microsecondsSinceEpoch,
      },
      where: 'pattern_key=?',
      whereArgs: [key],
    );
  }

  Future<bool> tryAutoPost(String id) async {
    return _db.transaction((db) async {
      final rows = await db.query(
        'tx',
        where: 'id=? AND deleted_at IS NULL',
        whereArgs: [id],
      );
      if (rows.isEmpty) return false;
      final row = rows.single;
      if (row['auto_applied_key'] != null ||
          row['pair_id'] != null ||
          row['memo'] == '중복 의심' ||
          (row['amount'] as int) <= 0 ||
          ['rejected'].contains(row['status'])) {
        return false;
      }
      final scope = await _autoScope(db, row);
      if (scope == null) return false;
      final key = sha256.convert(utf8.encode(jsonEncode(scope))).toString();
      final patterns = await db.query(
        'auto_pattern',
        where: 'pattern_key=? AND enabled=1',
        whereArgs: [key],
      );
      if (patterns.isEmpty) return false;
      final rule = patterns.single, type = rule['type'] as String;
      if (type != 'transfer' &&
          ((row['dir'] == 'in' && type != 'income') ||
              (row['dir'] == 'out' && type != 'expense'))) {
        return false;
      }
      if (type == 'transfer' &&
          rule['destination'] != null &&
          (await db.query(
            'account',
            where: 'key=?',
            whereArgs: [rule['destination']],
          )).isEmpty) {
        return false;
      }
      final before = {
        for (final field in [
          'type',
          'category',
          'destination',
          'status',
          'memo',
          'auto_applied_key',
        ])
          field: row[field],
      };
      final after = {
        ...before,
        'type': type,
        'category': rule['category'],
        'destination': rule['destination'],
        'status': 'ok',
        'memo': null,
        'auto_applied_key': key,
      };
      await db.insert('classification_history', {
        'id': _newId(),
        'batch': _newId(),
        'tx_id': id,
        'before_json': jsonEncode(before),
        'after_json': jsonEncode(after),
        'created_at': DateTime.now().microsecondsSinceEpoch,
        'undone': 0,
      });
      await db.update(
        'tx',
        {...after, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id=?',
        whereArgs: [id],
      );
      await db.delete('learning_suggestion', where: 'tx_id=?', whereArgs: [id]);
      if (row['account'] != null) {
        await db.insert('account', {
          'key': row['account'],
          'label': row['account'],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      return true;
    });
  }
}

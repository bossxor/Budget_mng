part of 'repo.dart';

Future<void> ensureNotificationFeedback(Database db) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS notif_feedback(
    notification_key TEXT PRIMARY KEY, tx_id TEXT, raw_id INTEGER, package TEXT,
    title TEXT, snippet TEXT, verdict TEXT, reason TEXT, note TEXT, at INTEGER,
    linked_tx_id TEXT, mute_title TEXT, mute_created_at INTEGER)''');
  // title=''은 앱 전체. SQLite의 NULL 복합 PK는 중복을 허용하므로 사용하지 않는다.
  await db.execute(
    '''CREATE TABLE IF NOT EXISTS notif_mute(
    package TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', reason TEXT,
    created_at INTEGER, blocked_count INTEGER DEFAULT 0, removed_at INTEGER, PRIMARY KEY(package,title))''',
  );
  final muteColumns = await db.rawQuery('PRAGMA table_info(notif_mute)');
  if (!muteColumns.any((c) => c['name'] == 'removed_at')) {
    await addColumnSafely(db, 'notif_mute', 'removed_at INTEGER');
  }
  final columns = await db.rawQuery('PRAGMA table_info(tx)');
  for (final name in [
    'notification_key',
    'notification_package',
    'notification_title',
  ]) {
    if (!columns.any((c) => c['name'] == name)) {
      await addColumnSafely(db, 'tx', '$name TEXT');
    }
  }
}

Future<Set<String>> _extraNotificationApps(DatabaseExecutor db) async {
  final rows = await db.query(
    'kv',
    where: 'k=?',
    whereArgs: ['extra_packages'],
  );
  return rows.isEmpty
      ? {}
      : (rows.single['v'] as String? ?? '')
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet();
}

Future<bool> _hasMutedNotification(
  DatabaseExecutor db,
  String package,
  String title,
) async {
  if (protectedNotificationSource(
    package,
    title,
    await _extraNotificationApps(db),
  )) {
    return false;
  }
  return (await db.query(
    'notif_mute',
    where: "removed_at IS NULL AND package=? AND (title='' OR title=?)",
    whereArgs: [package, title],
    limit: 1,
  )).isNotEmpty;
}

class NotificationReview {
  NotificationReview(
    this.tx,
    this.package,
    this.title,
    this.original,
    this.fingerprint, {
    required this.protectedSource,
  });
  final TxRow tx;
  final String package, title, fingerprint;
  final String? original;
  final bool protectedSource;
}

extension NotificationFeedback on Repo {
  /// 거래 여부와 분류를 같은 카드에서 한 번에 확인할 수 있는 제안.
  Future<PersonalPrediction?> proposeNotificationClassification(
    NotificationReview review,
  ) async {
    final row = await _checkedNotification(_db, review);
    if (row['memo'] == '중복 의심' || (row['amount'] as int) <= 0) return null;
    final input = await _learningInput(_db, row);
    final prediction = (await personalModel()).predict(
      input,
      excludeId: review.tx.id,
    );
    if (prediction != null) return prediction;
    if (row['type'] != 'transfer') return null;
    final purpose = {
      'saving': '적금',
      'travel': '여행저축',
      'emergency': '비상금',
    }[input.destinationRole];
    return purpose == null
        ? null
        : PersonalPrediction(
            LearningLabel('transfer', purpose),
            0.5,
            0,
            '받는 통장에 지정한 용도를 바탕으로 추천했어요. 아직 학습 결과는 아니에요.',
          );
  }

  Future<NotificationAssessment?> assessNotification(
    NotificationReview review,
  ) async {
    if (review.original == null) return null;
    final rows = await _db.query(
      'notif_feedback',
      where: "package=? AND snippet IS NOT NULL AND (verdict IN ('yes','fixed') OR (verdict='no' AND reason IN ('chat','ad','otp','other')))",
      whereArgs: [review.package],
      orderBy: 'at DESC',
      limit: 500,
    );
    return NotificationClassifier([
      for (final r in rows)
        NotificationExample(
          r['notification_key'] as String,
          r['package'] as String,
          r['title'] as String? ?? '',
          r['snippet'] as String,
          r['verdict'] != 'no',
        ),
    ]).predict(
      review.package,
      review.title,
      review.original!,
      excludeId: await _notificationKeyFor(review.tx.id),
    );
  }

  Future<String?> _notificationKeyFor(String id) async {
    final rows = await _db.query(
      'tx',
      columns: ['notification_key'],
      where: 'id=?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : rows.single['notification_key'] as String?;
  }

  /// 미확인 범용 기록만 재검토한다. 사용자 승인·정산·분할·쌍 이체는 보존한다.
  Future<void> prepareNotificationReview() async {
    await _db.transaction((db) async {
      if ((await db.query(
        'kv',
        where: 'k=?',
        whereArgs: ['notification_review_v1'],
      )).isNotEmpty) {
        return;
      }
      final rows = await db.rawQuery(
        '''SELECT t.*,r.package AS origin_package,r.title AS origin_title,
        r.text AS origin_text,r.posted_at AS origin_at,
        EXISTS(SELECT 1 FROM classification_history h WHERE h.tx_id=t.id AND h.undone=0)
          OR EXISTS(SELECT 1 FROM learning_example e WHERE e.tx_id=t.id)
          OR EXISTS(SELECT 1 FROM settlement_item si WHERE si.tx_id=t.id)
          OR EXISTS(SELECT 1 FROM settlement_payment sp WHERE sp.tx_id=t.id)
          OR EXISTS(SELECT 1 FROM tx_split ts WHERE ts.tx_id=t.id)
          OR EXISTS(SELECT 1 FROM tx_tag tt WHERE tt.tx_id=t.id) AS user_action
        FROM tx t JOIN raw_notification r ON r.id=t.raw_id
        WHERE t.deleted_at IS NULL AND t.notification_key IS NULL''',
      );
      var migrated = 0;
      for (final row in rows) {
        final package = row['origin_package'] as String,
            title = row['origin_title'] as String? ?? '';
        final text = row['origin_text'] as String, at = row['origin_at'] as int;
        final parsed = parseNotification(
          joinNotification(title, text),
          DateTime.fromMillisecondsSinceEpoch(at),
        );
        final guessed = guessFromText(joinNotification(title, text));
        final amount = parsed?.amount ?? guessed.amount;
        final timestamp = parsed?.occurredAt.millisecondsSinceEpoch ?? at;
        // 백업의 raw_id가 다른 알림을 가리킬 수 있어 내용 일치도 검사한다.
        if (amount != row['amount'] ||
            timestamp != row['occurred_at'] ||
            (parsed != null && parsed.source != row['source']) ||
            (parsed == null && row['source'] != package)) {
          continue;
        }
        final change = <String, Object?>{
          'notification_key': notificationKey(package, title, text, at),
          'notification_package': package,
          'notification_title': title,
        };
        if (!trustedNotification(
              package,
              title,
              row['source'] as String? ?? '',
            ) &&
            row['user_action'] == 0 &&
            row['pair_id'] == null) {
          change['status'] = 'candidate';
          migrated++;
          await db.delete(
            'learning_suggestion',
            where: 'tx_id=?',
            whereArgs: [row['id']],
          );
        }
        await db.update('tx', change, where: 'id=?', whereArgs: [row['id']]);
      }
      await db.insert('kv', {
        'k': 'notification_review_v1',
        'v': '1',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('kv', {
        'k': 'notification_review_migrated_count',
        'v': '$migrated',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<NotificationReview?> notificationReview(String id) async {
    final rows = await _db.query(
      'tx',
      where: 'id=? AND deleted_at IS NULL',
      whereArgs: [id],
    );
    if (rows.isEmpty || rows.single['notification_key'] == null) return null;
    final row = rows.single,
        package = row['notification_package'] as String,
        title = row['notification_title'] as String? ?? '';
    String? original;
    final raw = row['raw_id'] == null
        ? <Map<String, Object?>>[]
        : await _db.query(
            'raw_notification',
            where: 'id=?',
            whereArgs: [row['raw_id']],
          );
    if (raw.isNotEmpty &&
        notificationKey(
              raw.single['package'] as String,
              raw.single['title'] as String? ?? '',
              raw.single['text'] as String,
              raw.single['posted_at'] as int,
            ) ==
            row['notification_key']) {
      original = joinNotification(
        raw.single['title'] as String?,
        raw.single['text'] as String,
      );
    }
    return NotificationReview(
      TxRow.fromMap(row),
      package,
      title,
      original,
      _learningFingerprint(row),
      protectedSource: protectedNotificationSource(
        package,
        title,
        await _extraNotificationApps(_db),
      ),
    );
  }

  Future<Map<String, Object?>> _checkedNotification(
    DatabaseExecutor db,
    NotificationReview review,
  ) async {
    final rows = await db.query(
      'tx',
      where: 'id=? AND deleted_at IS NULL',
      whereArgs: [review.tx.id],
    );
    if (rows.isEmpty ||
        _learningFingerprint(rows.single) != review.fingerprint) {
      throw StateError('내역이 변경되었어요. 알림을 다시 확인해 주세요.');
    }
    return rows.single;
  }

  Future<void> _feedback(
    DatabaseExecutor db,
    Map<String, Object?> row,
    NotificationReview review,
    String verdict, {
    String? reason,
    String? note,
    String? linkedId,
    String? muteTitle,
    int? muteAt,
  }) async {
    await db.insert('notif_feedback', {
      'notification_key': row['notification_key'],
      'tx_id': row['id'],
      'raw_id': row['raw_id'],
      'package': review.package,
      'title': review.title,
      'snippet': normalizedNotificationSnippet(
        review.original ?? review.tx.title,
      ),
      'verdict': verdict,
      'reason': reason,
      'note': note,
      'at': DateTime.now().microsecondsSinceEpoch,
      'linked_tx_id': linkedId,
      'mute_title': muteTitle,
      'mute_created_at': muteAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.execute(
      '''UPDATE notif_feedback SET snippet=NULL WHERE notification_key NOT IN
      (SELECT notification_key FROM notif_feedback ORDER BY at DESC LIMIT 500)''',
    );
  }

  Future<void> confirmNotification(
    NotificationReview review, {
    int? amount,
    String? type,
    String? party,
    String? category,
    String? destination,
    String? reason,
  }) async {
    await migratePersonalApprovals();
    await _db.transaction((db) async {
      final row = await _checkedNotification(db, review);
      if (row['status'] == 'rejected') throw StateError('숨긴 알림을 먼저 되돌려 주세요.');
      final kind = type ?? row['type'] as String,
          value = amount ?? row['amount'] as int;
      if (!['income', 'expense', 'transfer', 'group'].contains(kind) ||
          value == 0 ||
          (value < 0 && kind != 'expense')) {
        throw ArgumentError('금액과 방향을 확인해 주세요.');
      }
      if (row['pair_id'] != null &&
          (kind != row['type'] || value != row['amount'])) {
        throw ArgumentError('연결된 이체는 거래 상세에서 수정해 주세요.');
      }
      String? dest = destination;
      if (dest != null) {
        final aliases = await db.query(
          'account_alias',
          where: 'alias=?',
          whereArgs: [dest],
        );
        if (aliases.isNotEmpty) dest = aliases.single['canonical'] as String;
        if (dest == row['account'] ||
            (await db.query(
              'account',
              where: 'key=?',
              whereArgs: [dest],
            )).isEmpty) {
          throw ArgumentError('다른 내 통장을 선택해 주세요.');
        }
      }
      final fields = [
        'type',
        'amount',
        'merchant',
        'counterparty',
        'category',
        'status',
        'memo',
        'dir',
        'destination',
      ];
      final before = {for (final f in fields) f: row[f]};
      final after = <String, Object?>{
        ...before,
        'type': kind,
        'amount': value,
        'status': 'ok',
        'memo': null,
        'dir': kind == 'income'
            ? 'in'
            : kind == 'expense'
            ? 'out'
            : row['dir'],
        'category': ?category,
        if (kind == 'transfer' && dest != null) 'destination': dest,
        if (kind != 'transfer') 'destination': null,
        if (party != null) 'merchant': party.trim(),
        if (party != null) 'counterparty': party.trim(),
      };
      if (kind == 'transfer' && after['category'] == null) {
        after['category'] = '내 계좌 이체';
      }
      final previous = await db.query(
        'learning_example',
        where: 'tx_id=?',
        whereArgs: [row['id']],
      );
      await db.delete(
        'learning_example',
        where: 'tx_id=?',
        whereArgs: [row['id']],
      );
      final sample = await _rememberApproval(db, {...row, ...after});
      await db.insert('classification_history', {
        'id': _newId(),
        'batch': _newId(),
        'tx_id': row['id'],
        'before_json': jsonEncode(before),
        'after_json': jsonEncode(after),
        'created_at': DateTime.now().microsecondsSinceEpoch,
        'undone': 0,
        'sample_before': previous.isEmpty ? null : jsonEncode(previous.single),
        'sample_after': sample == null ? null : jsonEncode(sample),
      });
      await db.update(
        'tx',
        {...after, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id=?',
        whereArgs: [row['id']],
      );
      if (row['account'] != null && kind != 'group') {
        await db.insert('account', {
          'key': row['account'],
          'label': row['account'],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await db.delete(
        'learning_suggestion',
        where: 'tx_id=?',
        whereArgs: [row['id']],
      );
      await _feedback(
        db,
        row,
        review,
        (amount != null || type != null || party != null || category != null)
            ? 'fixed'
            : 'yes',
        reason: reason,
      );
    });
  }

  Future<List<TxRow>> notificationDuplicates(NotificationReview review) async {
    final rows = await _db.query(
      'tx',
      where: "deleted_at IS NULL AND status='ok' AND id<>? AND amount=? AND type=? AND ABS(occurred_at-?)<=86400000",
      whereArgs: [
        review.tx.id,
        review.tx.amount,
        review.tx.type,
        review.tx.occurredAt.millisecondsSinceEpoch,
      ],
      orderBy: 'occurred_at DESC',
      limit: 20,
    );
    return rows.map(TxRow.fromMap).toList();
  }

  Future<void> rejectNotification(
    NotificationReview review, {
    required String reason,
    String muteScope = 'none',
    String? note,
    String? duplicateId,
  }) async {
    if (!notificationReasons.containsKey(reason) || reason == 'own_transfer') {
      throw ArgumentError('거절 이유를 선택해 주세요.');
    }
    if (reason == 'other' && (note == null || note.trim().isEmpty)) {
      throw ArgumentError('다른 이유를 적어 주세요.');
    }
    if (!['none', 'title', 'app'].contains(muteScope) ||
        (reason != 'chat' && muteScope != 'none')) {
      throw ArgumentError('숨김 범위를 확인해 주세요.');
    }
    await _db.transaction((db) async {
      final row = await _checkedNotification(db, review);
      if (row['status'] == 'rejected') {
        throw StateError('이미 숨긴 알림이에요. 먼저 되돌려 주세요.');
      }
      if (row['pair_id'] != null ||
          (await db.query(
            'settlement_item',
            where: 'tx_id=?',
            whereArgs: [row['id']],
          )).isNotEmpty ||
          (await db.query(
            'settlement_payment',
            where: 'tx_id=?',
            whereArgs: [row['id']],
          )).isNotEmpty) {
        throw StateError('연결된 내역을 먼저 해제한 뒤 확인해 주세요.');
      }
      if (reason == 'duplicate') {
        if (duplicateId == null) {
          throw ArgumentError('같은 거래로 연결할 기존 내역을 선택해 주세요.');
        }
        final target = await db.query(
          'tx',
          where: "id=? AND id<>? AND deleted_at IS NULL AND status='ok' AND amount=? AND type=?",
          whereArgs: [duplicateId, row['id'], row['amount'], row['type']],
        );
        if (target.isEmpty) throw ArgumentError('같은 거래로 연결할 기존 내역을 선택해 주세요.');
      }
      String? muteTitle;
      int? muteAt;
      if (muteScope != 'none' &&
          !protectedNotificationSource(
            review.package,
            review.title,
            await _extraNotificationApps(db),
          )) {
        if (muteScope == 'title' && review.title.isEmpty) {
          throw ArgumentError('대화방 제목이 없어 방 단위로 숨길 수 없어요.');
        }
        muteTitle = muteScope == 'app' ? '' : review.title;
        muteAt = DateTime.now().microsecondsSinceEpoch;
        await db.insert('notif_mute', {
          'package': review.package,
          'title': muteTitle,
          'reason': 'chat',
          'created_at': muteAt,
          'blocked_count': 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await db.update(
        'tx',
        {
          'status': 'rejected',
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id=?',
        whereArgs: [row['id']],
      );
      await db.delete(
        'learning_example',
        where: 'tx_id=?',
        whereArgs: [row['id']],
      );
      await db.delete(
        'learning_suggestion',
        where: 'tx_id=?',
        whereArgs: [row['id']],
      );
      await _feedback(
        db,
        row,
        review,
        'no',
        reason: reason,
        note: note,
        linkedId: duplicateId,
        muteTitle: muteTitle,
        muteAt: muteAt,
      );
    });
  }

  Future<List<Map<String, Object?>>> hiddenNotificationFeedback() =>
      _db.query('notif_feedback', where: "verdict='no'", orderBy: 'at DESC');
  Future<List<Map<String, Object?>>> notificationMuteRules() => _db.query(
    'notif_mute',
    where: 'removed_at IS NULL',
    orderBy: 'created_at DESC',
  );

  Future<void> restoreNotification(String key) async {
    await _db.transaction((db) async {
      final feedback = await db.query(
        'notif_feedback',
        where: 'notification_key=?',
        whereArgs: [key],
      );
      if (feedback.isEmpty || feedback.single['verdict'] != 'no') {
        throw StateError('되돌릴 알림이 없어요.');
      }
      final f = feedback.single;
      if (f['mute_title'] != null) {
        await db.update(
          'notif_mute',
          {'removed_at': DateTime.now().microsecondsSinceEpoch},
          where: 'package=? AND title=? AND created_at=?',
          whereArgs: [f['package'], f['mute_title'], f['mute_created_at']],
        );
      }
      await db.update(
        'notif_feedback',
        {'verdict': 'undone', 'at': DateTime.now().microsecondsSinceEpoch},
        where: 'notification_key=?',
        whereArgs: [key],
      );
      await db.update(
        'tx',
        {
          'status': 'candidate',
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where:
            "notification_key=? AND deleted_at IS NULL AND status='rejected'",
        whereArgs: [key],
      );
    });
  }

  Future<void> removeNotificationMute(String package, String title) async {
    await _db.update(
      'notif_mute',
      {'removed_at': DateTime.now().microsecondsSinceEpoch},
      where: 'package=? AND title=?',
      whereArgs: [package, title],
    );
  }
}

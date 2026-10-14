import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/classify.dart';
import '../core/parsers.dart';
import 'budget_repo.dart';
import 'extras.dart';
import 'planning_repo.dart';
import 'settlement_repo.dart';

class TxRow {
  TxRow(this.id, this.type, this.amount, this.title, this.category,
      this.occurredAt, this.account, this.status, this.memo);
  final String id;
  final String type; // expense | income | transfer | group
  final int amount;
  final String title;
  final String? category;
  final DateTime occurredAt;
  final String? account;
  final String status; // ok | review
  final String? memo;
  String? note; // 사용자 메모

  /// 정산에 묶인 지출이면 내 몫, 아니면 null.
  int? mine;

  /// 정산에 연결된 입금액.
  int paid = 0;

  /// 가계부 집계에 쓰는 금액 (정산 반영 후).
  int get effective => type == 'income' ? amount - paid : (mine ?? amount);

  factory TxRow.fromMap(Map<String, Object?> m) => TxRow(
        m['id'] as String,
        m['type'] as String,
        m['amount'] as int,
        (m['merchant'] ?? m['counterparty'] ?? '(알 수 없음)') as String,
        m['category'] as String?,
        DateTime.fromMillisecondsSinceEpoch(m['occurred_at'] as int),
        m['account'] as String?,
        (m['status'] ?? 'ok') as String,
        m['memo'] as String?,
      )..note = m['note'] as String?;
}

class TxSplit {
  TxSplit(this.category, this.amount, [this.memo]);
  final String category;
  final int amount;
  final String? memo;
}

class GapAlert {
  GapAlert(this.id, this.account, this.amount, this.at);
  final String id;
  final String account;
  final int amount; // +면 알림에 없던 입금이, −면 알림에 없던 출금이 있었다
  final DateTime at;
}

class SourceStatus {
  SourceStatus(this.package, this.last, this.count);
  final String package;
  final DateTime last;
  final int count;
}

class AccountRow {
  AccountRow(this.key, this.label, this.role, this.balance,
      {this.monthlyTarget, this.goalAmount, this.goalDate, this.paysFrom});
  final String key;
  final String label;
  final String role;
  final int? balance;
  final int? monthlyTarget; // 매월 채우기로 한 금액
  final int? goalAmount; // 목표 금액
  final DateTime? goalDate; // 목표 기한
  final String? paysFrom; // 카드: 대금이 빠지는 통장 key
}

class MonthSummary {
  MonthSummary(this.expense, this.income, this.byCategory, this.reviewCount);
  final int expense;
  final int income;
  final Map<String, int> byCategory;
  final int reviewCount;
}

const roles = {
  'living': '생활비',
  'saving': '적금',
  'travel': '여행비',
  'bills': '공과금',
  'income': '수입',
  'emergency': '비상금',
  'unset': '미지정',
};

class Repo {
  Repo._(this._db)
      : settlements = SettlementRepo(_db),
        planning = PlanningRepo(_db),
        tags = TagRepo(_db),
        budget = BudgetRepo(_db);
  final Database _db;
  final SettlementRepo settlements;
  final PlanningRepo planning;
  final TagRepo tags;
  final BudgetRepo budget;

  /// 백업/검색 같은 부가 기능이 쓰는 원본 DB.
  Database get db => _db;

  static Future<Repo> open() async {
    final path = p.join(await getDatabasesPath(), 'budget.db');
    final db = await openDatabase(path, version: 1, onCreate: (d, v) async {
      await _schema(d);
    }, onOpen: (d) async {
      // 네이티브 서비스가 먼저 파일을 만든 경우를 위해 항상 보장.
      await _schema(d);
    });
    return Repo._(db);
  }

  /// 테스트용: 이미 열린 DB로 Repo를 만든다.
  static Future<Repo> fromDb(Database d) async {
    await _schema(d);
    return Repo._(d);
  }

  static Future<void> _schema(Database d) async {
    await d.execute('''CREATE TABLE IF NOT EXISTS raw_notification(
      id INTEGER PRIMARY KEY AUTOINCREMENT, package TEXT, title TEXT, text TEXT,
      posted_at INTEGER, state INTEGER DEFAULT 0, UNIQUE(package, text, posted_at))''');
    await d.execute('''CREATE TABLE IF NOT EXISTS tx(
      id TEXT PRIMARY KEY, type TEXT, amount INTEGER, merchant TEXT, counterparty TEXT,
      category TEXT, occurred_at INTEGER, account TEXT, source TEXT, status TEXT DEFAULT 'ok',
      raw_id INTEGER, balance INTEGER, memo TEXT, installment_months INTEGER,
      updated_at INTEGER, deleted_at INTEGER)''');
    await d.execute(
        'CREATE INDEX IF NOT EXISTS tx_time ON tx(occurred_at)');
    await d.execute('CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT)');
    await d.execute('''CREATE TABLE IF NOT EXISTS account(
      key TEXT PRIMARY KEY, label TEXT, role TEXT DEFAULT 'unset')''');
    await d.execute(
        'CREATE TABLE IF NOT EXISTS rule(keyword TEXT PRIMARY KEY, category TEXT)');
    for (final c in const [
      'monthly_target INTEGER',
      'goal_amount INTEGER',
      'goal_date INTEGER',
      'pays_from TEXT',
    ]) {
      try {
        await d.execute('ALTER TABLE account ADD COLUMN $c');
      } catch (_) {}
    }
    try {
      await d.execute('ALTER TABLE tx ADD COLUMN dir TEXT');
    } catch (_) {}
    // 사용자가 적는 메모. memo 컬럼은 '중복 의심' 같은 검토 표시로 쓴다.
    try {
      await d.execute('ALTER TABLE tx ADD COLUMN note TEXT');
    } catch (_) {}
    await d.execute('''CREATE TABLE IF NOT EXISTS allocation(
      id TEXT PRIMARY KEY, from_key TEXT, to_key TEXT, amount INTEGER, day INTEGER)''');
    await d.execute('''CREATE TABLE IF NOT EXISTS gap_alert(
      id TEXT PRIMARY KEY, account TEXT, amount INTEGER, at INTEGER, resolved INTEGER DEFAULT 0)''');
    await d.execute('''CREATE TABLE IF NOT EXISTS tx_tag(
      tx_id TEXT, tag TEXT, PRIMARY KEY(tx_id, tag))''');
    await d.execute('''CREATE TABLE IF NOT EXISTS tx_split(
      id TEXT PRIMARY KEY, tx_id TEXT, category TEXT, amount INTEGER, memo TEXT)''');
    await BudgetRepo.schema(d);
    await SettlementRepo.schema(d);
  }

  // ---- kv ----
  Future<String?> getKv(String k) async {
    final r = await _db.query('kv', where: 'k=?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  Future<void> setKv(String k, String v) => _db.insert(
      'kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);

  // ---- identity / rules ----
  Future<Identity> identity() async {
    final names = ((await getKv('my_names')) ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    final keys = (await _db.query('account', columns: ['key']))
        .map((r) => r['key'] as String)
        .toSet();
    return Identity(names: names, accountAliases: keys);
  }

  Future<Map<String, String>> learnedRules() async {
    final r = await _db.query('rule');
    return {for (final x in r) x['keyword'] as String: x['category'] as String};
  }

  // ---- ingest ----
  int _seq = 0;
  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';

  /// 네이티브 서비스가 쌓아 둔 원문을 파싱해 거래로 저장한다. 처리한 건수를 반환.
  Future<int> processPending() async {
    final raws = await _db.query('raw_notification',
        where: 'state=0', orderBy: 'posted_at ASC');
    if (raws.isEmpty) return 0;
    final me = await identity();
    final learned = await learnedRules();
    final extra = ((await getKv('extra_packages')) ?? '').split(',');
    var saved = 0;
    for (final r in raws) {
      // 앱과 백그라운드 엔진이 동시에 돌아도 같은 알림을 두 번 처리하지 않게 먼저 선점한다.
      final claimed = await _db.rawUpdate(
          'UPDATE raw_notification SET state=3 WHERE id=? AND state=0',
          [r['id']]);
      if (claimed == 0) continue;
      final received = DateTime.fromMillisecondsSinceEpoch(r['posted_at'] as int);
      final raw = joinNotification(r['title'] as String?, r['text'] as String);
      var parsed = parseNotification(raw, received);
      // 직접 추가한 앱은 템플릿이 없으므로 금액/방향만 짐작해 저장한다 (검토 목록에서 고칠 수 있다).
      // ponytail: 취소/환불은 방향을 알 수 없어 "인식 못 한 알림"으로 남긴다.
      if (parsed == null &&
          extra.contains(r['package']) &&
          !raw.contains(RegExp('취소|환불'))) {
        final g = guessFromText(raw);
        if (g.amount != null && g.amount! > 0) {
          parsed = ParsedTx(
              source: r['package'] as String,
              type: g.type,
              amount: g.amount!,
              occurredAt: received,
              merchant: g.type == 'expense' ? g.title : null,
              counterparty: g.type == 'income' ? g.title : null);
        }
      }
      if (parsed == null) {
        await _db.update('raw_notification', {'state': 2},
            where: 'id=?', whereArgs: [r['id']]);
        continue;
      }
      final dir = parsed.type == 'expense'
          ? 'out'
          : parsed.type == 'income'
              ? 'in'
              : null;
      classify(parsed, me, learned);
      await _insertParsed(parsed, r['id'] as int, r['package'] as String, dir);
      await _db.update('raw_notification', {'state': 1},
          where: 'id=?', whereArgs: [r['id']]);
      saved++;
    }
    return saved;
  }

  Future<void> _insertParsed(
      ParsedTx t, int rawId, String package, String? dir) async {
    final at = t.occurredAt.millisecondsSinceEpoch;
    var status = 'ok';
    String? memo;
    // 같은 금액이 다른 앱에서 2분 안에 또 오면 중복 의심.
    final dup = await _db.rawQuery('''SELECT t.id FROM tx t JOIN raw_notification r ON r.id=t.raw_id
      WHERE t.deleted_at IS NULL AND t.type=? AND t.amount=? AND ABS(t.occurred_at-?)<=120000
        AND r.package<>? LIMIT 1''', [t.type, t.amount, at, package]);
    if (dup.isNotEmpty) {
      status = 'review';
      memo = '중복 의심';
    } else if (t.type == 'expense' && t.category == null) {
      status = 'review';
      memo = '미분류';
    }
    final id = _newId();
    final acctKey = t.account ?? t.card;
    if (status == 'ok' &&
        t.balance != null &&
        acctKey != null &&
        dir != null &&
        t.type != 'group') {
      // 직전 잔액에서 이번 금액을 더하고 뺀 값이 알림의 잔액과 다르면 그 사이 알림이 빠진 것이다.
      final prev = await _db.rawQuery(
          'SELECT balance FROM tx WHERE account=? AND balance IS NOT NULL AND deleted_at IS NULL AND occurred_at<=? ORDER BY occurred_at DESC LIMIT 1',
          [acctKey, at]);
      if (prev.isNotEmpty) {
        final pb = prev.first['balance'] as int;
        final expected = dir == 'in' ? pb + t.amount : pb - t.amount;
        final gap = t.balance! - expected;
        if (gap != 0) {
          await _db.insert('gap_alert', {
            'id': _newId(),
            'account': acctKey,
            'amount': gap,
            'at': at,
          });
        }
      }
    }
    await _db.insert('tx', {
      'id': id,
      'type': t.type,
      'amount': t.amount,
      'merchant': t.merchant,
      'counterparty': t.counterparty,
      'category': t.category,
      'occurred_at': at,
      'account': t.account ?? t.card,
      'source': t.source,
      'status': status,
      'raw_id': rawId,
      'balance': t.balance,
      'memo': memo,
      'installment_months': t.installmentMonths,
      'dir': dir,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
    if (t.account != null || t.card != null) {
      final key = (t.account ?? t.card)!;
      if (t.type != 'group') {
        await _db.insert('account', {'key': key, 'label': key},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    await _pairTransfers(id, t, at);
  }

  /// 다른 계좌에서 같은 금액의 반대 거래가 5분 안에 있으면 둘 다 이체로 묶는다.
  Future<void> _pairTransfers(String id, ParsedTx t, int at) async {
    if (t.type != 'expense' && t.type != 'income') return;
    final opposite = t.type == 'expense' ? 'income' : 'expense';
    final mine = t.account ?? t.card;
    final r = await _db.query('tx',
        where:
            "type=? AND amount=? AND ABS(occurred_at-?)<=300000 AND deleted_at IS NULL AND id<>? AND IFNULL(account,'')<>?",
        whereArgs: [opposite, t.amount, at, id, mine ?? ''],
        limit: 1);
    if (r.isEmpty || t.amount <= 0) return;
    for (final x in [id, r.first['id'] as String]) {
      await _db.update('tx', {'type': 'transfer'},
          where: 'id=?', whereArgs: [x]);
    }
  }

  Future<void> addManual({
    required String type,
    required int amount,
    required String title,
    String? category,
    DateTime? at,
    String? memo,
  }) async {
    await _db.insert('tx', {
      'id': _newId(),
      'type': type,
      'amount': amount,
      'merchant': title,
      'category': category ?? categorize(title, await learnedRules()),
      'occurred_at': (at ?? DateTime.now()).millisecondsSinceEpoch,
      'account': '현금',
      'source': 'manual',
      'status': 'ok',
      'dir': type == 'income' ? 'in' : 'out',
      'memo': memo,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // ---- queries ----
  Future<List<TxRow>> monthTx(DateTime month) async {
    final from = DateTime(month.year, month.month).millisecondsSinceEpoch;
    final to = DateTime(month.year, month.month + 1).millisecondsSinceEpoch;
    final r = await _db.query('tx',
        where: 'occurred_at>=? AND occurred_at<? AND deleted_at IS NULL',
        whereArgs: [from, to],
        orderBy: 'occurred_at DESC');
    final rows = r.map(TxRow.fromMap).toList();
    final mine = await settlements.myAmountByTx();
    final paid = await settlements.paidByTx();
    for (final t in rows) {
      t.mine = mine[t.id];
      t.paid = paid[t.id] ?? 0;
    }
    return rows;
  }

  Future<MonthSummary> summary(DateTime month) async {
    final rows = await monthTx(month);
    final splits = await _splitsFor(rows.map((t) => t.id).toList());
    var exp = 0, inc = 0, review = 0;
    final cat = <String, int>{};
    for (final t in rows) {
      if (t.status == 'review') review++;
      if (t.type == 'expense') {
        exp += t.effective;
        final sp = splits[t.id];
        if (sp != null && sp.isNotEmpty && t.amount > 0) {
          // 분할된 결제는 카테고리별로 나눠 센다 (정산 몫이 있으면 같은 비율로 축소).
          var left = t.effective;
          for (var i = 0; i < sp.length; i++) {
            final part = i == sp.length - 1
                ? left
                : (sp[i].amount * t.effective / t.amount).round();
            left -= part;
            cat[sp[i].category] = (cat[sp[i].category] ?? 0) + part;
          }
        } else {
          final c = t.category ?? '미분류';
          cat[c] = (cat[c] ?? 0) + t.effective;
        }
      } else if (t.type == 'income') {
        inc += t.effective;
      }
    }
    return MonthSummary(exp, inc, cat, review);
  }

  Future<Map<String, List<TxSplit>>> _splitsFor(List<String> ids) async {
    if (ids.isEmpty) return {};
    final out = <String, List<TxSplit>>{};
    // SQLite 변수 개수 제한을 피하려고 나눠서 조회한다.
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final r = await _db.query('tx_split',
          where: 'tx_id IN (${List.filled(chunk.length, '?').join(',')})',
          whereArgs: chunk,
          orderBy: 'rowid');
      for (final m in r) {
        out.putIfAbsent(m['tx_id'] as String, () => []).add(TxSplit(
            m['category'] as String, m['amount'] as int, m['memo'] as String?));
      }
    }
    return out;
  }

  Future<List<TxSplit>> splitsOf(String txId) async =>
      (await _splitsFor([txId]))[txId] ?? [];

  /// 분할을 통째로 교체한다. 빈 목록이면 분할을 해제한다.
  Future<void> saveSplits(String txId, List<TxSplit> parts) async {
    await _db.delete('tx_split', where: 'tx_id=?', whereArgs: [txId]);
    for (final p in parts) {
      await _db.insert('tx_split', {
        'id': _newId(),
        'tx_id': txId,
        'category': p.category,
        'amount': p.amount,
        'memo': p.memo,
      });
    }
  }

  // ---- 누락 감지 ----
  Future<List<GapAlert>> gaps() async {
    final r = await _db.query('gap_alert',
        where: 'resolved=0', orderBy: 'at DESC');
    return r
        .map((m) => GapAlert(m['id'] as String, m['account'] as String,
            m['amount'] as int, DateTime.fromMillisecondsSinceEpoch(m['at'] as int)))
        .toList();
  }

  Future<void> resolveGap(String id) => _db.update('gap_alert', {'resolved': 1},
      where: 'id=?', whereArgs: [id]);

  // ---- 수집 상태 / 보관 ----
  /// 인식 못 한 알림을 사용자가 직접 처리(수동 입력 또는 무시)했다고 표시한다.
  Future<void> markRawHandled(int id) => _db.update(
      'raw_notification', {'state': 4}, where: 'id=?', whereArgs: [id]);

  /// 인식에 실패한 알림 중 광고이거나 금융 키워드가 없는 것은 개인정보만 쌓이므로 지운다.
  Future<int> purgeNoise() => _db.delete('raw_notification', where: '''state=2 AND (
      text LIKE '%(광고)%' OR text LIKE '%수신거부%' OR text LIKE '%알림끄기%' OR
      NOT (text LIKE '%입금%' OR text LIKE '%출금%' OR text LIKE '%승인%' OR
           text LIKE '%취소%' OR text LIKE '%결제%' OR text LIKE '%이체%' OR
           text LIKE '%송금%' OR text LIKE '%잔액%'))''');

  /// 알림 서비스가 화면 없이 호출하는 처리. 끝난 시각과 건수를 남겨 설정 화면에서 확인할 수 있다.
  Future<int> runBackgroundIngest({DateTime? now}) async {
    final n = await processPending();
    await setKv('bg_last_run', '${(now ?? DateTime.now()).millisecondsSinceEpoch}');
    await setKv('bg_last_saved', '$n');
    final total = int.tryParse(await getKv('bg_total_saved') ?? '') ?? 0;
    await setKv('bg_total_saved', '${total + n}');
    return n;
  }

  /// 앱이 죽어서 처리 중으로 남은 알림을 다시 대기 상태로 돌린다 (앱 시작 시 한 번).
  Future<void> recoverClaims() => _db
      .rawUpdate('UPDATE raw_notification SET state=0 WHERE state=3');

  /// 수집원(패키지)별 마지막 수신 시각과 건수.
  Future<List<SourceStatus>> sourceStatus() async {
    final r = await _db.rawQuery(
        'SELECT package, MAX(posted_at) AS last, COUNT(*) AS n FROM raw_notification GROUP BY package ORDER BY last DESC');
    return r
        .map((m) => SourceStatus(m['package'] as String,
            DateTime.fromMillisecondsSinceEpoch(m['last'] as int), m['n'] as int))
        .toList();
  }

  /// 보관 기간이 지난 처리 완료 원문을 지운다. days<=0이면 무기한.
  Future<int> purgeRaw(int days, {DateTime? now}) async {
    if (days <= 0) return 0;
    final cutoff = (now ?? DateTime.now())
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    return _db.delete('raw_notification',
        where: 'posted_at<? AND state IN (1,2,4)', whereArgs: [cutoff]);
  }

  Future<List<TxRow>> reviewList() async {
    final r = await _db.query('tx',
        where: "status='review' AND deleted_at IS NULL",
        orderBy: 'occurred_at DESC');
    return r.map(TxRow.fromMap).toList();
  }

  Future<List<Map<String, Object?>>> failedRaw() => _db.query('raw_notification',
      where: 'state=2', orderBy: 'posted_at DESC', limit: 50);

  Future<int> rawCount() async =>
      Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM raw_notification')) ??
      0;

  Future<List<AccountRow>> accounts() async {
    final a = await _db.query('account', orderBy: 'key');
    final out = <AccountRow>[];
    for (final r in a) {
      final k = r['key'] as String;
      final b = await _db.rawQuery(
          'SELECT balance FROM tx WHERE account=? AND balance IS NOT NULL ORDER BY occurred_at DESC LIMIT 1',
          [k]);
      final gd = r['goal_date'] as int?;
      out.add(AccountRow(k, (r['label'] ?? k) as String,
          (r['role'] ?? 'unset') as String,
          b.isEmpty ? null : b.first['balance'] as int?,
          monthlyTarget: r['monthly_target'] as int?,
          goalAmount: r['goal_amount'] as int?,
          goalDate:
              gd == null ? null : DateTime.fromMillisecondsSinceEpoch(gd),
          paysFrom: r['pays_from'] as String?));
    }
    return out;
  }

  Future<void> setAccount(String key, {String? label, String? role}) async {
    final v = <String, Object?>{};
    if (label != null) v['label'] = label;
    if (role != null) v['role'] = role;
    await _db.update('account', v, where: 'key=?', whereArgs: [key]);
  }

  Future<void> setAccountGoal(String key,
          {int? monthlyTarget,
          int? goalAmount,
          DateTime? goalDate,
          String? paysFrom}) =>
      _db.update(
          'account',
          {
            'monthly_target': monthlyTarget,
            'goal_amount': goalAmount,
            'goal_date': goalDate?.millisecondsSinceEpoch,
            'pays_from': paysFrom,
          },
          where: 'key=?',
          whereArgs: [key]);

  // ---- edits ----
  /// 분류를 바꾸고 같은 가맹점에 학습 규칙을 남긴다. 검토 상태는 해제.
  Future<void> setCategory(TxRow t, String category) async {
    await _db.update(
        'tx',
        {
          'category': category,
          'status': 'ok',
          'memo': null,
          'updated_at': DateTime.now().millisecondsSinceEpoch
        },
        where: 'id=?',
        whereArgs: [t.id]);
    if (t.title != '(알 수 없음)') {
      await _db.insert('rule', {'keyword': t.title, 'category': category},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// 이체로 바꿀 때 원래 방향(out/in)을 보존한다.
  Future<void> setType(String id, String type) async {
    if (type == 'transfer') {
      await _db.rawUpdate(
          "UPDATE tx SET dir = CASE type WHEN 'expense' THEN 'out' WHEN 'income' THEN 'in' ELSE dir END, type='transfer', status='ok', memo=NULL WHERE id=?",
          [id]);
    } else {
      await _db.update('tx', {'type': type, 'status': 'ok', 'memo': null},
          where: 'id=?', whereArgs: [id]);
    }
  }

  /// 이름·금액·날짜·메모를 고친다. 이름은 표시용 가맹점(merchant)에 저장해 입금자명 매칭은 그대로 둔다.
  Future<void> updateTx(String id,
      {String? title, int? amount, DateTime? at, String? note}) async {
    final v = <String, Object?>{'updated_at': DateTime.now().millisecondsSinceEpoch};
    if (title != null && title.trim().isNotEmpty) v['merchant'] = title.trim();
    if (amount != null) v['amount'] = amount;
    if (at != null) v['occurred_at'] = at.millisecondsSinceEpoch;
    if (note != null) v['note'] = note.trim().isEmpty ? null : note.trim();
    await _db.update('tx', v, where: 'id=?', whereArgs: [id]);
  }

  Future<void> confirm(String id) => _db.update(
      'tx', {'status': 'ok', 'memo': null}, where: 'id=?', whereArgs: [id]);

  Future<void> delete(String id) => _db.update(
      'tx', {'deleted_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id=?', whereArgs: [id]);
}

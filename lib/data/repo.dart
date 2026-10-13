import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/classify.dart';
import '../core/parsers.dart';
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
      );
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
        planning = PlanningRepo(_db);
  final Database _db;
  final SettlementRepo settlements;
  final PlanningRepo planning;

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
    await d.execute('''CREATE TABLE IF NOT EXISTS allocation(
      id TEXT PRIMARY KEY, from_key TEXT, to_key TEXT, amount INTEGER, day INTEGER)''');
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
    var saved = 0;
    for (final r in raws) {
      final received = DateTime.fromMillisecondsSinceEpoch(r['posted_at'] as int);
      final parsed = parseNotification(
          joinNotification(r['title'] as String?, r['text'] as String), received);
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
    var exp = 0, inc = 0, review = 0;
    final cat = <String, int>{};
    for (final t in rows) {
      if (t.status == 'review') review++;
      if (t.type == 'expense') {
        exp += t.effective;
        final c = t.category ?? '미분류';
        cat[c] = (cat[c] ?? 0) + t.effective;
      } else if (t.type == 'income') {
        inc += t.effective;
      }
    }
    return MonthSummary(exp, inc, cat, review);
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

  Future<void> confirm(String id) => _db.update(
      'tx', {'status': 'ok', 'memo': null}, where: 'id=?', whereArgs: [id]);

  Future<void> delete(String id) => _db.update(
      'tx', {'deleted_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id=?', whereArgs: [id]);
}

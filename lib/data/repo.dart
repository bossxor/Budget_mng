import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/classify.dart';
import '../core/parsers.dart';
import '../core/personal_classifier.dart';
import '../core/bank_accounts.dart';
import 'budget_repo.dart';
import 'extras.dart';
import 'planning_repo.dart';
import 'settlement_repo.dart';

part 'account_tools.dart';
part 'learning_tools.dart';
part 'account_registry.dart';

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
  String? pairId, destination, route, direction;
  String? note; // 사용자 메모
  bool personalReview = false;

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
      )..note = m['note'] as String?
       ..pairId = m['pair_id'] as String?
       ..destination = m['destination'] as String?
       ..direction = m['dir'] as String?;
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
      {this.monthlyTarget, this.goalAmount, this.goalDate, this.paysFrom, this.balanceAt,
       this.manualBalance = false,this.bankCode,this.accountNumber});
  final String? bankCode,accountNumber;
  String get maskedIdentity => [if(bankCode!=null)bankNames[bankCode]??bankCode!,
    if(accountNumber!=null)maskedAccountNumber(accountNumber)].join(' · ');
  String get selectionLabel => maskedIdentity.isEmpty?label:'$label · $maskedIdentity';
  final String key;
  final String label;
  final String role;
  final int? balance;
  final DateTime? balanceAt;
  final bool manualBalance;
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
  PersonalClassifier? _personalModel;
  String? _personalSignature;
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
    await ensureAccountTools(d);
    await ensurePersonalLearning(d);
    await ensureAccountRegistry(d);
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
    for(final row in await _db.query('account',where:'bank_code IS NOT NULL AND account_number IS NOT NULL')) {
      final bank=bankNames[row['bank_code']];
      if(bank!=null)keys.add('$bank ${row['account_number']}');
    }
    return Identity(names: names, accountAliases: keys);
  }

  Future<Map<String, String>> learnedRules() async {
    final r = await _db.query('rule');
    return {for (final x in r) x['keyword'] as String: x['category'] as String};
  }

  /// 이전 버전에서 못 읽은 원문 중 새 파서가 확실하게 읽는 것만 재처리한다.
  Future<int> retryRecognizableNotifications() async {
    final rows = await _db.query('raw_notification', where: 'state=2');
    var count = 0;
    for (final row in rows) {
      if (parseBankTransfer(joinNotification(row['title'] as String?, row['text'] as String),
          DateTime.fromMillisecondsSinceEpoch(row['posted_at'] as int)) == null) { continue; }
      count += await _db.update('raw_notification', {'state': 0},
          where: 'id=? AND state=2', whereArgs: [row['id']]);
    }
    return count;
  }
  // ---- ingest ----
  int _seq = 0;
  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';

  /// 네이티브 서비스가 쌓아 둔 원문을 파싱해 거래로 저장한다. 처리한 건수를 반환.
  Future<int> processPending({void Function(int saved, int review)? onComplete}) async {
    final raws = await _db.query('raw_notification',
        where: 'state=0', orderBy: 'posted_at ASC');
    if (raws.isEmpty) return 0;
    final me = await identity();
    final learned = await learnedRules();
    final extra = ((await getKv('extra_packages')) ?? '').split(',');
    var saved = 0;
    final savedRawIds = <Object?>{};
    var review = 0, failed = 0;
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
          !raw.contains(RegExp('취소|환불|요청|예정|예약|실패|거절|인증|OTP|광고|부탁|해주세요'))) {
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
        if (RegExp('입금|출금|승인|취소|결제|이체|송금|잔액').hasMatch(raw) &&
            !RegExp(r'\(광고\)|수신거부|알림끄기').hasMatch(raw)) { failed++; }
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
      if (await _insertParsed(parsed, r['id'] as int, r['package'] as String, dir)) review++;
      await _db.update('raw_notification', {'state': 1},
          where: 'id=?', whereArgs: [r['id']]);
      saved++;
      savedRawIds.add(r['id']);
    }
    await refreshPersonalSuggestions();
    // 추천은 거래를 바꾸지 않고 확인 목록에만 더한다.
    final newReviews = await _db.rawQuery('''SELECT raw_id FROM tx
      WHERE deleted_at IS NULL AND (status='review' OR id IN
        (SELECT tx_id FROM learning_suggestion))''');
    review = newReviews.where((r) => savedRawIds.contains(r['raw_id'])).length;
    onComplete?.call((saved - review).clamp(0, saved), review + failed);
    return saved;
  }

  Future<bool> _insertParsed(
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
    final acctKey = await resolveAccount(t.account ?? t.card);
    final otherAccount=t.type=='transfer'?
      await _registeredAccount(t.counterparty??t.merchant??''):null;
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
      'account': await resolveAccount(t.account ?? t.card),
      'destination':otherAccount==acctKey?null:otherAccount,
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
      final key = (await resolveAccount(t.account ?? t.card))!;
      if (t.type != 'group') {
        await _db.insert('account', {'key': key, 'label': key},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    await _pairTransfers(id, t, at);
    return status == 'review';
  }

  /// 다른 계좌에서 같은 금액의 반대 거래가 5분 안에 있으면 둘 다 이체로 묶는다.
  Future<void> _pairTransfers(String id, ParsedTx t, int at) async {
    await pairTransfers();
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
    final labels = {for (final a in await accounts()) a.key: a.label};

    for (final row in rows) {
      final other = row.destination;

      if (row.type == 'transfer' && other != null && row.account != null) {
        final from = row.direction == 'in' ? other : row.account!;
        final to = row.direction == 'in' ? row.account! : other;
        row.route = '${labels[from] ?? from} → ${labels[to] ?? to}';
      }
    }
    return rows;
  }

  Future<MonthSummary> summary(DateTime month) async {
    final rows = await monthTx(month);
    final splits = await _splitsFor(rows.map((t) => t.id).toList());
    final personalReviewIds = (await personalSuggestions()).keys.toSet();
    var exp = 0, inc = 0, review = 0;
    final cat = <String, int>{};
    for (final t in rows) {
      if (t.status == 'review' || personalReviewIds.contains(t.id)) review++;
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
  Future<int> runBackgroundIngest({DateTime? now, void Function(int saved, int review)? onComplete}) async {
    final n = await processPending(onComplete: onComplete);
    await setKv('bg_last_run', '${(now ?? DateTime.now()).millisecondsSinceEpoch}');
    await setKv('bg_last_saved', '$n');
    final total = int.tryParse(await getKv('bg_total_saved') ?? '') ?? 0;
    await setKv('bg_total_saved', '${total + n}');
    await writeWidgetSnapshot(now: now);
    return n;
  }

  /// 위젯도 정산의 내 몫과 환불을 반영한 동일한 가계부 집계를 사용한다.
  Future<void> writeWidgetSnapshot({DateTime? now}) async {
    final date = now ?? DateTime.now();
    final rows = (await monthTx(date))
        .where((t) => !t.occurredAt.isAfter(date)).toList();
    final spent = rows.where((t) => t.type == 'expense')
        .fold<int>(0, (sum, t) => sum + t.effective);
    final limit = (await budget.budgets())[''];
    final forecast = BudgetForecast.calculate(
        month: date, now: date, limit: limit ?? 0, spent: spent);
    await setKv('widget_snapshot', jsonEncode({
      'year': date.year, 'month': date.month, 'spent': spent,
      'limit': limit, 'excess': forecast?.excess ?? 0,
      'updatedAt': date.millisecondsSinceEpoch,
    }));
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
        where: "deleted_at IS NULL AND (status='review' OR id IN (SELECT tx_id FROM learning_suggestion))",
        orderBy: 'occurred_at DESC');
    final suggestions = await personalSuggestions();
    return collapseTransfers(r.map((m) => TxRow.fromMap(m)
      ..personalReview = suggestions.containsKey(m['id'])).toList());
  }

  Future<List<Map<String, Object?>>> failedRaw() => _db.query('raw_notification',
      where: 'state=2', orderBy: 'posted_at DESC', limit: 50);

  Future<int> rawCount() async =>
      Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM raw_notification')) ??
      0;

  Future<List<AccountRow>> accounts() async {
    final a = await _db.rawQuery('SELECT * FROM account WHERE key NOT IN (SELECT alias FROM account_alias) ORDER BY key');
    final out = <AccountRow>[];
    for (final r in a) {
      final k = r['key'] as String;
      final b = await _db.rawQuery(
          'SELECT balance, occurred_at FROM tx WHERE account=? AND balance IS NOT NULL AND deleted_at IS NULL ORDER BY occurred_at DESC LIMIT 1',
          [k]);
      final gd = r['goal_date'] as int?;
      out.add(AccountRow(k, (r['label'] ?? k) as String,
          (r['role'] ?? 'unset') as String,
          (r['manual_balance_at'] != null && (b.isEmpty || (r['manual_balance_at'] as int) >= (b.first['occurred_at'] as int)))
              ? r['manual_balance'] as int? : (b.isEmpty ? null : b.first['balance'] as int?),
          balanceAt: (r['manual_balance_at'] != null && (b.isEmpty || (r['manual_balance_at'] as int) >= (b.first['occurred_at'] as int)))
              ? DateTime.fromMillisecondsSinceEpoch(r['manual_balance_at'] as int)
              : b.isEmpty ? null : DateTime.fromMillisecondsSinceEpoch(b.first['occurred_at'] as int),
          manualBalance: r['manual_balance_at'] != null && (b.isEmpty || (r['manual_balance_at'] as int) >= (b.first['occurred_at'] as int)),
          monthlyTarget: r['monthly_target'] as int?,
          goalAmount: r['goal_amount'] as int?,
          goalDate:
              gd == null ? null : DateTime.fromMillisecondsSinceEpoch(gd),
          paysFrom: r['pays_from'] as String?,bankCode:r['bank_code'] as String?,
          accountNumber:r['account_number'] as String?));
    }
    return out;
  }

  Future<void> addAccount(String name, {String role = 'unset'}) async {
    final key = name.trim();
    if (key.isEmpty) throw ArgumentError('통장 이름을 입력하세요');
    if (!roles.containsKey(role)) throw ArgumentError('용도를 확인하세요');
    await _db.insert('account', {'key': key, 'label': key, 'role': role},
        conflictAlgorithm: ConflictAlgorithm.abort);
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
  Future<void> setCategory(TxRow t, String category) => classifyTx(t.id, category: category);
  Future<void> setType(String id, String type) => classifyTx(id, type: type);
  /// 이름·금액·날짜·메모를 고친다. 이름은 표시용 가맹점(merchant)에 저장해 입금자명 매칭은 그대로 둔다.
  Future<void> updateTx(String id,
      {String? title, int? amount, DateTime? at, String? note}) async {
    final v = <String, Object?>{'updated_at': DateTime.now().millisecondsSinceEpoch};
    if (title != null && title.trim().isNotEmpty) v['merchant'] = title.trim();
    if (amount != null) v['amount'] = amount;
    if (at != null) v['occurred_at'] = at.millisecondsSinceEpoch;
    if (note != null) v['note'] = note.trim().isEmpty ? null : note.trim();
    await _db.transaction((db) async {
      await db.update('tx', v, where: 'id=?', whereArgs: [id]);
      final current=(await db.query('tx',where:'id=?',whereArgs:[id])).first;
      if (title != null || amount != null || at != null) {
        for (final key in [id,if(current['pair_id']!=null)current['pair_id'] as String]) {
          await db.delete('learning_example',where:'tx_id=?',whereArgs:[key]);
          await db.delete('learning_suggestion',where:'tx_id=?',whereArgs:[key]);
        }
      }
      if (amount != null || at != null) {
        final row = (await db.query('tx', where: 'id=?', whereArgs: [id])).first;
        if (row['pair_id'] != null) { await db.update('tx', {
          'amount': ?amount,
          if(at != null) 'occurred_at': at.millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        }, where: 'id=?', whereArgs: [row['pair_id']]); }
      }
    });
  }

  Future<void> confirm(String id) => classifyTx(id);

  Future<void> delete(String id) async {
    await _db.transaction((db) async {
      final rows=await db.query('tx',where:'id=?',whereArgs:[id]);
      if(rows.isEmpty)return;
      for(final key in [id, if(rows.first['pair_id']!=null)rows.first['pair_id'] as String]) {
        await db.delete('learning_example',where:'tx_id=?',whereArgs:[key]);
        await db.delete('learning_suggestion',where:'tx_id=?',whereArgs:[key]);
        await db.update('tx',{'deleted_at':DateTime.now().millisecondsSinceEpoch,'updated_at':DateTime.now().millisecondsSinceEpoch},where:'id=?',whereArgs:[key]);
      }
    });
  }
}

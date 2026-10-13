import 'package:sqflite/sqflite.dart';

import 'repo.dart';

class Person {
  Person(this.id, this.name, this.aliases);
  final String id;
  final String name;
  final List<String> aliases;
}

class ShareView {
  ShareView(this.id, this.personId, this.name, this.amount, this.received,
      {this.paidByThem = 0});
  final String id;
  final String? personId; // null = 나
  final String name;
  final int amount; // 이 사람이 쓴 몫
  final int received; // 받은 돈 (내가 줄 쪽이면 내가 보낸 돈)
  final int paidByThem; // 이 사람이 대신 낸 결제 합계
  bool get isMe => personId == null;

  /// +면 이 사람이 나에게 줄 돈, -면 내가 이 사람에게 줄 돈.
  int get due => amount - paidByThem;
  bool get iOwe => !isMe && due < 0;
  int get remaining => due.abs() - received;
}

/// 다른 사람이 낸 결제 (내 거래 내역에는 없는 돈).
class ExtraItem {
  ExtraItem(this.id, this.payer, this.title, this.amount);
  final String id;
  final String payer;
  final String title;
  final int amount;
}

class ExtraInput {
  ExtraInput(this.payer, this.title, this.amount);
  final String payer;
  final String title;
  final int amount;
}

/// 정산 한 건. 모든 사람은 '나'와만 주고받는다고 보고 사람별 순액을 계산한다.
class SettlementView {
  SettlementView(this.id, this.title, this.createdAt, this.items, this.shares,
      [this.extras = const []]);
  final String id;
  final String title;
  final DateTime createdAt;
  final List<TxRow> items; // 내가 낸 결제
  final List<ShareView> shares;
  final List<ExtraItem> extras; // 다른 사람이 낸 결제

  int get myPaid => items.fold(0, (a, t) => a + t.amount);
  int get total => myPaid + extras.fold(0, (a, e) => a + e.amount);
  int get myShare => shares.where((s) => s.isMe).fold(0, (a, s) => a + s.amount);
  List<ShareView> get others => shares.where((s) => !s.isMe).toList();
  List<ShareView> get owesMe => others.where((s) => s.due > 0).toList();
  List<ShareView> get iOweList => others.where((s) => s.iOwe).toList();

  int get toReceive => owesMe.fold(0, (a, s) => a + s.due);
  int get received => owesMe.fold(0, (a, s) => a + s.received);
  int get outstanding => toReceive - received;
  int get toPay => iOweList.fold(0, (a, s) => a - s.due);
  int get sent => iOweList.fold(0, (a, s) => a + s.received);
  int get payOutstanding => toPay - sent;

  /// 내 결제 중 '내 지출'로 남길 금액. 내가 보낼 돈은 송금 거래가 따로 지출로 잡히므로 뺀다.
  /// ponytail: 내가 한 푼도 안 냈는데 받을 돈도 있는 경우(나를 거쳐 전달)는 지출이 조금 과하게 잡힌다.
  int get myItemsTarget {
    final t = myShare - toPay;
    if (t < 0) return 0;
    return t > myPaid ? myPaid : t;
  }

  /// open: 아직 아무것도 안 오감 / partial: 일부 / done: 모두 정리
  String get status {
    final open = others.where((s) => s.due != 0 && s.remaining > 0).toList();
    if (open.isEmpty) return 'done';
    return others.any((s) => s.received > 0) ? 'partial' : 'open';
  }
}

class DepositCandidate {
  DepositCandidate(this.tx, this.free, this.nameMatch);
  final TxRow tx;
  final int free; // 아직 정산에 연결되지 않은 금액
  final bool nameMatch;
}

/// 홈에서 한 번에 연결할 수 있는 입금 추천.
class LinkSuggestion {
  LinkSuggestion(this.settlement, this.share, this.deposit, this.byName);
  final SettlementView settlement;
  final ShareView share;
  final DepositCandidate deposit;
  final bool byName; // true: 이름 일치, false: 금액만 일치
  int get amount => deposit.free < share.remaining ? deposit.free : share.remaining;
}

/// 자주 만나는 멤버 조합.
class GroupPreset {
  GroupPreset(this.id, this.name, this.members);
  final String id;
  final String name;
  final List<String> members;
}

/// 정산한 지 며칠이 지나도 못 받은 몫.
class OverdueItem {
  OverdueItem(this.settlement, this.share, this.days);
  final SettlementView settlement;
  final ShareView share;
  final int days;
}

const defaultRequestTemplate = '{이름}님, "{정산명}" 정산 {금액}원 보내주세요.\n{계좌}';

String _won(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// 요청 문구 템플릿을 채운다. 계좌가 비어 있으면 그 줄은 빼서 빈 줄이 남지 않게 한다.
String buildRequestText(String template,
    {required String name,
    required String title,
    required int amount,
    String account = ''}) {
  final t = template.trim().isEmpty ? defaultRequestTemplate : template;
  final filled = t
      .replaceAll('{이름}', name)
      .replaceAll('{정산명}', title)
      .replaceAll('{금액}', _won(amount))
      .replaceAll('{계좌}', account);
  return filled
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .join('\n');
}

class ShareInput {
  ShareInput(this.name, this.amount);
  final String? name; // null = 나
  final int amount;
}

class SettlementRepo {
  SettlementRepo(this._db);
  final Database _db;
  int _seq = 0;
  String _id() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';

  static Future<void> schema(Database d) async {
    await d.execute('''CREATE TABLE IF NOT EXISTS person(
      id TEXT PRIMARY KEY, name TEXT UNIQUE, aliases TEXT DEFAULT '')''');
    await d.execute('''CREATE TABLE IF NOT EXISTS group_preset(
      id TEXT PRIMARY KEY, name TEXT, members TEXT)''');
    await d.execute('''CREATE TABLE IF NOT EXISTS settlement(
      id TEXT PRIMARY KEY, title TEXT, created_at INTEGER, deleted_at INTEGER)''');
    await d.execute('''CREATE TABLE IF NOT EXISTS settlement_item(
      settlement_id TEXT, tx_id TEXT, PRIMARY KEY(settlement_id, tx_id))''');
    await d.execute('''CREATE TABLE IF NOT EXISTS settlement_share(
      id TEXT PRIMARY KEY, settlement_id TEXT, person_id TEXT, amount INTEGER)''');
    await d.execute('''CREATE TABLE IF NOT EXISTS settlement_extra(
      id TEXT PRIMARY KEY, settlement_id TEXT, payer TEXT, title TEXT, amount INTEGER)''');
    await d.execute('''CREATE TABLE IF NOT EXISTS settlement_payment(
      id TEXT PRIMARY KEY, share_id TEXT, tx_id TEXT, amount INTEGER)''');
  }

  // ---- 사람 ----
  Future<List<Person>> people() async {
    final r = await _db.query('person', orderBy: 'name');
    return r
        .map((m) => Person(
            m['id'] as String,
            m['name'] as String,
            ((m['aliases'] as String?) ?? '')
                .split(',')
                .where((s) => s.isNotEmpty)
                .toList()))
        .toList();
  }

  /// 이름으로 찾고 없으면 자동 등록한다.
  Future<String> ensurePerson(String name) async {
    final n = name.trim();
    final r = await _db.query('person', where: 'name=?', whereArgs: [n]);
    if (r.isNotEmpty) return r.first['id'] as String;
    final id = _id();
    await _db.insert('person', {'id': id, 'name': n, 'aliases': ''});
    return id;
  }

  // ---- 정산 생성/조회 ----
  Future<String> create({
    required String title,
    required List<String> txIds,
    required List<ShareInput> shares,
    List<ExtraInput> extras = const [],
  }) async {
    final id = _id();
    // 결제한 사람이 몫 목록에 없으면 몫 0으로 넣어 순액 계산에 포함한다.
    final names = {for (final s in shares) s.name?.trim()};
    shares = [
      ...shares,
      for (final p in {for (final e in extras) e.payer.trim()})
        if (!names.contains(p)) ShareInput(p, 0),
    ];
    await _db.transaction((t) async {
      await t.insert('settlement', {
        'id': id,
        'title': title,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      for (final x in txIds) {
        await t.insert('settlement_item', {'settlement_id': id, 'tx_id': x});
      }
      for (final e in extras) {
        await t.insert('settlement_extra', {
          'id': _id(),
          'settlement_id': id,
          'payer': e.payer.trim(),
          'title': e.title,
          'amount': e.amount,
        });
      }
      for (final s in shares) {
        String? pid;
        if (s.name != null) {
          final r = await t.query('person', where: 'name=?', whereArgs: [s.name!.trim()]);
          if (r.isNotEmpty) {
            pid = r.first['id'] as String;
          } else {
            pid = _id();
            await t.insert('person', {'id': pid, 'name': s.name!.trim(), 'aliases': ''});
          }
        }
        await t.insert('settlement_share', {
          'id': _id(),
          'settlement_id': id,
          'person_id': pid,
          'amount': s.amount,
        });
      }
    });
    return id;
  }

  Future<List<SettlementView>> all() async {
    final r = await _db.query('settlement',
        where: 'deleted_at IS NULL', orderBy: 'created_at DESC');
    final out = <SettlementView>[];
    for (final m in r) {
      final v = await get(m['id'] as String);
      if (v != null) out.add(v);
    }
    return out;
  }

  Future<SettlementView?> get(String id) async {
    final s = await _db.query('settlement', where: 'id=?', whereArgs: [id]);
    if (s.isEmpty) return null;
    final items = await _db.rawQuery('''SELECT t.* FROM tx t
      JOIN settlement_item i ON i.tx_id=t.id WHERE i.settlement_id=?
      ORDER BY t.occurred_at''', [id]);
    final shares = await _db.rawQuery('''SELECT s.id, s.person_id, s.amount,
        IFNULL(p.name,'나') AS name,
        IFNULL((SELECT SUM(amount) FROM settlement_payment WHERE share_id=s.id),0) AS received
      FROM settlement_share s LEFT JOIN person p ON p.id=s.person_id
      WHERE s.settlement_id=? ORDER BY (s.person_id IS NOT NULL), p.name''', [id]);
    final ex = (await _db.query('settlement_extra',
            where: 'settlement_id=?', whereArgs: [id], orderBy: 'rowid'))
        .map((m) => ExtraItem(m['id'] as String, m['payer'] as String,
            (m['title'] ?? '') as String, m['amount'] as int))
        .toList();
    final paidBy = <String, int>{};
    for (final e in ex) {
      paidBy[e.payer] = (paidBy[e.payer] ?? 0) + e.amount;
    }
    return SettlementView(
      id,
      s.first['title'] as String,
      DateTime.fromMillisecondsSinceEpoch(s.first['created_at'] as int),
      items.map(TxRow.fromMap).toList(),
      shares.map((m) {
        final name = m['name'] as String;
        final isMe = m['person_id'] == null;
        return ShareView(m['id'] as String, m['person_id'] as String?, name,
            m['amount'] as int, m['received'] as int,
            paidByThem: isMe ? 0 : (paidBy[name] ?? 0));
      }).toList(),
      ex,
    );
  }

  Future<void> delete(String id) async {
    await _db.update('settlement', {'deleted_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id=?', whereArgs: [id]);
    // 연결된 입금은 다시 일반 수입으로 돌아간다.
    await _db.delete('settlement_payment',
        where: 'share_id IN (SELECT id FROM settlement_share WHERE settlement_id=?)',
        whereArgs: [id]);
  }

  // ---- 모임 프리셋 ----
  Future<List<GroupPreset>> presets() async {
    final r = await _db.query('group_preset', orderBy: 'name');
    return r
        .map((m) => GroupPreset(
            m['id'] as String,
            m['name'] as String,
            ((m['members'] as String?) ?? '')
                .split(',')
                .where((x) => x.isNotEmpty)
                .toList()))
        .toList();
  }

  /// 같은 이름이면 멤버만 바꾼다.
  Future<void> savePreset(String name, List<String> members) async {
    final n = name.trim();
    if (n.isEmpty || members.isEmpty) return;
    final cur = await _db.query('group_preset', where: 'name=?', whereArgs: [n]);
    final value = members.join(',');
    if (cur.isEmpty) {
      await _db.insert('group_preset', {'id': _id(), 'name': n, 'members': value});
    } else {
      await _db.update('group_preset', {'members': value},
          where: 'id=?', whereArgs: [cur.first['id']]);
    }
  }

  Future<void> deletePreset(String id) =>
      _db.delete('group_preset', where: 'id=?', whereArgs: [id]);

  // ---- 미수금 경과 ----
  /// 정산한 지 [days]일이 지났는데 아직 못 받은 몫. 오래된 순.
  Future<List<OverdueItem>> overdue({int days = 3, DateTime? now}) async {
    final today = now ?? DateTime.now();
    final out = <OverdueItem>[];
    for (final st in await all()) {
      final age = today.difference(st.createdAt).inDays;
      if (age < days) continue;
      for (final sh in st.owesMe.where((x) => x.remaining > 0)) {
        out.add(OverdueItem(st, sh, age));
      }
    }
    out.sort((a, b) => b.days.compareTo(a.days));
    return out;
  }

  // ---- 입금 연결 ----
  /// 정산에 아직 연결되지 않은 입금 후보. 이름이 같은 입금을 먼저 보여 준다.
  Future<List<DepositCandidate>> candidates(String personName) async {
    final since = DateTime.now().subtract(const Duration(days: 120)).millisecondsSinceEpoch;
    final r = await _db.rawQuery('''SELECT t.*,
        IFNULL((SELECT SUM(amount) FROM settlement_payment WHERE tx_id=t.id),0) AS paid
      FROM tx t WHERE t.type='income' AND t.deleted_at IS NULL AND t.occurred_at>=?
      ORDER BY t.occurred_at DESC''', [since]);
    final aliases = await _aliasesOf(personName);
    final out = <DepositCandidate>[];
    for (final m in r) {
      final free = (m['amount'] as int) - (m['paid'] as int);
      if (free <= 0) continue;
      final who = (m['counterparty'] ?? m['merchant'] ?? '') as String;
      final match = who.isNotEmpty && aliases.any((a) => who == a || who.contains(a));
      out.add(DepositCandidate(TxRow.fromMap(m), free, match));
    }
    out.sort((a, b) {
      if (a.nameMatch != b.nameMatch) return a.nameMatch ? -1 : 1;
      return b.tx.occurredAt.compareTo(a.tx.occurredAt);
    });
    return out;
  }

  /// 내가 줄 돈에 연결할 송금(지출) 후보. 정산 결제로 묶인 지출은 제외한다.
  Future<List<DepositCandidate>> outgoingCandidates(String personName) async {
    final since = DateTime.now().subtract(const Duration(days: 120)).millisecondsSinceEpoch;
    final r = await _db.rawQuery('''SELECT t.*,
        IFNULL((SELECT SUM(amount) FROM settlement_payment WHERE tx_id=t.id),0) AS paid
      FROM tx t WHERE t.type='expense' AND t.amount>0 AND t.deleted_at IS NULL AND t.occurred_at>=?
        AND t.id NOT IN (SELECT i.tx_id FROM settlement_item i
                         JOIN settlement s ON s.id=i.settlement_id AND s.deleted_at IS NULL)
      ORDER BY t.occurred_at DESC''', [since]);
    final aliases = await _aliasesOf(personName);
    final out = <DepositCandidate>[];
    for (final m in r) {
      final free = (m['amount'] as int) - (m['paid'] as int);
      if (free <= 0) continue;
      final who = (m['counterparty'] ?? m['merchant'] ?? '') as String;
      final match = who.isNotEmpty && aliases.any((a) => who == a || who.contains(a));
      out.add(DepositCandidate(TxRow.fromMap(m), free, match));
    }
    out.sort((a, b) {
      if (a.nameMatch != b.nameMatch) return a.nameMatch ? -1 : 1;
      return b.tx.occurredAt.compareTo(a.tx.occurredAt);
    });
    return out;
  }

  Future<Set<String>> _aliasesOf(String name) async {
    final r = await _db.query('person', where: 'name=?', whereArgs: [name]);
    final s = {name};
    if (r.isNotEmpty) {
      s.addAll(((r.first['aliases'] as String?) ?? '').split(',').where((x) => x.isNotEmpty));
    }
    return s;
  }

  /// 입금을 사람 몫에 연결한다. 입금자명이 다르면 별칭으로 학습한다.
  Future<void> pay(ShareView share, DepositCandidate d, int amount) async {
    await _db.insert('settlement_payment',
        {'id': _id(), 'share_id': share.id, 'tx_id': d.tx.id, 'amount': amount});
    final who = d.tx.title;
    if (share.personId != null && who != share.name && who != '(알 수 없음)') {
      final r = await _db.query('person', where: 'id=?', whereArgs: [share.personId]);
      final cur = ((r.first['aliases'] as String?) ?? '').split(',').where((x) => x.isNotEmpty).toSet();
      if (cur.add(who)) {
        await _db.update('person', {'aliases': cur.join(',')},
            where: 'id=?', whereArgs: [share.personId]);
      }
    }
  }

  Future<List<Map<String, Object?>>> paymentsOf(String shareId) =>
      _db.rawQuery('''SELECT p.id, p.amount, t.merchant, t.counterparty, t.occurred_at
        FROM settlement_payment p JOIN tx t ON t.id=p.tx_id
        WHERE p.share_id=? ORDER BY t.occurred_at''', [shareId]);

  Future<void> unpay(String paymentId) =>
      _db.delete('settlement_payment', where: 'id=?', whereArgs: [paymentId]);

  /// 받을 돈이 남은 사람마다 이름이 같은 입금(없으면 금액이 딱 맞는 입금 1건)을 찾아 추천한다.
  Future<List<LinkSuggestion>> suggestions() async {
    final out = <LinkSuggestion>[];
    final used = <String>{};
    for (final st in await all()) {
      for (final sh in st.owesMe.where((x) => x.remaining > 0)) {
        final cands = (await candidates(sh.name))
            .where((c) => !used.contains(c.tx.id))
            .toList();
        var byName = true;
        DepositCandidate? m;
        for (final c in cands) {
          if (c.nameMatch) {
            m = c;
            break;
          }
        }
        if (m == null) {
          final exact = cands.where((c) => c.free == sh.remaining).toList();
          if (exact.length == 1) {
            m = exact.first;
            byName = false;
          }
        }
        if (m != null) {
          used.add(m.tx.id);
          out.add(LinkSuggestion(st, sh, m, byName));
        }
      }
    }
    return out;
  }

  // ---- 집계용 ----
  /// 정산에 묶인 결제의 '내 몫' 금액 (결제별로 금액 비례 배분).
  /// ponytail: 비례 배분 반올림으로 몇 원 오차가 날 수 있음. 정산당 결제 수가 적어 무시.
  Future<Map<String, int>> myAmountByTx() async {
    final out = <String, int>{};
    final r = await _db.query('settlement', where: 'deleted_at IS NULL', columns: ['id']);
    for (final m in r) {
      final v = await get(m['id'] as String);
      if (v == null || v.myPaid == 0) continue;
      final target = v.myItemsTarget;
      var left = target;
      for (var i = 0; i < v.items.length; i++) {
        final t = v.items[i];
        final mine = i == v.items.length - 1
            ? left
            : (t.amount * target / v.myPaid).round();
        left -= mine;
        out[t.id] = mine;
      }
    }
    return out;
  }

  Future<Map<String, int>> paidByTx() async {
    final r = await _db.rawQuery('''SELECT p.tx_id AS id, SUM(p.amount) AS s
      FROM settlement_payment p
      JOIN settlement_share sh ON sh.id=p.share_id
      JOIN settlement st ON st.id=sh.settlement_id AND st.deleted_at IS NULL
      GROUP BY p.tx_id''');
    return {for (final m in r) m['id'] as String: m['s'] as int};
  }

  /// 아직 정산에 묶이지 않은 최근 지출 (정산 만들기에서 선택).
  Future<List<TxRow>> settleableExpenses({int days = 60}) async {
    final since = DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch;
    final r = await _db.rawQuery('''SELECT t.* FROM tx t
      WHERE t.type='expense' AND t.amount>0 AND t.deleted_at IS NULL AND t.occurred_at>=?
        AND t.id NOT IN (SELECT i.tx_id FROM settlement_item i
                         JOIN settlement s ON s.id=i.settlement_id AND s.deleted_at IS NULL)
      ORDER BY t.occurred_at DESC''', [since]);
    return r.map(TxRow.fromMap).toList();
  }
}

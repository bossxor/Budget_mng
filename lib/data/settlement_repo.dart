import 'package:sqflite/sqflite.dart';

import 'repo.dart';

class Person {
  Person(this.id, this.name, this.aliases);
  final String id;
  final String name;
  final List<String> aliases;
}

class ShareView {
  ShareView(this.id, this.personId, this.name, this.amount, this.received);
  final String id;
  final String? personId; // null = 나
  final String name;
  final int amount;
  final int received;
  bool get isMe => personId == null;
  int get remaining => amount - received;
}

class SettlementView {
  SettlementView(this.id, this.title, this.createdAt, this.items, this.shares);
  final String id;
  final String title;
  final DateTime createdAt;
  final List<TxRow> items;
  final List<ShareView> shares;

  int get total => items.fold(0, (a, t) => a + t.amount);
  int get myShare => shares.where((s) => s.isMe).fold(0, (a, s) => a + s.amount);
  List<ShareView> get others => shares.where((s) => !s.isMe).toList();
  int get toReceive => others.fold(0, (a, s) => a + s.amount);
  int get received => others.fold(0, (a, s) => a + s.received);
  int get outstanding => toReceive - received;

  /// open: 한 푼도 못 받음 / partial: 일부 / done: 전부 받음
  String get status {
    if (others.isEmpty || outstanding <= 0) return 'done';
    return received > 0 ? 'partial' : 'open';
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
    await d.execute('''CREATE TABLE IF NOT EXISTS settlement(
      id TEXT PRIMARY KEY, title TEXT, created_at INTEGER, deleted_at INTEGER)''');
    await d.execute('''CREATE TABLE IF NOT EXISTS settlement_item(
      settlement_id TEXT, tx_id TEXT, PRIMARY KEY(settlement_id, tx_id))''');
    await d.execute('''CREATE TABLE IF NOT EXISTS settlement_share(
      id TEXT PRIMARY KEY, settlement_id TEXT, person_id TEXT, amount INTEGER)''');
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
  }) async {
    final id = _id();
    await _db.transaction((t) async {
      await t.insert('settlement', {
        'id': id,
        'title': title,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      for (final x in txIds) {
        await t.insert('settlement_item', {'settlement_id': id, 'tx_id': x});
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
    return SettlementView(
      id,
      s.first['title'] as String,
      DateTime.fromMillisecondsSinceEpoch(s.first['created_at'] as int),
      items.map(TxRow.fromMap).toList(),
      shares
          .map((m) => ShareView(m['id'] as String, m['person_id'] as String?,
              m['name'] as String, m['amount'] as int, m['received'] as int))
          .toList(),
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
      for (final sh in st.others.where((x) => x.remaining > 0)) {
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
      if (v == null || v.total == 0) continue;
      var left = v.myShare;
      for (var i = 0; i < v.items.length; i++) {
        final t = v.items[i];
        final mine = i == v.items.length - 1
            ? left
            : (t.amount * v.myShare / v.total).round();
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

import 'package:sqflite/sqflite.dart';

/// 월 배분 계획 한 줄: from 통장에서 to로 매월 amount를 보낸다.
class Plan {
  Plan(this.id, this.fromKey, this.toKey, this.amount, this.day);
  final String id;
  final String fromKey;
  final String toKey; // 계좌 key 또는 직접 입력한 이름
  final int amount;
  final int day; // 매월 몇 일까지
}

class PlanStatus {
  PlanStatus(this.plan, this.paid, this.overdue);
  final Plan plan;
  final int paid;
  final bool overdue;
  bool get done => paid >= plan.amount;
  int get remaining => plan.amount - paid;
}

class SavingsSummary {
  SavingsSummary(this.saved, this.withdrawn);
  final int saved; // 저축 성격 통장으로 들어간 돈
  final int withdrawn; // 저축 통장에서 빠져나간 돈
  int get net => saved - withdrawn;
}

const savingRoles = {'saving', 'travel', 'emergency'};

class PlanningRepo {
  PlanningRepo(this._db);
  final Database _db;
  int _seq = 0;
  String _id() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';

  Future<List<Plan>> plans() async {
    final r = await _db.query('allocation', orderBy: 'day, amount DESC');
    return r
        .map((m) => Plan(m['id'] as String, m['from_key'] as String,
            m['to_key'] as String, m['amount'] as int, m['day'] as int))
        .toList();
  }

  Future<void> addPlan(String fromKey, String toKey, int amount, int day) =>
      _db.insert('allocation', {
        'id': _id(),
        'from_key': fromKey,
        'to_key': toKey,
        'amount': amount,
        'day': day,
      });

  Future<void> deletePlan(String id) =>
      _db.delete('allocation', where: 'id=?', whereArgs: [id]);

  /// 계좌 key -> 이름(label) 매핑과 저축 성격 통장 집합.
  Future<({Map<String, String> labels, Set<String> savingKeys})> _accounts() async {
    final r = await _db.query('account');
    final labels = <String, String>{};
    final saving = <String>{};
    for (final m in r) {
      final k = m['key'] as String;
      labels[k] = (m['label'] ?? k) as String;
      if (savingRoles.contains(m['role'])) saving.add(k);
    }
    for(final alias in await _db.query('account_alias')) {
      final key=alias['alias'] as String, canonical=alias['canonical'] as String;
      labels[key]=labels[canonical]??canonical;
      if(saving.contains(canonical)) { saving.add(key); } else { saving.remove(key); }
    }
    return (labels: labels, savingKeys: saving);
  }

  bool _matches(String? who, String key, Map<String, String> labels) {
    if (who == null || who.isEmpty) return false;
    final label = labels[key];
    return who == key ||
        (label != null && label.isNotEmpty && who.contains(label)) ||
        key.contains(who);
  }

  Future<List<Map<String, Object?>>> _transfers(DateTime month) {
    final from = DateTime(month.year, month.month).millisecondsSinceEpoch;
    final to = DateTime(month.year, month.month + 1).millisecondsSinceEpoch;
    return _db.query('tx',
        where: "type='transfer' AND deleted_at IS NULL AND occurred_at>=? AND occurred_at<?",
        whereArgs: [from, to]);
  }

  /// 이번 달 배분 계획 이행 상태.
  Future<List<PlanStatus>> status(DateTime month, {DateTime? now}) async {
    final ps = await plans();
    if (ps.isEmpty) return [];
    final acc = await _accounts();
    final tr = (await _transfers(month)).where((t) => t['dir'] == 'out').toList();
    final today = now ?? DateTime.now();
    final sameMonth = today.year == month.year && today.month == month.month;
    return [
      for (final p in ps)
        () {
          var paid = 0;
          for (final t in tr) {
            if (t['account'] == p.fromKey &&
                (t['destination'] == p.toKey || _matches(t['counterparty'] as String?, p.toKey, acc.labels))) {
              paid += t['amount'] as int;
            }
          }
          final late = sameMonth && today.day > p.day && paid < p.amount;
          return PlanStatus(p, paid, late);
        }(),
    ];
  }

  /// 저축/인출 집계. 같은 이체를 양쪽 알림에서 두 번 세지 않도록 5분 안의 쌍은 한 번만 센다.
  Future<SavingsSummary> savings(DateTime month) async {
    final acc = await _accounts();
    if (acc.savingKeys.isEmpty) return SavingsSummary(0, 0);
    final tr = await _transfers(month);
    final outs = tr.where((t) => t['dir'] == 'out').toList();
    bool toSaving(String? who) =>
        acc.savingKeys.any((k) => _matches(who, k, acc.labels));

    bool paired(Map<String, Object?> t) => outs.any((o) =>
        (t['pair_id'] == o['id'] || (t['pair_id'] == null && o['amount'] == t['amount'] && (o['account'] == t['counterparty'] || t['account'] == o['counterparty']))) &&
        ((o['occurred_at'] as int) - (t['occurred_at'] as int)).abs() <= 300000);

    var saved = 0, withdrawn = 0;
    for (final t in tr) {
      final amt = t['amount'] as int;
      final account = t['account'] as String?;
      final cp = t['counterparty'] as String?;
      final fromSaving = account != null && acc.savingKeys.contains(account);
      if (t['dir'] == 'out') {
        final dest = toSaving(t['destination'] as String? ?? cp) || ['적금', '여행저축', '비상금'].contains(t['category']);
        if (dest && !fromSaving) saved += amt;
        if (fromSaving && !dest) withdrawn += amt;
      } else if (t['dir'] == 'in') {
        if (paired(t)) continue; // 보낸 쪽 알림이 이미 집계됨
        final destIsSaving = account != null && acc.savingKeys.contains(account);
        final srcIsSaving = toSaving(cp);
        if (destIsSaving && !srcIsSaving) saved += amt;
        if (srcIsSaving && !destIsSaving) withdrawn += amt;
      }
    }
    return SavingsSummary(saved, withdrawn);
  }
}

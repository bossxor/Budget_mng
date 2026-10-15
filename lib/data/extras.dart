import 'package:sqflite/sqflite.dart';

import 'repo.dart';
import '../core/notification_policy.dart';

/// 태그와 검색.
class TagRepo {
  TagRepo(this._db);
  final Database _db;

  Future<List<String>> tagsOf(String txId) async {
    final r = await _db.query('tx_tag',
        where: 'tx_id=?', whereArgs: [txId], orderBy: 'tag');
    return r.map((m) => m['tag'] as String).toList();
  }

  Future<void> setTags(String txId, List<String> tags) async {
    final clean = {
      for (final t in tags)
        if (t.trim().isNotEmpty) t.trim().replaceFirst(RegExp(r'^#'), '')
    };
    await _db.delete('tx_tag', where: 'tx_id=?', whereArgs: [txId]);
    for (final t in clean) {
      await _db.insert('tx_tag', {'tx_id': txId, 'tag': t});
    }
  }

  /// 태그별 사용 횟수.
  Future<Map<String, int>> allTags() async {
    final r = await _db.rawQuery(
        'SELECT tag, COUNT(*) n FROM tx_tag GROUP BY tag ORDER BY n DESC, tag');
    return {for (final m in r) m['tag'] as String: m['n'] as int};
  }

  /// 조건은 모두 AND. 정산 몫이 아니라 거래 금액 기준으로 찾는다.
  Future<List<TxRow>> search({
    String? text,
    String? tag,
    String? category,
    String? type,
    int? minAmount,
    int? maxAmount,
    DateTime? from,
    DateTime? to,
    int limit = 300,
  }) async {
    final where = <String>['t.deleted_at IS NULL',confirmedTxFilter('t.')];
    final args = <Object?>[];
    if (text != null && text.trim().isNotEmpty) {
      where.add(
          "(t.merchant LIKE ? OR t.counterparty LIKE ? OR t.memo LIKE ? OR t.note LIKE ? OR t.id IN (SELECT tx_id FROM tx_tag WHERE tag LIKE ?))");
      final q = '%${text.trim()}%';
      args.addAll([q, q, q, q, q]);
    }
    if (tag != null) {
      where.add('t.id IN (SELECT tx_id FROM tx_tag WHERE tag=?)');
      args.add(tag);
    }
    if (category != null) {
      where.add(
          "(t.category=? OR t.id IN (SELECT tx_id FROM tx_split WHERE category=?))");
      args.addAll([category, category]);
    }
    if (type != null) {
      where.add('t.type=?');
      args.add(type);
    }
    if (minAmount != null) {
      where.add('t.amount>=?');
      args.add(minAmount);
    }
    if (maxAmount != null) {
      where.add('t.amount<=?');
      args.add(maxAmount);
    }
    if (from != null) {
      where.add('t.occurred_at>=?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('t.occurred_at<?');
      args.add(to.millisecondsSinceEpoch);
    }
    final r = await _db.rawQuery(
        'SELECT t.* FROM tx t WHERE ${where.join(' AND ')} ORDER BY t.occurred_at DESC LIMIT $limit',
        args);
    return r.map(TxRow.fromMap).toList();
  }
}

const _typeLabel = {
  'expense': '지출',
  'income': '입금',
  'transfer': '이체',
  'group': '모임통장',
};

String _csvCell(Object? v) {
  final s = v?.toString() ?? '';
  return RegExp(r'[",\r\n]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// 엑셀에서 바로 열리는 CSV(UTF-8 BOM). month가 없으면 전체 기간.
/// '가계부 반영'은 정산 몫·정산 입금을 반영한 금액이고, 이체와 모임통장은 0이다.
Future<String> exportCsv(Repo repo, {DateTime? month}) async {
  final where = ['deleted_at IS NULL',confirmedTxFilter()];
  final args = <Object?>[];
  if (month != null) {
    where.add('occurred_at>=? AND occurred_at<?');
    args.addAll([
      DateTime(month.year, month.month).millisecondsSinceEpoch,
      DateTime(month.year, month.month + 1).millisecondsSinceEpoch,
    ]);
  }
  final rows = await repo.db.query('tx',
      where: where.join(' AND '), whereArgs: args, orderBy: 'occurred_at');
  final mine = await repo.settlements.myAmountByTx();
  final paid = await repo.settlements.paidByTx();
  String two(int n) => n.toString().padLeft(2, '0');
  final lines = <String>['날짜,유형,금액,가계부 반영,내용,카테고리,계좌,메모'];
  for (final m in rows) {
    final t = TxRow.fromMap(m)
      ..mine = mine[m['id']]
      ..paid = paid[m['id']] ?? 0;
    final shown = (t.type == 'expense' || t.type == 'income') ? t.effective : 0;
    final d = t.occurredAt;
    lines.add([
      '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}',
      _typeLabel[t.type] ?? t.type,
      t.amount,
      shown,
      t.title,
      t.category ?? '',
      t.account ?? '',
      t.note ?? '',
    ].map(_csvCell).join(','));
  }
  return '\uFEFF${lines.join('\r\n')}\r\n';
}

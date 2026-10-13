import 'package:sqflite/sqflite.dart';

import 'repo.dart';

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
    final where = <String>['t.deleted_at IS NULL'];
    final args = <Object?>[];
    if (text != null && text.trim().isNotEmpty) {
      where.add(
          "(t.merchant LIKE ? OR t.counterparty LIKE ? OR t.memo LIKE ? OR t.id IN (SELECT tx_id FROM tx_tag WHERE tag LIKE ?))");
      final q = '%${text.trim()}%';
      args.addAll([q, q, q, q]);
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

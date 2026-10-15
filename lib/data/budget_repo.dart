import 'package:sqflite/sqflite.dart';
import '../core/notification_policy.dart';

/// 매달 비슷한 금액으로 반복되는 지출 (구독, 통신비 등).
class Recurring {
  Recurring(this.name, this.amount, this.months, this.lastDate);
  final String name;
  final int amount; // 최근 결제 금액
  final int months; // 연속으로 나온 달 수
  final DateTime lastDate;

  /// 다음 결제 예상일: 마지막 결제일 + 1개월 (말일 넘치면 그 달 말일).
  DateTime get nextDate {
    final y = lastDate.month == 12 ? lastDate.year + 1 : lastDate.year;
    final m = lastDate.month == 12 ? 1 : lastDate.month + 1;
    final lastDay = DateTime(y, m + 1, 0).day;
    return DateTime(y, m, lastDate.day > lastDay ? lastDay : lastDate.day);
  }
}

/// 예산 상태 한 줄.
class BudgetLine {
  BudgetLine(this.category, this.limit, this.spent);
  final String? category; // null = 전체 예산
  final int limit;
  final int spent;
  double get ratio => limit <= 0 ? 0 : spent / limit;
  int get left => limit - spent;
}

/// 현재 월의 누적 지출을 경과 일수로 나눈 단순 추세 예상.
class BudgetForecast {
  BudgetForecast(this.limit, this.spent, this.projected);
  final int limit, spent, projected;
  int get excess => projected > limit ? projected - limit : 0;
  static BudgetForecast? calculate({required DateTime month,
      required DateTime now, required int limit, required int spent}) {
    if (month.year != now.year || month.month != now.month ||
        now.day < 3 || limit <= 0 || spent <= 0) {
      return null;
    }
    final days = DateTime(now.year, now.month + 1, 0).day;
    return BudgetForecast(limit, spent, (spent * days / now.day).round());
  }
}

class BudgetRepo {
  BudgetRepo(this._db);
  final Database _db;

  static Future<void> schema(Database d) async {
    // category가 ''이면 전체 예산.
    await d.execute('''CREATE TABLE IF NOT EXISTS budget(
      category TEXT PRIMARY KEY, monthly_limit INTEGER)''');
  }

  Future<Map<String, int>> budgets() async {
    final r = await _db.query('budget');
    return {
      for (final m in r) m['category'] as String: m['monthly_limit'] as int
    };
  }

  /// amount가 null이거나 0 이하이면 예산을 지운다.
  Future<void> setBudget(String? category, int? amount) async {
    final key = category ?? '';
    if (amount == null || amount <= 0) {
      await _db.delete('budget', where: 'category=?', whereArgs: [key]);
    } else {
      await _db.insert('budget', {'category': key, 'monthly_limit': amount},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// 예산 대비 사용 현황. 사용률 높은 순, 전체 예산이 맨 앞.
  Future<List<BudgetLine>> status(int totalSpent, Map<String, int> byCategory) async {
    final b = await budgets();
    final out = <BudgetLine>[];
    if (b.containsKey('')) out.add(BudgetLine(null, b['']!, totalSpent));
    final cats = [
      for (final e in b.entries)
        if (e.key.isNotEmpty) BudgetLine(e.key, e.value, byCategory[e.key] ?? 0)
    ]..sort((a, c) => c.ratio.compareTo(a.ratio));
    return out..addAll(cats);
  }

  /// 같은 가맹점에서 금액 차이 5% 이내로 3개월 이상 연속 결제된 지출.
  /// ponytail: 가맹점명 완전 일치로만 묶는다. 이름이 매달 조금씩 바뀌면 못 잡는다.
  Future<List<Recurring>> recurring({DateTime? now, int minMonths = 3}) async {
    final today = now ?? DateTime.now();
    final from = DateTime(today.year, today.month - 5).millisecondsSinceEpoch;
    final r = await _db.rawQuery('''SELECT merchant, amount, occurred_at FROM tx
      WHERE type='expense' AND amount>0 AND deleted_at IS NULL AND ${confirmedTxFilter()} AND merchant IS NOT NULL
        AND occurred_at>=? ORDER BY occurred_at''', [from]);

    // 가맹점 -> 달(yyyy*12+mm) -> 그 달 마지막 결제
    final byName = <String, Map<int, (int, DateTime)>>{};
    for (final m in r) {
      final d = DateTime.fromMillisecondsSinceEpoch(m['occurred_at'] as int);
      final key = d.year * 12 + d.month - 1;
      byName.putIfAbsent(m['merchant'] as String, () => {})[key] =
          (m['amount'] as int, d);
    }

    final out = <Recurring>[];
    final thisMonth = today.year * 12 + today.month - 1;
    byName.forEach((name, months) {
      // 이번 달이나 지난달에 결제가 있어야 아직 이어지는 반복으로 본다.
      final end = months.containsKey(thisMonth) ? thisMonth : thisMonth - 1;
      if (!months.containsKey(end)) return;
      final last = months[end]!;
      var run = 0;
      for (var k = end; months.containsKey(k); k--) {
        final a = months[k]!.$1;
        if ((a - last.$1).abs() > last.$1 * 0.05) break;
        run++;
      }
      if (run >= minMonths) out.add(Recurring(name, last.$1, run, last.$2));
    });
    out.sort((a, b) => a.nextDate.compareTo(b.nextDate));
    return out;
  }
}

import 'repo.dart';

class CategoryDelta {
  CategoryDelta(this.category, this.amount, this.previous);
  final String category;
  final int amount;
  final int previous;
  int get delta => amount - previous;
}

class MerchantTotal {
  MerchantTotal(this.name, this.amount, this.count);
  final String name;
  final int amount;
  final int count;
}

/// 월말 결산. 저장하지 않고 거래에서 그때그때 계산한다.
class MonthReport {
  MonthReport({
    required this.expense,
    required this.income,
    required this.prevExpense,
    required this.categories,
    required this.topMerchants,
    required this.biggestDay,
    required this.biggestDayAmount,
    required this.txCount,
  });
  final int expense;
  final int income;
  final int prevExpense;
  final List<CategoryDelta> categories;
  final List<MerchantTotal> topMerchants;
  final DateTime? biggestDay;
  final int biggestDayAmount;
  final int txCount;

  int get net => income - expense;
  int get expenseDelta => expense - prevExpense;
}

Future<MonthReport> buildReport(Repo repo, DateTime month) async {
  final cur = await repo.summary(month);
  final prev = await repo.summary(DateTime(month.year, month.month - 1));
  final rows = await repo.monthTx(month);

  final cats = <CategoryDelta>[
    for (final e in cur.byCategory.entries)
      CategoryDelta(e.key, e.value, prev.byCategory[e.key] ?? 0),
  ]..sort((a, b) => b.amount.compareTo(a.amount));

  final byMerchant = <String, (int, int)>{};
  final byDay = <DateTime, int>{};
  var n = 0;
  for (final t in rows.where((t) => t.type == 'expense' && t.effective > 0)) {
    n++;
    final m = byMerchant[t.title] ?? (0, 0);
    byMerchant[t.title] = (m.$1 + t.effective, m.$2 + 1);
    final d = DateTime(t.occurredAt.year, t.occurredAt.month, t.occurredAt.day);
    byDay[d] = (byDay[d] ?? 0) + t.effective;
  }
  final top = byMerchant.entries
      .map((e) => MerchantTotal(e.key, e.value.$1, e.value.$2))
      .toList()
    ..sort((a, b) => b.amount.compareTo(a.amount));
  DateTime? bd;
  var ba = 0;
  byDay.forEach((d, v) {
    if (v > ba) {
      ba = v;
      bd = d;
    }
  });
  return MonthReport(
    expense: cur.expense,
    income: cur.income,
    prevExpense: prev.expense,
    categories: cats,
    topMerchants: top.take(5).toList(),
    biggestDay: bd,
    biggestDayAmount: ba,
    txCount: n,
  );
}

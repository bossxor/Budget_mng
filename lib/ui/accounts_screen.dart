import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/planning_repo.dart';
import '../data/repo.dart';
import 'screens.dart';
import 'theme.dart';

bool _looksLikeCard(String key) => RegExp(r'^[가-힣A-Za-z]+\d{4}$').hasMatch(key);

int _monthsLeft(DateTime goal) {
  final n = DateTime.now();
  final m = (goal.year - n.year) * 12 + goal.month - n.month;
  return m < 1 ? 1 : m;
}

class AccountsScreen extends StatelessWidget {
  const AccountsScreen(this.s, {super.key});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = s.accounts
        .where((a) => !_looksLikeCard(a.key))
        .fold<int>(0, (a, x) => a + (x.balance ?? 0));
    final sv = s.savings;
    final income = s.summary.income;
    final rate = income > 0 ? (sv.net * 100 / income) : null;
    final sorted = [...s.accounts]..sort((x, y) {
        final ux = x.role == 'unset' ? 1 : 0, uy = y.role == 'unset' ? 1 : 0;
        if (ux != uy) return ux - uy;
        return (y.balance ?? -1).compareTo(x.balance ?? -1);
      });
    final labelOf = {for (final a in s.accounts) a.key: a.label};

    return ListView(padding: const EdgeInsets.all(16), children: [
      Container(
        padding: const EdgeInsets.all(20),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const LinearGradient(
            colors: [Color(0xFF1FB57A), Color(0xFF5AD1A3)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('내 주머니 전체',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.9))),
          const SizedBox(height: 4),
          Text('${fmt(total)}원',
              style: const TextStyle(
                  color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800)),
          Text('알림으로 확인된 잔액의 합이에요',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12)),
        ]),
      ),
      if (s.accounts.any((a) => savingRoles.contains(a.role)))
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              const RoundIcon(Icons.savings_rounded, Dsn.mint),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${s.month.month}월 저축',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                  Text('${sv.net < 0 ? '−' : ''}${fmt(sv.net)}원',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  if (sv.withdrawn > 0)
                    Text('저축 ${fmt(sv.saved)}원 − 인출 ${fmt(sv.withdrawn)}원',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ]),
              ),
              if (rate != null)
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('저축률', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  Text('${rate.toStringAsFixed(1)}%',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w800, color: Dsn.mint)),
                ]),
            ]),
          ),
        ),
      _PlanCard(s, labelOf),
      if (s.accounts.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('입출금 알림이 오면 통장이 자동으로 나타나요.\n이름과 용도를 정해 주머니를 나눠 보세요.',
              textAlign: TextAlign.center),
        ),
      for (final a in sorted) _AccountCard(s, a, labelOf),
    ]);
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard(this.s, this.a, this.labelOf);
  final AppState s;
  final AccountRow a;
  final Map<String, String> labelOf;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bal = a.balance ?? 0;
    final goal = a.goalAmount;
    final lines = <String>[];
    if (a.monthlyTarget != null) lines.add('월 목표 ${fmt(a.monthlyTarget!)}원');
    if (a.paysFrom != null) {
      lines.add('대금 결제: ${labelOf[a.paysFrom] ?? a.paysFrom}');
    }
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _editAccount(context, s, a, labelOf),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              RoundIcon(
                  _looksLikeCard(a.key)
                      ? Icons.credit_card_rounded
                      : Icons.account_balance_wallet_rounded,
                  Dsn.role(a.role)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.label,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  Text(roles[a.role] ?? '미지정',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                ]),
              ),
              Text(a.balance == null ? '-' : '${fmt(bal)}원',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ]),
            if (goal != null && goal > 0) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: (bal / goal).clamp(0.0, 1.0),
                  minHeight: 10,
                  color: Dsn.role(a.role),
                  backgroundColor: Dsn.role(a.role).withValues(alpha: 0.15),
                ),
              ),
              const SizedBox(height: 6),
              Text(_goalText(a, bal, goal),
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ],
            if (lines.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(lines.join(' · '),
                  style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ],
          ]),
        ),
      ),
    );
  }

  String _goalText(AccountRow a, int bal, int goal) {
    final pct = (bal * 100 / goal).clamp(0, 999).toStringAsFixed(0);
    var t = '목표 ${fmt(goal)}원 · $pct%';
    final gd = a.goalDate;
    if (gd != null && bal < goal) {
      final m = _monthsLeft(gd);
      final need = ((goal - bal) / m).ceil();
      t += ' · ${gd.year}.${gd.month} 까지 월 ${fmt(need)}원 필요';
    } else if (bal >= goal) {
      t += ' · 달성!';
    }
    return t;
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard(this.s, this.labelOf);
  final AppState s;
  final Map<String, String> labelOf;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
                child: Text('이번 달 배분 계획',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            TextButton.icon(
              onPressed: () => _addPlan(context, s, labelOf),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('추가'),
            ),
          ]),
          if (s.plans.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, right: 8),
              child: Text('월급이 들어오면 어느 통장에 얼마를 나눌지 적어 두면, 이체했는지 자동으로 체크해요.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
            ),
          for (final p in s.plans)
            Dismissible(
              key: ValueKey(p.plan.id),
              direction: DismissDirection.endToStart,
              background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  child: const Icon(Icons.delete_outline_rounded)),
              onDismissed: (_) async {
                await s.repo.planning.deletePlan(p.plan.id);
                await s.refresh();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Icon(
                      p.done
                          ? Icons.check_circle_rounded
                          : (p.overdue
                              ? Icons.error_rounded
                              : Icons.radio_button_unchecked_rounded),
                      color: p.done
                          ? Dsn.mint
                          : (p.overdue ? Dsn.coral : cs.outline)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${labelOf[p.plan.fromKey] ?? p.plan.fromKey} → ${labelOf[p.plan.toKey] ?? p.plan.toKey}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                          p.done
                              ? '${p.plan.day}일까지 · 완료'
                              : p.paid > 0
                                  ? '${p.plan.day}일까지 · ${fmt(p.paid)}원 보냄, ${fmt(p.remaining)}원 남음'
                                  : '${p.plan.day}일까지${p.overdue ? ' · 아직 안 보냈어요' : ''}',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: p.overdue ? Dsn.coral : cs.onSurfaceVariant)),
                    ]),
                  ),
                  Text('${fmt(p.plan.amount)}원',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

void _addPlan(BuildContext context, AppState s, Map<String, String> labelOf) {
  final keys = s.accounts.where((a) => !_looksLikeCard(a.key)).toList();
  String? from = keys.isEmpty ? null : keys.first.key;
  String? to;
  final custom = TextEditingController();
  final amt = TextEditingController();
  final day = TextEditingController(text: '10');
  String? err;
  showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('배분 계획 추가',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          const Text('보내는 통장'),
          DropdownButton<String>(
            isExpanded: true,
            value: from,
            hint: const Text('통장을 먼저 등록하세요'),
            items: [
              for (final a in keys)
                DropdownMenuItem(value: a.key, child: Text(a.label)),
            ],
            onChanged: (v) => setS(() => from = v),
          ),
          const SizedBox(height: 8),
          const Text('받는 통장'),
          DropdownButton<String>(
            isExpanded: true,
            value: to,
            hint: const Text('선택하거나 아래에 직접 입력'),
            items: [
              for (final a in keys.where((a) => a.key != from))
                DropdownMenuItem(value: a.key, child: Text(a.label)),
            ],
            onChanged: (v) => setS(() => to = v),
          ),
          TextField(
            controller: custom,
            decoration: const InputDecoration(labelText: '또는 이름 직접 입력 (예: 여행비 통장)'),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: amt,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '금액', suffixText: '원'),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: TextField(
                controller: day,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '매월', suffixText: '일까지'),
              ),
            ),
          ]),
          if (err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(err!, style: const TextStyle(color: Dsn.coral)),
            ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () async {
                final a = int.tryParse(amt.text.replaceAll(',', ''));
                final d = int.tryParse(day.text);
                final dest = custom.text.trim().isNotEmpty ? custom.text.trim() : to;
                if (from == null) {
                  setS(() => err = '보내는 통장을 고르세요');
                } else if (dest == null) {
                  setS(() => err = '받는 통장을 고르거나 이름을 입력하세요');
                } else if (a == null || a <= 0) {
                  setS(() => err = '금액을 입력하세요');
                } else if (d == null || d < 1 || d > 31) {
                  setS(() => err = '날짜는 1~31 사이로 입력하세요');
                } else {
                  await s.repo.planning.addPlan(from!, dest, a, d);
                  await s.refresh();
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              child: const Text('저장'),
            ),
          ),
        ]),
      ),
    ),
  );
}

void _editAccount(BuildContext context, AppState s, AccountRow a,
    Map<String, String> labelOf) {
  final name = TextEditingController(text: a.label);
  final monthly = TextEditingController(text: a.monthlyTarget?.toString() ?? '');
  final goal = TextEditingController(text: a.goalAmount?.toString() ?? '');
  var role = a.role;
  DateTime? goalDate = a.goalDate;
  String? paysFrom = a.paysFrom;
  final isCard = _looksLikeCard(a.key);
  final bankKeys = s.accounts.where((x) => !_looksLikeCard(x.key)).toList();
  showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(a.key, style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 8),
          TextField(controller: name, decoration: const InputDecoration(labelText: '이름')),
          const SizedBox(height: 16),
          const Text('어떤 주머니인가요?', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in roles.entries)
              ChoiceChip(
                avatar: CircleAvatar(backgroundColor: Dsn.role(e.key), radius: 6),
                label: Text(e.value),
                selected: role == e.key,
                onSelected: (_) => setS(() => role = e.key),
              ),
          ]),
          const SizedBox(height: 16),
          if (isCard) ...[
            const Text('대금이 빠지는 통장', style: TextStyle(fontWeight: FontWeight.w600)),
            DropdownButton<String>(
              isExpanded: true,
              value: paysFrom,
              hint: const Text('선택'),
              items: [
                for (final b in bankKeys)
                  DropdownMenuItem(value: b.key, child: Text(b.label)),
              ],
              onChanged: (v) => setS(() => paysFrom = v),
            ),
          ] else ...[
            TextField(
              controller: monthly,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: '매월 채울 금액 (선택)', suffixText: '원'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: goal,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: '목표 금액 (선택, 여행·적금용)', suffixText: '원'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: Text(goalDate == null
                      ? '목표일 없음'
                      : '목표일 ${goalDate!.year}.${goalDate!.month}.${goalDate!.day}')),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: goalDate ?? DateTime.now().add(const Duration(days: 180)),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 3650)),
                  );
                  if (d != null) setS(() => goalDate = d);
                },
                child: const Text('날짜 선택'),
              ),
              if (goalDate != null)
                TextButton(
                    onPressed: () => setS(() => goalDate = null),
                    child: const Text('지우기')),
            ]),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () async {
                await s.repo.setAccount(a.key,
                    label: name.text.trim().isEmpty ? a.key : name.text.trim(),
                    role: role);
                await s.repo.setAccountGoal(a.key,
                    monthlyTarget: int.tryParse(monthly.text.replaceAll(',', '')),
                    goalAmount: int.tryParse(goal.text.replaceAll(',', '')),
                    goalDate: goalDate,
                    paysFrom: paysFrom);
                await s.refresh();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('저장'),
            ),
          ),
        ]),
      ),
    ),
  );
}

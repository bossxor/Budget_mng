import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../data/budget_repo.dart';
import '../core/parsers.dart';
import '../data/repo.dart';
import 'accounts_screen.dart';
import 'extras_screens.dart';
import 'settings_screen.dart';
import 'package:share_plus/share_plus.dart';

import 'settlement_screens.dart';
import 'theme.dart';

String fmt(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

const _weekday = ['월', '화', '수', '목', '금', '토', '일'];
String dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(DateTime(d.year, d.month, d.day)).inDays;
  final base = '${d.month}월 ${d.day}일 ${_weekday[d.weekday - 1]}요일';
  if (diff == 0) return '오늘 · $base';
  if (diff == 1) return '어제 · $base';
  return base;
}

IconData catIcon(String? c) => switch (c) {
      '카페' => Icons.local_cafe_rounded,
      '식비' => Icons.restaurant_rounded,
      '편의점' => Icons.storefront_rounded,
      '배달' => Icons.delivery_dining_rounded,
      '교통' => Icons.directions_bus_rounded,
      '쇼핑' => Icons.shopping_bag_rounded,
      '구독' => Icons.subscriptions_rounded,
      '의료' => Icons.local_hospital_rounded,
      '송금' => Icons.send_rounded,
      '생활' => Icons.home_rounded,
      '문화/여가' => Icons.movie_rounded,
      '경조사' => Icons.card_giftcard_rounded,
      null => Icons.help_outline_rounded,
      _ => Icons.sell_rounded,
    };

/// 금액: 지출은 −(코랄), 입금은 +(민트). 이체/모임통장은 회색. 색만이 아니라 부호도 같이 쓴다.
class Amount extends StatelessWidget {
  const Amount(this.t, {super.key, this.big = false});
  final TxRow t;
  final bool big;
  @override
  Widget build(BuildContext context) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final (sign, color) = switch (t.type) {
      'expense' => (t.amount < 0 ? '+' : '−', Dsn.coral),
      'income' => ('+', Dsn.mint),
      _ => ('', grey),
    };
    return Text('$sign${fmt(t.amount)}원',
        style: TextStyle(
            color: color,
            fontWeight: FontWeight.w700,
            fontSize: big ? 24 : 16,
            fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

class TxTile extends StatelessWidget {
  const TxTile(this.t, {super.key, this.onTap});
  final TxRow t;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final grey = cs.onSurfaceVariant;
    final (icon, color) = switch (t.type) {
      'income' => (Icons.south_west_rounded, Dsn.mint),
      'transfer' => (Icons.swap_horiz_rounded, grey),
      'group' => (Icons.groups_rounded, grey),
      _ => (catIcon(t.category), Dsn.cat(t.category)),
    };
    final sub = [
      if (t.type == 'transfer') '내 계좌 간 이체',
      if (t.type == 'group') '모임통장',
      if (t.type == 'income') t.paid > 0 ? '입금 · 정산 ${fmt(t.paid)}원 연결' : '입금',
      if (t.type == 'expense') t.category ?? '미분류',
      if (t.type == 'expense' && t.mine != null) '내 몫 ${fmt(t.mine!)}원',
      if (t.account != null) t.account!,
      if (t.note != null) t.note!,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          RoundIcon(icon, color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                    child: Text(t.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                if (t.status == 'review')
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                        color: Dsn.amber.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(10)),
                    child: const Text('확인 필요',
                        style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFFB27300),
                            fontWeight: FontWeight.w600)),
                  ),
              ]),
              const SizedBox(height: 2),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: grey)),
            ]),
          ),
          const SizedBox(width: 8),
          if (t.type == 'transfer' || t.type == 'group')
            Text('${fmt(t.amount)}원', style: TextStyle(color: grey, fontWeight: FontWeight.w600))
          else
            Amount(t),
        ]),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell(this.s, {super.key});
  final AppState s;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _i = 0;
  String? _pendingAction;
  static const _native = MethodChannel('jumeoni/native');

  @override
  void initState() {
    super.initState();
    widget.s.addListener(_resumeAction);
    // 앱이 떠 있을 때 바로가기로 다시 들어온 경우.
    _native.setMethodCallHandler((call) async {
      if (call.method == 'launchAction') {
        _run(await _native.invokeMethod<String>('takeLaunchAction'));
      }
    });
    // 바로가기로 앱이 새로 켜진 경우.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        _run(await _native.invokeMethod<String>('takeLaunchAction'));
      } catch (_) {}
    });
  }

  void _run(String? action) {
    if (action != 'quick_add' || !mounted) return;
    if (widget.s.lock.locked) {
      _pendingAction = action;
      return;
    }
    setState(() => _i = 1); // 내역 탭에서 입력 시트를 연다
    showManualEntry(context, widget.s);
  }

  void _resumeAction() {
    if (_pendingAction == null || widget.s.lock.locked) return;
    final action = _pendingAction;
    _pendingAction = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _run(action));
  }

  @override
  void dispose() {
    widget.s.removeListener(_resumeAction);
    _native.setMethodCallHandler(null);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final pages = [
      HomeScreen(s, goHistory: () => setState(() => _i = 1)),
      HistoryScreen(s),
      SettlementListScreen(s),
      AccountsScreen(s),
      SettingsScreen(s),
    ];
    return Scaffold(
      body: SafeArea(child: pages[_i]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (v) => setState(() => _i = v),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: '홈'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long_rounded),
              label: '내역'),
          NavigationDestination(
              icon: Icon(Icons.groups_outlined),
              selectedIcon: Icon(Icons.groups_rounded),
              label: '정산'),
          NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined),
              selectedIcon: Icon(Icons.account_balance_wallet_rounded),
              label: '통장'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings_rounded),
              label: '설정'),
        ],
      ),
    );
  }
}

class MonthBar extends StatelessWidget {
  const MonthBar(this.s, {super.key});
  final AppState s;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
                onPressed: () => s.shiftMonth(-1),
                icon: const Icon(Icons.chevron_left_rounded)),
            Expanded(child: Text('${s.month.year}년 ${s.month.month}월',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            IconButton(
                onPressed: () => s.shiftMonth(1),
                icon: const Icon(Icons.chevron_right_rounded)),
          ],
        ),
      );
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(18)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ]),
        ),
      );
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard(this.s);
  final AppState s;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = s.budgetLines.where((b) => b.category == null).firstOrNull;
    final cats = s.budgetLines.where((b) => b.category != null).toList();
    final days = s.daysLeftThisMonth;
    final forecast = s.budgetForecast;
    Color barColor(double r) => r >= 1 ? Dsn.coral : (r >= 0.8 ? Dsn.amber : Dsn.blue);
    Widget bar(BudgetLine b, {double h = 8}) => ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: b.ratio.clamp(0.0, 1.0),
            minHeight: h,
            color: barColor(b.ratio),
            backgroundColor: barColor(b.ratio).withValues(alpha: 0.15),
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('선택한 달 예산',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          if (total != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text(total.left >= 0 ? '${fmt(total.left)}원 남았어요' : '${fmt(total.left)}원 넘었어요',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: total.left >= 0 ? cs.onSurface : Dsn.coral))),
              const SizedBox(width: 12),
              Text('${(total.ratio * 100).round()}% 사용',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
            ]),
            const SizedBox(height: 8),
            bar(total, h: 10),
            if (days != null && total.left > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('오늘부터 하루 ${fmt(total.left ~/ days)}원씩 쓸 수 있어요',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
              ),
          ],
          if (forecast != null && forecast.excess > 0) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Dsn.coral.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.trending_up_rounded, color: Dsn.coral, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(total != null && total.left < 0 ? '이미 예산을 초과했어요' : '이 속도라면 예산을 넘을 수 있어요',
                      style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('월말 예상 ${fmt(forecast.projected)}원 · 예산보다 ${fmt(forecast.excess)}원 초과',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text('현재까지의 하루 평균 기준이며 실제 지출과 달라질 수 있어요.',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
                ])),
              ]),
            ),
          ],
          for (final b in cats)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(b.category!, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('${fmt(b.spent)} / ${fmt(b.limit)}원',
                      style: TextStyle(
                          fontSize: 13,
                          color: b.ratio >= 1 ? Dsn.coral : cs.onSurfaceVariant)),
                ]),
                const SizedBox(height: 6),
                bar(b),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _RecurringCard extends StatelessWidget {
  const _RecurringCard(this.s);
  final AppState s;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sum = s.recurring.fold<int>(0, (a, r) => a + r.amount);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('고정지출',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const Spacer(),
            Text('${s.recurring.length}건 · 월 ${fmt(sum)}원',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          ]),
          const SizedBox(height: 6),
          for (final r in s.recurring.take(4))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                const RoundIcon(Icons.autorenew_rounded, Dsn.blue, size: 34),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('다음 예상 ${r.nextDate.month}월 ${r.nextDate.day}일 · ${r.months}개월째',
                        style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
                  ]),
                ),
                Text('${fmt(r.amount)}원',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
        ]),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen(this.s, {super.key, required this.goHistory});
  final AppState s;
  final VoidCallback goHistory;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sm = s.summary;
    final cats = sm.byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxV = cats.isEmpty ? 1 : cats.first.value;
    final net = sm.income - sm.expense;
    final recent = s.rows.where((t) => t.type != 'group').take(4).toList();
    return RefreshIndicator(
      onRefresh: s.refresh,
      child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(20, 12, 20, 28), children: [
        Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('주머니', style: TextStyle(color: cs.onSurface, fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('내 돈의 흐름을 한눈에', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          ])),
        MonthBar(s),
        if (!s.listenerOn)
          Card(
            color: const Color(0xFFFFE9E9),
            child: ListTile(
              leading: const Icon(Icons.notifications_off_rounded, color: Dsn.coral),
              title: const Text('알림 접근이 꺼져 있어요',
                  style: TextStyle(color: Color(0xFF8A1C1C), fontWeight: FontWeight.w700)),
              subtitle: const Text('켜면 카드·입출금 알림이 자동으로 들어와요',
                  style: TextStyle(color: Color(0xFF8A1C1C))),
              trailing: FilledButton(
                  onPressed: s.openListenerSettings,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 36), backgroundColor: Dsn.coral),
                  child: const Text('켜기')),
            ),
          ),
        // 여백 중심 요약: 금액을 먼저, 수입/차액을 나란히 배치.
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s.month.month}월 쓴 돈', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 6),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
              child: Text('${fmt(sm.expense)}원', style: TextStyle(
                color: cs.onSurface, fontSize: 38, fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()]))),
            const SizedBox(height: 20),
            Row(children: [
              _MiniStat('들어온 돈', '${fmt(sm.income)}원'),
              const SizedBox(width: 20),
              _MiniStat('수입 − 지출', '${net < 0 ? '−' : ''}${fmt(net)}원'),
            ]),
          ]),
        ),
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: () => showManualEntry(context, s),
            icon: const Icon(Icons.add_rounded), label: const Text('직접 입력'))),
          const SizedBox(width: 12),
          Expanded(child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SettlementListScreen(s))),
            icon: const Icon(Icons.groups_outlined), label: const Text('정산 관리'))),
        ]),
        const SizedBox(height: 16),
        if (s.receivable > 0)
          Card(child: ListTile(
            leading: const RoundIcon(Icons.groups_rounded, Dsn.blue, size: 40),
            title: Text('받을 돈 ${fmt(s.receivable)}원',
              style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('아직 끝나지 않은 정산을 확인해요'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SettlementListScreen(s))),
          )),
        if (sm.reviewCount > 0)
          Card(
            color: const Color(0xFFFFF4DB),
            child: ListTile(
              leading: const Icon(Icons.priority_high_rounded, color: Color(0xFFB27300)),
              title: Text('확인이 필요한 내역 ${sm.reviewCount}건',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, color: Color(0xFF6B4A00))),
              trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF6B4A00)),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => ReviewScreen(s))),
            ),
          ),
        for (final g in s.gaps.take(2))
          Card(
            color: const Color(0xFFFFF4DB),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(children: [
                const Icon(Icons.search_off_rounded, color: Color(0xFFB27300)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('알림이 빠진 것 같아요',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, color: Color(0xFF6B4A00))),
                    Text(
                        '${s.accounts.where((a) => a.key == g.account).map((a) => a.label).firstOrNull ?? g.account} 잔액이 ${fmt(g.amount)}원 ${g.amount > 0 ? '더 많아요' : '더 적어요'}',
                        style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B4A00))),
                  ]),
                ),
                TextButton(
                  onPressed: () async {
                    await s.repo.resolveGap(g.id);
                    await s.refresh();
                  },
                  child: const Text('무시'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 38),
                      backgroundColor: const Color(0xFFB27300)),
                  onPressed: () async {
                    final saved = await showManualEntry(context, s,
                        initialType: g.amount > 0 ? 'income' : 'expense',
                        initialAmount: g.amount.abs(),
                        initialTitle: '빠진 내역');
                    if (saved == true) {
                      await s.repo.resolveGap(g.id);
                      await s.refresh();
                    }
                  },
                  child: const Text('추가'),
                ),
              ]),
            ),
          ),
        if (s.backupDue)
          Card(
            child: ListTile(
              leading: const RoundIcon(Icons.cloud_upload_rounded, Dsn.blue, size: 40),
              title: const Text('백업해 두면 안심이에요',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(s.lastBackupAt == null
                  ? '아직 백업한 적이 없어요'
                  : '마지막 백업 ${DateTime.now().difference(s.lastBackupAt!).inDays}일 전'),
              trailing: FilledButton.tonal(
                  onPressed: () => exportBackup(context, s), child: const Text('백업')),
            ),
          ),
        if (s.budgetLines.isNotEmpty) _BudgetCard(s),
        if (s.recurring.isNotEmpty) _RecurringCard(s),
        for (final o in s.overdue.take(2))
          Card(
            color: const Color(0xFFFFEFE0),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(children: [
                const Icon(Icons.hourglass_bottom_rounded, color: Color(0xFFB25E00)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${o.share.name}님 ${fmt(o.share.remaining)}원 아직이에요',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, color: Color(0xFF6B3A00))),
                    Text('${o.settlement.title} · ${o.days}일 지났어요',
                        style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B3A00))),
                  ]),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 38),
                      backgroundColor: const Color(0xFFB25E00)),
                  onPressed: () => SharePlus.instance
                      .share(ShareParams(text: s.requestText(o))),
                  child: const Text('다시 요청'),
                ),
              ]),
            ),
          ),
        for (final g in s.suggestions.take(3))
          Card(
            color: const Color(0xFFE6F8EF),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(children: [
                const Icon(Icons.savings_rounded, color: Dsn.mint),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        '${g.share.name}님 ${fmt(g.amount)}원 입금',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, color: Color(0xFF0F5A3C))),
                    Text(
                        '${g.settlement.title} 정산에 연결할까요?${g.byName ? '' : ' (금액이 같아요)'}',
                        style: const TextStyle(fontSize: 12.5, color: Color(0xFF0F5A3C))),
                  ]),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 38), backgroundColor: Dsn.mint),
                  onPressed: () async {
                    await s.repo.settlements.pay(g.share, g.deposit, g.amount);
                    await s.refresh();
                  },
                  child: const Text('연결'),
                ),
              ]),
            ),
          ),
        Card(
          child: ListTile(
            leading: const RoundIcon(Icons.insights_rounded, Dsn.blueDeep, size: 40),
            title: const Text('월말 결산 보기', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('지난달과 비교하고 많이 쓴 곳을 확인해요'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => ReportScreen(s))),
          ),
        ),
        if (recent.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Row(children: [
                    const Text('최근 내역',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    TextButton(onPressed: goHistory, child: const Text('전체 보기')),
                  ]),
                ),
                for (final t in recent) TxTile(t),
              ]),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('어디에 썼을까요',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              if (cats.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text('아직 지출 내역이 없어요. 알림이 오면 자동으로 채워져요.',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                ),
              for (final c in cats)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(children: [
                    RoundIcon(catIcon(c.key == '미분류' ? null : c.key),
                        Dsn.cat(c.key == '미분류' ? null : c.key),
                        size: 38),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Text(c.key, style: const TextStyle(fontWeight: FontWeight.w600)),
                          const Spacer(),
                          Text('${fmt(c.value)}원',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: c.value / maxV,
                            minHeight: 8,
                            color: Dsn.cat(c.key == '미분류' ? null : c.key),
                            backgroundColor:
                                Dsn.cat(c.key == '미분류' ? null : c.key).withValues(alpha: 0.14),
                          ),
                        ),
                      ]),
                    ),
                  ]),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen(this.s, {super.key});
  final AppState s;
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String? _acct; // null = 전체

  /// 선택한 통장에서 나간 거래: 그 통장 자체 + 대금이 그 통장에서 빠지는 카드.
  Set<String> _keysFor(String key) => {
        key,
        for (final a in widget.s.accounts)
          if (a.paysFrom == key) a.key,
      };

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final keys = _acct == null ? null : _keysFor(_acct!);
    final rows = keys == null
        ? s.rows
        : s.rows.where((t) => t.account != null && keys.contains(t.account)).toList();
    final groups = <DateTime, List<TxRow>>{};
    for (final t in rows) {
      final d = DateTime(t.occurredAt.year, t.occurredAt.month, t.occurredAt.day);
      groups.putIfAbsent(d, () => []).add(t);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    final bankAccts = s.accounts
        .where((a) => !RegExp(r'^[가-힣A-Za-z]+d{4}$').hasMatch(a.key))
        .toList();
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showManualEntry(context, s),
        icon: const Icon(Icons.add_rounded),
        label: const Text('직접 입력'),
      ),
      body: Column(children: [
        Row(children: [
          const SizedBox(width: 48),
          Expanded(child: MonthBar(s)),
          IconButton(
            tooltip: '검색',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => SearchScreen(s))),
          ),
        ]),
        if (bankAccts.length > 1)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: const Text('전체'),
                    selected: _acct == null,
                    onSelected: (_) => setState(() => _acct = null),
                  ),
                ),
                for (final a in bankAccts)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      avatar: CircleAvatar(
                          backgroundColor: Dsn.role(a.role), radius: 6),
                      label: Text(a.label),
                      selected: _acct == a.key,
                      onSelected: (_) => setState(() => _acct = a.key),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: days.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.inbox_rounded,
                      size: 56, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 8),
                  const Text('이 달에는 내역이 없어요'),
                ]))
              : RefreshIndicator(
                  onRefresh: s.refresh,
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                      children: [
                        for (final d in days) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                            child: Row(children: [
                              Expanded(
                                  child: Text(dayLabel(d),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700, fontSize: 14))),
                              Builder(builder: (context) {
                                final sum = groups[d]!
                                    .where((t) => t.type == 'expense')
                                    .fold<int>(0, (a, t) => a + t.effective);
                                return sum == 0
                                    ? const SizedBox.shrink()
                                    : Text('−${fmt(sum)}원',
                                        style: TextStyle(
                                            fontSize: 13,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant));
                              }),
                            ]),
                          ),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                              child: Column(children: [
                                for (final t in groups[d]!)
                                  TxTile(t, onTap: () => showEditSheet(context, s, t)),
                              ]),
                            ),
                          ),
                        ],
                      ]),
                ),
        ),
      ]),
    );
  }
}

Future<void> showEditSheet(BuildContext context, AppState s, TxRow t) {
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Amount(t, big: true),
          const SizedBox(height: 20),
          const Text('카테고리', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in allCategories)
              ChoiceChip(
                avatar: Icon(catIcon(c), size: 18, color: Dsn.cat(c)),
                label: Text(c),
                selected: t.category == c,
                onSelected: (_) async {
                  await s.repo.setCategory(t, c);
                  await s.refresh();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 18),
              label: const Text('새 카테고리'),
              onPressed: () async {
                final ctl = TextEditingController();
                final name = await showDialog<String>(
                  context: ctx,
                  builder: (d) => AlertDialog(
                    title: const Text('새 카테고리'),
                    content: TextField(
                      controller: ctl,
                      autofocus: true,
                      decoration: const InputDecoration(hintText: '예: 반려동물'),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d), child: const Text('취소')),
                      FilledButton(
                          onPressed: () => Navigator.pop(d, ctl.text.trim()),
                          child: const Text('추가')),
                    ],
                  ),
                );
                if (name == null || name.isEmpty) return;
                await s.addCategory(name);
                await s.repo.setCategory(t, name.replaceAll(',', ' '));
                await s.refresh();
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
          ]),
          if (t.note != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('메모: ${t.note}',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            ),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await showTxForm(context, s, t);
                },
                child: const Text('수정')),
            if (t.status == 'review')
              FilledButton.tonal(
                  onPressed: () async {
                    await s.repo.confirm(t.id);
                    await s.refresh();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('확인 완료')),
            OutlinedButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await showTagSheet(context, s, t);
                },
                child: const Text('태그')),
            if (t.type == 'expense' && t.amount > 0)
              OutlinedButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await showSplitSheet(context, s, t);
                  },
                  child: const Text('카테고리 나누기')),
            if (t.type != 'transfer')
              OutlinedButton(
                  onPressed: () async {
                    await s.repo.setType(t.id, 'transfer');
                    await s.refresh();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('내 계좌 간 이체로 표시')),
            OutlinedButton(
                onPressed: () async {
                  await s.repo.delete(t.id);
                  await s.refresh();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('삭제')),
          ]),
        ]),
      ),
    ),
  );
}

/// 거래 이름·금액·날짜·메모 수정.
Future<void> showTxForm(BuildContext context, AppState s, TxRow t) {
  final title = TextEditingController(text: t.title);
  final amt = TextEditingController(text: '${t.amount}');
  final note = TextEditingController(text: t.note ?? '');
  var at = t.occurredAt;
  String? err;
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: '내용')),
          const SizedBox(height: 12),
          TextField(
            controller: amt,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: '금액', suffixText: '원', errorText: err),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text('${at.year}.${at.month}.${at.day} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}')),
            TextButton(
              onPressed: () async {
                final d = await showDatePicker(
                    context: ctx,
                    initialDate: at,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now().add(const Duration(days: 365)));
                if (d != null) setS(() => at = DateTime(d.year, d.month, d.day, at.hour, at.minute));
              },
              child: const Text('날짜'),
            ),
            TextButton(
              onPressed: () async {
                final tm = await showTimePicker(
                    context: ctx, initialTime: TimeOfDay.fromDateTime(at));
                if (tm != null) setS(() => at = DateTime(at.year, at.month, at.day, tm.hour, tm.minute));
              },
              child: const Text('시간'),
            ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: note,
            maxLines: 2,
            decoration: const InputDecoration(labelText: '메모'),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () async {
                final a = int.tryParse(amt.text.replaceAll(',', ''));
                if (a == null || a < 0) {
                  setS(() => err = '금액을 확인하세요');
                  return;
                }
                await s.repo.updateTx(t.id,
                    title: title.text, amount: a, at: at, note: note.text);
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

Future<bool?> showManualEntry(BuildContext context, AppState s,
    {String? initialType, int? initialAmount, String? initialTitle}) {
  final amt = TextEditingController(text: initialAmount?.toString() ?? '');
  final title = TextEditingController(text: initialTitle ?? '');
  var type = initialType ?? 'expense';
  String? error;
  return showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'expense', label: Text('쓴 돈')),
              ButtonSegment(value: 'income', label: Text('받은 돈')),
            ],
            selected: {type},
            onSelectionChanged: (v) => setS(() => type = v.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amt,
            autofocus: true,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
                labelText: '금액', suffixText: '원', errorText: error),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: title,
            decoration: const InputDecoration(labelText: '내용 (예: 점심, 현금 용돈)'),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () async {
                final v = int.tryParse(amt.text.replaceAll(',', ''));
                if (v == null || v <= 0) {
                  setS(() => error = '금액을 입력하세요');
                  return;
                }
                await s.repo.addManual(
                    type: type,
                    amount: v,
                    title: title.text.trim().isEmpty ? '현금' : title.text.trim());
                await s.refresh();
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('저장'),
            ),
          ),
        ]),
      ),
    ),
  );
}

class ReviewScreen extends StatefulWidget {
  const ReviewScreen(this.s, {super.key});
  final AppState s;
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late Future<(List<TxRow>, List<Map<String, Object?>>)> _f;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _f = () async {
      final r = await widget.s.repo.reviewList();
      final f = await widget.s.repo.failedRaw();
      return (r, f);
    }();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('확인이 필요한 내역')),
        body: FutureBuilder(
          future: _f,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final (rows, failed) = snap.data!;
            if (rows.isEmpty && failed.isEmpty) {
              return const Center(child: Text('확인할 내역이 없어요 🎉'));
            }
            return ListView(padding: const EdgeInsets.all(16), children: [
              if (rows.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(children: [
                      for (final t in rows)
                        TxTile(t, onTap: () async {
                          await showEditSheet(context, widget.s, t);
                          setState(_load);
                        }),
                    ]),
                  ),
                ),
              if (failed.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 12, 8, 8),
                  child: Text('인식 못 한 알림',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Text('눌러서 내역으로 만들거나, X로 지울 수 있어요.',
                      style: TextStyle(fontSize: 12.5)),
                ),
                for (final r in failed)
                  Card(
                    child: ListTile(
                      title: Text((r['text'] as String).replaceAll('\n', ' '),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(r['package'] as String,
                          style: const TextStyle(fontSize: 11)),
                      trailing: IconButton(
                        tooltip: '무시',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () async {
                          await widget.s.repo.markRawHandled(r['id'] as int);
                          setState(_load);
                        },
                      ),
                      onTap: () async {
                        final g = guessFromText(joinNotification(
                            r['title'] as String?, r['text'] as String));
                        final saved = await showManualEntry(context, widget.s,
                            initialType: g.type,
                            initialAmount: g.amount,
                            initialTitle: g.title);
                        if (saved == true) {
                          await widget.s.repo.markRawHandled(r['id'] as int);
                          await widget.s.refresh();
                        }
                        setState(_load);
                      },
                    ),
                  ),
              ],
            ]);
          },
        ),
      );
}

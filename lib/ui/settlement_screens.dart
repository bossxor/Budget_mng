import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../data/repo.dart';
import '../data/settlement_repo.dart';
import 'screens.dart';
import 'theme.dart';

const _statusLabel = {'open': '받는 중', 'partial': '일부 입금', 'done': '정산 완료'};

Color _statusColor(BuildContext c, String s) {
  final cs = Theme.of(c).colorScheme;
  return switch (s) {
    'done' => cs.primary,
    'partial' => cs.tertiary,
    _ => cs.error,
  };
}

class SettlementListScreen extends StatefulWidget {
  const SettlementListScreen(this.s, {super.key});
  final AppState s;
  @override
  State<SettlementListScreen> createState() => _SettlementListScreenState();
}

class _SettlementListScreenState extends State<SettlementListScreen> {
  late Future<List<SettlementView>> _f;
  @override
  void initState() {
    super.initState();
    _f = widget.s.repo.settlements.all();
  }

  void _reload() => setState(() => _f = widget.s.repo.settlements.all());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('새 정산'),
        onPressed: () async {
          final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
              builder: (_) => CreateSettlementScreen(widget.s)));
          if (ok == true) {
            await widget.s.refresh();
            _reload();
          }
        },
      ),
      body: FutureBuilder(
        future: _f,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          final due = list.fold<int>(0, (a, x) => a + x.outstanding);
          if (list.isEmpty) {
            return const Center(
                child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('아직 정산이 없어요.\n오른쪽 아래 버튼으로 결제 내역을 골라 더치페이를 만들어 보세요.',
                  textAlign: TextAlign.center),
            ));
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF9F43), Color(0xFFFFC27A)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('아직 못 받은 돈',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.95))),
                const SizedBox(height: 4),
                Text('${fmt(due)}원',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800)),
              ]),
            ),
            for (final st in list)
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  leading: RoundIcon(
                      st.status == 'done' ? Icons.check_circle_rounded : Icons.groups_rounded,
                      st.status == 'done' ? Dsn.mint : Dsn.blue),
                  title: Text(st.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('결제 ${fmt(st.total)}원 · ${st.shares.length}명'),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(_statusLabel[st.status]!,
                        style: TextStyle(
                            color: _statusColor(context, st.status),
                            fontWeight: FontWeight.w600)),
                    if (st.outstanding > 0)
                      Text('남은 ${fmt(st.outstanding)}',
                          style: const TextStyle(fontSize: 12)),
                  ]),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => SettlementDetailScreen(widget.s, st.id)));
                    await widget.s.refresh();
                    _reload();
                  },
                ),
              ),
          ]);
        },
      ),
    );
  }
}

/// 1) 결제 선택 -> 2) 참여자/금액 -> 저장
class CreateSettlementScreen extends StatefulWidget {
  const CreateSettlementScreen(this.s, {super.key});
  final AppState s;
  @override
  State<CreateSettlementScreen> createState() => _CreateSettlementScreenState();
}

class _Part {
  _Part(this.name, int amt) : ctl = TextEditingController(text: '$amt');
  final String? name; // null = 나
  final TextEditingController ctl;
  int get amount => int.tryParse(ctl.text.replaceAll(',', '')) ?? 0;
}

class _CreateSettlementScreenState extends State<CreateSettlementScreen> {
  List<TxRow> _candidates = [];
  List<Person> _people = [];
  List<GroupPreset> _presets = [];
  final _picked = <String>{};
  final _title = TextEditingController();
  final _newName = TextEditingController();
  bool _step2 = false;
  bool _includeMe = true;
  final _selectedNames = <String>[];
  List<_Part> _parts = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = widget.s.repo.settlements;
    final c = await r.settleableExpenses();
    final p = await r.people();
    final pr = await r.presets();
    if (!mounted) return;
    setState(() {
      _candidates = c;
      _people = p;
      _presets = pr;
    });
  }

  int get _total => _candidates
      .where((t) => _picked.contains(t.id))
      .fold(0, (a, t) => a + t.amount);

  /// 합계를 인원수로 나누고, 남는 원 단위는 '나'(없으면 첫 사람)에게 붙인다.
  void _split() {
    final n = _selectedNames.length + (_includeMe ? 1 : 0);
    if (n == 0) return;
    final base = _total ~/ n;
    final rest = _total - base * n;
    final parts = <_Part>[];
    if (_includeMe) parts.add(_Part(null, base + rest));
    for (var i = 0; i < _selectedNames.length; i++) {
      parts.add(_Part(_selectedNames[i], base + (!_includeMe && i == 0 ? rest : 0)));
    }
    setState(() => _parts = parts);
  }

  void _addName(String raw) {
    final n = raw.trim();
    if (n.isEmpty || _selectedNames.contains(n)) return;
    setState(() => _selectedNames.add(n));
    _newName.clear();
    _split();
  }

  Future<void> _save() async {
    final sum = _parts.fold<int>(0, (a, p) => a + p.amount);
    if (_parts.where((p) => p.name != null).isEmpty) {
      setState(() => _error = '함께한 사람을 한 명 이상 선택하세요');
      return;
    }
    if (sum != _total) {
      setState(() => _error = '합계가 ${fmt(_total)}원이 되어야 해요 (지금 ${fmt(sum)}원)');
      return;
    }
    final first = _candidates.firstWhere((t) => _picked.contains(t.id));
    final title = _title.text.trim().isEmpty ? first.title : _title.text.trim();
    await widget.s.repo.settlements.create(
      title: title,
      txIds: _picked.toList(),
      shares: [for (final p in _parts) ShareInput(p.name, p.amount)],
    );
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_step2 ? '누구와 얼마씩?' : '정산할 결제 선택')),
      body: _step2 ? _buildStep2() : _buildStep1(),
    );
  }

  Widget _buildStep1() => Column(children: [
        Expanded(
          child: _candidates.isEmpty
              ? const Center(child: Text('최근 60일 안에 정산할 수 있는 지출이 없어요.'))
              : ListView(children: [
                  for (final t in _candidates)
                    CheckboxListTile(
                      value: _picked.contains(t.id),
                      onChanged: (v) => setState(
                          () => v == true ? _picked.add(t.id) : _picked.remove(t.id)),
                      title: Text(t.title),
                      subtitle: Text(
                          '${t.occurredAt.month}/${t.occurredAt.day} · ${t.category ?? '미분류'}'),
                      secondary: Text('${fmt(t.amount)}원',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                ]),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Expanded(
                  child: Text('${_picked.length}건 · 합계 ${fmt(_total)}원',
                      style: const TextStyle(fontSize: 16))),
              FilledButton(
                onPressed: _picked.isEmpty
                    ? null
                    : () {
                        setState(() => _step2 = true);
                        _split();
                      },
                child: const Text('다음'),
              ),
            ]),
          ),
        ),
      ]);

  Widget _buildStep2() => ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: '정산 이름 (예: 1·2차 회식)'),
        ),
        const SizedBox(height: 12),
        Text('결제 합계 ${fmt(_total)}원', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('나도 포함 (내 몫은 지출로 반영)'),
          value: _includeMe,
          onChanged: (v) {
            _includeMe = v;
            _split();
          },
        ),
        if (_presets.isNotEmpty) ...[
          const Text('자주 만나는 모임'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final g in _presets)
              InputChip(
                avatar: const Icon(Icons.groups_rounded, size: 18),
                label: Text('${g.name} ${g.members.length}명'),
                onPressed: () {
                  setState(() {
                    _selectedNames
                      ..clear()
                      ..addAll(g.members);
                  });
                  _split();
                },
                onDeleted: () async {
                  await widget.s.repo.settlements.deletePreset(g.id);
                  await _load();
                },
              ),
          ]),
          const SizedBox(height: 12),
        ],
        const Text('함께한 사람'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final p in _people)
            FilterChip(
              label: Text(p.name),
              selected: _selectedNames.contains(p.name),
              onSelected: (v) {
                setState(() => v ? _selectedNames.add(p.name) : _selectedNames.remove(p.name));
                _split();
              },
            ),
          for (final n in _selectedNames.where((n) => !_people.any((p) => p.name == n)))
            InputChip(
              label: Text(n),
              onDeleted: () {
                setState(() => _selectedNames.remove(n));
                _split();
              },
            ),
        ]),
        if (_selectedNames.length >= 2)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final ctl = TextEditingController();
                final name = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('모임으로 저장'),
                    content: TextField(
                      controller: ctl,
                      autofocus: true,
                      decoration: const InputDecoration(hintText: '예: 동창 모임'),
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('취소')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
                          child: const Text('저장')),
                    ],
                  ),
                );
                if (name != null && name.isNotEmpty) {
                  await widget.s.repo.settlements
                      .savePreset(name, List.of(_selectedNames));
                  await _load();
                }
              },
              icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: const Text('이 멤버를 모임으로 저장'),
            ),
          ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _newName,
              decoration: const InputDecoration(labelText: '새 이름 추가'),
              onSubmitted: _addName,
            ),
          ),
          IconButton(onPressed: () => _addName(_newName.text), icon: const Icon(Icons.add)),
        ]),
        const Divider(height: 32),
        Row(children: [
          Text('금액', style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          TextButton(onPressed: _split, child: const Text('N등분으로 되돌리기')),
        ]),
        for (final p in _parts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(child: Text(p.name ?? '나')),
              SizedBox(
                width: 140,
                child: TextField(
                  controller: p.ctl,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.end,
                  decoration: const InputDecoration(suffixText: '원'),
                  onChanged: (_) => setState(() => _error = null),
                ),
              ),
            ]),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 16),
        Row(children: [
          OutlinedButton(
              onPressed: () => setState(() => _step2 = false), child: const Text('이전')),
          const SizedBox(width: 12),
          Expanded(child: FilledButton(onPressed: _save, child: const Text('정산 저장'))),
        ]),
      ]);
}

class SettlementDetailScreen extends StatefulWidget {
  const SettlementDetailScreen(this.s, this.id, {super.key});
  final AppState s;
  final String id;
  @override
  State<SettlementDetailScreen> createState() => _SettlementDetailScreenState();
}

class _SettlementDetailScreenState extends State<SettlementDetailScreen> {
  late Future<SettlementView?> _f;
  @override
  void initState() {
    super.initState();
    _f = widget.s.repo.settlements.get(widget.id);
  }

  void _reload() =>
      setState(() => _f = widget.s.repo.settlements.get(widget.id));

  Future<void> _share(SettlementView st, ShareView sh) async {
    final text = buildRequestText(widget.s.requestTemplate,
        name: sh.name,
        title: st.title,
        amount: sh.remaining,
        account: widget.s.payAccount);
    await SharePlus.instance.share(ShareParams(text: text));
  }

  Future<void> _link(SettlementView st, ShareView sh) async {
    final cands = await widget.s.repo.settlements.candidates(sh.name);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx, ctl) => Column(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('${sh.name}님 입금 연결 (남은 ${fmt(sh.remaining)}원)',
                style: Theme.of(ctx).textTheme.titleMedium),
          ),
          Expanded(
            child: cands.isEmpty
                ? const Center(child: Text('연결할 수 있는 입금 내역이 없어요.'))
                : ListView(controller: ctl, children: [
                    for (final c in cands)
                      ListTile(
                        title: Row(children: [
                          Flexible(child: Text(c.tx.title)),
                          if (c.nameMatch)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                  color: Theme.of(ctx).colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(6)),
                              child: const Text('이름 일치', style: TextStyle(fontSize: 11)),
                            ),
                        ]),
                        subtitle: Text(
                            '${c.tx.occurredAt.month}/${c.tx.occurredAt.day} · 남은 입금 ${fmt(c.free)}원'),
                        trailing: Text('+${fmt(c.tx.amount)}',
                            style: TextStyle(
                                color: Theme.of(ctx).colorScheme.primary,
                                fontWeight: FontWeight.w600)),
                        onTap: () async {
                          final amt = c.free < sh.remaining ? c.free : sh.remaining;
                          await widget.s.repo.settlements.pay(sh, c, amt);
                          if (ctx.mounted) Navigator.pop(ctx);
                          _reload();
                        },
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _f,
      builder: (context, snap) {
        final st = snap.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(st?.title ?? '정산'),
            actions: [
              if (st != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('정산을 삭제할까요?'),
                        content: const Text('연결된 입금은 다시 일반 입금으로 돌아가요.'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('취소')),
                          FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('삭제')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await widget.s.repo.settlements.delete(st.id);
                      if (context.mounted) Navigator.pop(context);
                    }
                  },
                ),
            ],
          ),
          body: st == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_statusLabel[st.status]!,
                            style: TextStyle(
                                color: _statusColor(context, st.status),
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text('결제 합계 ${fmt(st.total)}원'),
                        Text('내 몫 ${fmt(st.myShare)}원 (지출로 반영)'),
                        Text('받을 돈 ${fmt(st.toReceive)}원 · 받음 ${fmt(st.received)}원'),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: st.toReceive == 0 ? 1 : st.received / st.toReceive,
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ]),
                    ),
                  ),
                  Text('결제 내역', style: Theme.of(context).textTheme.titleSmall),
                  for (final t in st.items)
                    ListTile(
                      dense: true,
                      title: Text(t.title),
                      subtitle: Text('${t.occurredAt.month}/${t.occurredAt.day}'),
                      trailing: Text('${fmt(t.amount)}원'),
                    ),
                  const Divider(height: 24),
                  Text('사람별', style: Theme.of(context).textTheme.titleSmall),
                  for (final sh in st.shares)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            InitialAvatar(sh.name, size: 36),
                            const SizedBox(width: 10),
                            Text(sh.name,
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w600)),
                            const Spacer(),
                            Text('${fmt(sh.amount)}원'),
                          ]),
                          if (!sh.isMe) ...[
                            const SizedBox(height: 6),
                            Text(
                                sh.remaining <= 0
                                    ? '입금 완료'
                                    : '받음 ${fmt(sh.received)}원 · 남음 ${fmt(sh.remaining)}원',
                                style: TextStyle(
                                    color: sh.remaining <= 0
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context).colorScheme.error)),
                            FutureBuilder(
                              future: widget.s.repo.settlements.paymentsOf(sh.id),
                              builder: (c, ps) => Column(children: [
                                for (final p in ps.data ?? const <Map<String, Object?>>[])
                                  Row(children: [
                                    Expanded(
                                        child: Text(
                                            '· ${(p['counterparty'] ?? p['merchant'] ?? '') as String} +${fmt(p['amount'] as int)}',
                                            style: const TextStyle(fontSize: 12))),
                                    TextButton(
                                        onPressed: () async {
                                          await widget.s.repo.settlements
                                              .unpay(p['id'] as String);
                                          _reload();
                                        },
                                        child: const Text('연결 해제')),
                                  ]),
                              ]),
                            ),
                            if (sh.remaining > 0)
                              Wrap(spacing: 8, children: [
                                OutlinedButton(
                                    onPressed: () => _link(st, sh),
                                    child: const Text('입금 연결')),
                                OutlinedButton(
                                    onPressed: () => _share(st, sh),
                                    child: const Text('요청 문구 보내기')),
                              ]),
                          ],
                        ]),
                      ),
                    ),
                ]),
        );
      },
    );
  }
}

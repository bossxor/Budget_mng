import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../data/backup.dart';
import '../data/report.dart';
import '../data/repo.dart';
import 'screens.dart';
import 'theme.dart';

// ---------------------------------------------------------------- 월말 결산

class ReportScreen extends StatefulWidget {
  const ReportScreen(this.s, {super.key});
  final AppState s;
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late DateTime _month = widget.s.month;
  late Future<MonthReport> _f = buildReport(widget.s.repo, _month);

  void _shift(int d) => setState(() {
        _month = DateTime(_month.year, _month.month + d);
        _f = buildReport(widget.s.repo, _month);
      });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('월말 결산')),
      body: FutureBuilder(
        future: _f,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final r = snap.data!;
          final maxC = r.categories.isEmpty ? 1 : r.categories.first.amount;
          final up = r.expenseDelta > 0;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                  onPressed: () => _shift(-1),
                  icon: const Icon(Icons.chevron_left_rounded)),
              Text('${_month.year}년 ${_month.month}월',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              IconButton(
                  onPressed: () => _shift(1),
                  icon: const Icon(Icons.chevron_right_rounded)),
            ]),
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                gradient: const LinearGradient(
                  colors: [Dsn.blueDeep, Dsn.blue],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_month.month}월에 쓴 돈',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.9))),
                Text('${fmt(r.expense)}원',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(
                  r.prevExpense == 0
                      ? '지난달 기록이 없어요'
                      : '지난달보다 ${fmt(r.expenseDelta)}원 ${up ? '더 썼어요' : '덜 썼어요'}',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.95)),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                      child: Text('들어온 돈 +${fmt(r.income)}원',
                          style: const TextStyle(color: Colors.white))),
                  Text('남은 돈 ${r.net < 0 ? '−' : ''}${fmt(r.net)}원',
                      style: const TextStyle(color: Colors.white)),
                ]),
              ]),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('카테고리',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (r.categories.isEmpty) const Text('이 달 지출이 없어요.'),
                  for (final c in r.categories)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(children: [
                        Row(children: [
                          Text(c.category,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          const Spacer(),
                          if (c.previous > 0)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Text(
                                  '${c.delta >= 0 ? '▲' : '▼'} ${fmt(c.delta)}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: c.delta > 0 ? Dsn.coral : Dsn.mint)),
                            ),
                          Text('${fmt(c.amount)}원',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: c.amount / maxC,
                            minHeight: 8,
                            color: Dsn.cat(c.category == '미분류' ? null : c.category),
                            backgroundColor:
                                Dsn.cat(c.category == '미분류' ? null : c.category)
                                    .withValues(alpha: 0.14),
                          ),
                        ),
                      ]),
                    ),
                ]),
              ),
            ),
            if (r.topMerchants.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('많이 쓴 곳 Top 5',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    for (var i = 0; i < r.topMerchants.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          CircleAvatar(
                              radius: 13,
                              backgroundColor: cs.primaryContainer,
                              child: Text('${i + 1}',
                                  style: const TextStyle(fontSize: 12))),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Text(
                                  '${r.topMerchants[i].name}'
                                  '${r.topMerchants[i].count > 1 ? ' · ${r.topMerchants[i].count}번' : ''}',
                                  overflow: TextOverflow.ellipsis)),
                          Text('${fmt(r.topMerchants[i].amount)}원',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        ]),
                      ),
                  ]),
                ),
              ),
            if (r.biggestDay != null)
              Card(
                child: ListTile(
                  leading: const RoundIcon(Icons.local_fire_department_rounded, Dsn.coral),
                  title: const Text('가장 많이 쓴 날'),
                  subtitle: Text(dayLabel(r.biggestDay!)),
                  trailing: Text('${fmt(r.biggestDayAmount)}원',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- 검색/태그

class SearchScreen extends StatefulWidget {
  const SearchScreen(this.s, {super.key});
  final AppState s;
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _q = TextEditingController();
  final _min = TextEditingController();
  final _max = TextEditingController();
  String? _tag;
  String? _type;
  Map<String, int> _tags = {};
  List<TxRow> _rows = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    widget.s.repo.tags.allTags().then((t) {
      if (mounted) setState(() => _tags = t);
    });
    _run();
  }

  Future<void> _run() async {
    final r = await widget.s.repo.tags.search(
      text: _q.text,
      tag: _tag,
      type: _type,
      minAmount: int.tryParse(_min.text.replaceAll(',', '')),
      maxAmount: int.tryParse(_max.text.replaceAll(',', '')),
    );
    if (mounted) {
      setState(() {
        _rows = r;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sum = _rows
        .where((t) => t.type == 'expense')
        .fold<int>(0, (a, t) => a + t.amount);
    return Scaffold(
      appBar: AppBar(title: const Text('검색')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(children: [
            TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                  hintText: '가맹점, 메모, 태그로 찾기',
                  prefixIcon: Icon(Icons.search_rounded)),
              onChanged: (_) => _run(),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _min,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: '최소 금액'),
                  onChanged: (_) => _run(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _max,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: '최대 금액'),
                  onChanged: (_) => _run(),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final e in const {'전체': null, '지출': 'expense', '입금': 'income', '이체': 'transfer'}.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(e.key),
                      selected: _type == e.value,
                      onSelected: (_) {
                        _type = e.value;
                        _run();
                      },
                    ),
                  ),
                for (final t in _tags.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text('#${t.key} ${t.value}'),
                      selected: _tag == t.key,
                      onSelected: (v) {
                        _tag = v ? t.key : null;
                        _run();
                      },
                    ),
                  ),
              ]),
            ),
          ]),
        ),
        if (_loaded)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Row(children: [
              Text('${_rows.length}건',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              if (sum > 0) Text('지출 합계 ${fmt(sum)}원'),
            ]),
          ),
        Expanded(
          child: _rows.isEmpty
              ? Center(child: Text(_loaded ? '조건에 맞는 내역이 없어요' : ''))
              : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                  Card(
                    child: Column(children: [
                      for (final t in _rows)
                        TxTile(t, onTap: () async {
                          await showEditSheet(context, widget.s, t);
                          await _run();
                        }),
                    ]),
                  ),
                ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- 태그/분할 시트

Future<void> showTagSheet(BuildContext context, AppState s, TxRow t) async {
  final current = await s.repo.tags.tagsOf(t.id);
  final all = await s.repo.tags.allTags();
  if (!context.mounted) return;
  final ctl = TextEditingController(text: current.join(', '));
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('태그', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('쉼표로 여러 개 입력해요. 예: 제주여행, 맛집'),
        const SizedBox(height: 12),
        TextField(controller: ctl, autofocus: true),
        if (all.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (final e in all.keys)
              ActionChip(
                label: Text('#$e'),
                onPressed: () {
                  final list = ctl.text
                      .split(RegExp(r'[,\s]+'))
                      .where((x) => x.isNotEmpty)
                      .toList();
                  if (!list.contains(e)) list.add(e);
                  ctl.text = list.join(', ');
                },
              ),
          ]),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () async {
              await s.repo.tags.setTags(t.id,
                  ctl.text.split(RegExp(r'[,\s]+')).where((x) => x.isNotEmpty).toList());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('저장'),
          ),
        ),
      ]),
    ),
  );
}

Future<void> showSplitSheet(BuildContext context, AppState s, TxRow t) async {
  final existing = await s.repo.splitsOf(t.id);
  if (!context.mounted) return;
  final rows = <({String category, TextEditingController amt})>[
    for (final p in existing)
      (category: p.category, amt: TextEditingController(text: '${p.amount}')),
    if (existing.isEmpty) ...[
      (category: t.category ?? '기타', amt: TextEditingController(text: '${t.amount}')),
      (category: '생활', amt: TextEditingController(text: '0')),
    ],
  ];
  var cats = [for (final r in rows) r.category];
  String? err;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        final sum = rows.fold<int>(0, (a, r) => a + (int.tryParse(r.amt.text) ?? 0));
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${t.title} ${fmt(t.amount)}원 나누기',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            for (var i = 0; i < rows.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: categories.contains(cats[i]) ? cats[i] : null,
                      hint: Text(cats[i]),
                      items: [
                        for (final c in categories)
                          DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: (v) => setS(() => cats[i] = v ?? cats[i]),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 130,
                    child: TextField(
                      controller: rows[i].amt,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.end,
                      decoration: const InputDecoration(suffixText: '원'),
                      onChanged: (_) => setS(() => err = null),
                    ),
                  ),
                ]),
              ),
            Row(children: [
              TextButton.icon(
                onPressed: () => setS(() {
                  rows.add((category: '기타', amt: TextEditingController(text: '0')));
                  cats = [...cats, '기타'];
                }),
                icon: const Icon(Icons.add_rounded),
                label: const Text('항목 추가'),
              ),
              const Spacer(),
              Text(
                  sum == t.amount
                      ? '합계 맞음'
                      : '남은 금액 ${fmt(t.amount - sum)}원',
                  style: TextStyle(
                      color: sum == t.amount ? Dsn.mint : Dsn.coral,
                      fontWeight: FontWeight.w600)),
            ]),
            if (err != null) Text(err!, style: const TextStyle(color: Dsn.coral)),
            const SizedBox(height: 12),
            Row(children: [
              if (existing.isNotEmpty)
                OutlinedButton(
                  onPressed: () async {
                    await s.repo.saveSplits(t.id, []);
                    await s.refresh();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('나누기 해제'),
                ),
              const Spacer(),
              FilledButton(
                onPressed: () async {
                  final parts = <TxSplit>[];
                  for (var i = 0; i < rows.length; i++) {
                    final a = int.tryParse(rows[i].amt.text) ?? 0;
                    if (a > 0) parts.add(TxSplit(cats[i], a));
                  }
                  if (parts.fold<int>(0, (a, p) => a + p.amount) != t.amount) {
                    setS(() => err = '합계가 ${fmt(t.amount)}원이 되어야 해요');
                    return;
                  }
                  await s.repo.saveSplits(t.id, parts.length > 1 ? parts : []);
                  await s.refresh();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('저장'),
              ),
            ]),
          ]),
        );
      },
    ),
  );
}

// ---------------------------------------------------------------- 백업/복원

Future<String?> _askPassphrase(BuildContext context, {required bool confirm}) {
  final a = TextEditingController();
  final b = TextEditingController();
  String? err;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(confirm ? '백업 암호 정하기' : '백업 암호 입력'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (confirm)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('암호를 잊으면 복원할 수 없어요. 꼭 기억해 두세요.',
                  style: TextStyle(fontSize: 13)),
            ),
          TextField(
            controller: a,
            obscureText: true,
            decoration: const InputDecoration(labelText: '암호 (6자 이상)'),
          ),
          if (confirm) ...[
            const SizedBox(height: 8),
            TextField(
              controller: b,
              obscureText: true,
              decoration: InputDecoration(labelText: '한 번 더', errorText: err),
            ),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(
            onPressed: () {
              if (a.text.length < 6) {
                setS(() => err = '6자 이상 입력하세요');
              } else if (confirm && a.text != b.text) {
                setS(() => err = '두 암호가 달라요');
              } else {
                Navigator.pop(ctx, a.text);
              }
            },
            child: const Text('확인'),
          ),
        ],
      ),
    ),
  );
}

void _busy(BuildContext context, String msg) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: Row(children: [
        const CircularProgressIndicator(),
        const SizedBox(width: 20),
        Expanded(child: Text(msg)),
      ]),
    ),
  );
}

Future<void> exportBackup(BuildContext context, AppState s) async {
  final pass = await _askPassphrase(context, confirm: true);
  if (pass == null || !context.mounted) return;
  _busy(context, '암호화하는 중이에요');
  try {
    final bytes = await encryptBackup(await exportData(s.repo.db), pass);
    final d = DateTime.now();
    final name =
        'jumeoni_${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}.jmbak';
    final f = File('${Directory.systemTemp.path}/$name');
    await f.writeAsBytes(bytes);
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await SharePlus.instance
        .share(ShareParams(files: [XFile(f.path)], subject: '주머니 백업'));
    await s.markBackupDone();
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('백업에 실패했어요: $e')));
    }
  }
}

Future<void> importBackup(BuildContext context, AppState s) async {
  final picked = await FilePicker.pickFiles();
  if (picked.isEmpty || !context.mounted) return;
  final bytes = await picked.first.readAsBytes();
  if (!context.mounted) return;
  final pass = await _askPassphrase(context, confirm: false);
  if (pass == null || !context.mounted) return;
  _busy(context, '복원하는 중이에요');
  try {
    final data = await decryptBackup(bytes, pass);
    final added = await importData(s.repo.db, data);
    await s.refresh();
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('복원했어요. 새 내역 $added건')));
    }
  } on BackupError catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('복원에 실패했어요: $e')));
    }
  }
}

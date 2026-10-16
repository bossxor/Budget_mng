import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/repo.dart';
import '../core/notification_policy.dart';
import 'theme.dart';
import 'auto_posting_screen.dart';

class NotificationReviewScreen extends StatefulWidget {
  const NotificationReviewScreen(this.s, this.review, {super.key});
  final AppState s;
  final NotificationReview review;
  @override
  State<NotificationReviewScreen> createState() =>
      _NotificationReviewScreenState();
}

class _NotificationReviewScreenState extends State<NotificationReviewScreen> {
  final amount = TextEditingController(),
      party = TextEditingController(),
      note = TextEditingController();
  String stage = 'review', type = 'income', scope = 'title';
  String? category, reason, destination, duplicate, error, evidence, appLabel;
  bool busy = true;
  AutoPostingProgress? autoProgress;
  bool enableAutoAfter = false;
  List<TxRow> duplicates = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = widget.review;
      try {
        final apps = await widget.s.installedApps();
        final matches = apps.where((a) => a.package == r.package);
        if (matches.isNotEmpty) appLabel = matches.first.name;
      } catch (_) {}
      final proposal = await widget.s.repo.proposeNotificationClassification(r);
      final assessment = await widget.s.repo.assessNotification(r);
      duplicates = await widget.s.repo.notificationDuplicates(r);
      amount.text = '${r.tx.amount}';
      party.text = r.tx.title;
      type = proposal?.label.type ?? r.tx.type;
      category = proposal?.label.category ?? r.tx.category;
      destination = r.tx.destination ?? await widget.s.repo.autoDestination(r);
      autoProgress = await widget.s.repo.observeAutoProposal(
        r,
        type: type,
        category: category,
        destination: destination,
      );
      evidence = assessment?.isTransaction == false
          ? '${assessment!.evidence} 이전에는 거래가 아니라고 알려주셨어요.'
          : proposal?.evidence ?? assessment?.evidence;
      if (mounted) setState(() => busy = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '알림을 불러오지 못했어요. 다시 열어 주세요.';
        });
      }
    }
  }

  @override
  void dispose() {
    amount.dispose();
    party.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> save({bool reject = false}) async {
    var committed = false;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final repo = widget.s.repo, r = widget.review;
      if (reject) {
        if (reason == null) throw ArgumentError('이유를 골라 주세요.');
        await repo.rejectNotification(
          r,
          reason: reason!,
          muteScope: reason == 'chat' && !r.protectedSource ? scope : 'none',
          note: note.text,
          duplicateId: duplicate,
        );
      } else {
        final value = int.tryParse(amount.text.replaceAll(',', ''));
        if (value == null) throw ArgumentError('금액을 확인해 주세요.');
        await repo.confirmNotification(
          r,
          amount: value,
          type: type,
          party: party.text,
          category: category,
          destination: type == 'transfer' ? destination : null,
          reason: reason == 'own_transfer' ? reason : null,
          enableAutoPatternKey: enableAutoAfter ? autoProgress?.key : null,
        );
      }
      committed = true;
      await widget.s.refresh();
      if (!mounted) return;
      if (!reject && autoProgress != null && !enableAutoAfter) {
        final progress = await repo.autoProgress(autoProgress!.key);
        if (progress.ready &&
            !progress.enabled &&
            !progress.paused &&
            await repo.getKv('auto_offer_seen_${progress.key}') == null) {
          await repo.setKv('auto_offer_seen_${progress.key}', '1');
          if (!mounted) return;
          final allow = await askAutoPosting(
            context,
            progress,
            sourceName: appLabel ?? _source(widget.review.package),
            accountLabels: autoAccountLabels(widget.s),
          );
          if (allow) {
            await repo.setAutoPosting(progress.key, true);
            enableAutoAfter = true;
          }
        }
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context), s = widget.s;
      Navigator.pop(context, true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            reject
                ? '이유를 반영했어요. 다음 판독에 참고할게요.'
                : enableAutoAfter
                ? '반영했어요. 다음 같은 패턴은 자동으로 기록해요.'
                : '반영하고 학습했어요.',
          ),
          action: SnackBarAction(
            label: '되돌리기',
            onPressed: () async {
              try {
                if (reject) {
                  final f = (await s.repo.hiddenNotificationFeedback()).where(
                    (f) => f['tx_id'] == r.tx.id,
                  );
                  if (f.isNotEmpty) {
                    await s.repo.restoreNotification(
                      f.first['notification_key'] as String,
                    );
                  }
                } else {
                  await s.repo.undoClassification(r.tx.id);
                }
                await s.refresh();
              } catch (_) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('최신 내역에서 다시 확인해 주세요.')),
                );
              }
            },
          ),
        ),
      );
    } catch (e) {
      if (committed && mounted) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context, true);
        messenger.showSnackBar(
          const SnackBar(
            content: Text('답변은 반영됐어요. 자동 반영 설정과 최신 내역은 설정에서 확인해 주세요.'),
          ),
        );
        return;
      }
      enableAutoAfter = false;
      if (mounted) {
        setState(() {
          busy = false;
          error = e is StateError
              ? e.message.toString()
              : e is ArgumentError
              ? e.message.toString()
              : '저장하지 못했어요. 다시 시도해 주세요.';
        });
      }
    }
  }

  Future<void> enablePattern() async {
    if (autoProgress == null) return;
    if (category == null) {
      setState(() {
        stage = 'correct';
        error = '자동 반영할 분류를 먼저 선택해 주세요.';
      });
      return;
    }
    final display = AutoPostingProgress(
      {
        ...autoProgress!.pattern,
        'category': category,
        'type': type,
        'destination': destination,
      },
      autoProgress!.checked,
      autoProgress!.correct,
      autoProgress!.streak,
    );
    if (!await askAutoPosting(
          context,
          display,
          sourceName: appLabel ?? _source(widget.review.package),
          accountLabels: autoAccountLabels(widget.s),
        ) ||
        !mounted) {
      return;
    }
    enableAutoAfter = true;
    await save();
  }

  Widget select(
    String label,
    String? value,
    List<String> values,
    ValueChanged<String?> changed,
  ) => DropdownButtonFormField<String>(
    initialValue: values.contains(value) ? value : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [for (final v in values) DropdownMenuItem(value: v, child: Text(v))],
    onChanged: busy ? null : changed,
  );
  @override
  Widget build(BuildContext context) {
    final r = widget.review, cs = Theme.of(context).colorScheme;
    final categories = type == 'transfer'
        ? transferPurposes
        : type == 'income'
        ? ['월급', '용돈', '기타수입']
        : allCategories;
    return Scaffold(
      appBar: AppBar(title: const Text('알림 도우미')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(22),
                children: [
                  Text(
                    stage == 'reason'
                        ? '이유를 알려주세요'
                        : stage == 'correct'
                        ? '맞는 내용으로 알려주세요'
                        : '먼저 읽어봤어요',
                    style: const TextStyle(color: Dsn.blue),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    stage == 'reason'
                        ? '어떤 알림이었나요?'
                        : stage == 'correct'
                        ? '어떻게 기록할까요?'
                        : type == 'transfer'
                        ? '${category ?? '내 계좌 이체'}로 옮긴 돈인가요?'
                        : '실제 ${type == 'income' ? '입금' : '지출'}이 맞나요?',
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (stage == 'review') ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${appLabel ?? _source(r.package)} · ${r.title}',
                              style: TextStyle(color: cs.onSurfaceVariant),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              '${amount.text}원',
                              style: const TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text('${_kind(type)} · ${category ?? '미분류'}'),
                            const Divider(height: 30),
                            const Text('받은 알림 원문'),
                            const SizedBox(height: 8),
                            SelectableText(
                              r.original ?? '원문 보관 기간이 지났거나 백업에서 복원한 내역이에요. 출처와 판독 내용을 확인해 주세요.',
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (evidence != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          evidence!,
                          style: const TextStyle(color: Dsn.mint),
                        ),
                      ),
                    const Text('확인 전 후보는 합계와 예산에 넣지 않아요.'),
                  ],
                  if (stage == 'correct') ...[
                    TextField(
                      controller: amount,
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                      ),
                      decoration: const InputDecoration(labelText: '금액'),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: type,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '거래 종류'),
                      items: [
                        for (final k in [
                          'income',
                          'expense',
                          'transfer',
                          'group',
                        ])
                          DropdownMenuItem(value: k, child: Text(_kind(k))),
                      ],
                      onChanged: (v) => setState(() {
                        type = v!;
                        category = null;
                      }),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: party,
                      decoration: const InputDecoration(labelText: '상대 이름'),
                    ),
                    const SizedBox(height: 16),
                    select(
                      '분류·목적',
                      category,
                      {?category, ...categories}.toList(),
                      (v) => setState(() => category = v),
                    ),
                    if (type == 'transfer') ...[
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue:
                            widget.s.accounts.any(
                              (a) =>
                                  a.key == destination && a.key != r.tx.account,
                            )
                            ? destination
                            : null,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '받는 내 통장 (선택)',
                        ),
                        items: [
                          for (final a in widget.s.accounts.where(
                            (a) => a.key != r.tx.account,
                          ))
                            DropdownMenuItem(
                              value: a.key,
                              child: Text(a.label),
                            ),
                        ],
                        onChanged: (v) => setState(() => destination = v),
                      ),
                    ],
                  ],
                  if (stage == 'reason') ...[
                    for (final entry in notificationReasons.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: OutlinedButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  reason = entry.key;
                                  if (reason == 'own_transfer') {
                                    type = 'transfer';
                                    category = '내 계좌 이체';
                                    stage = 'correct';
                                  }
                                }),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.all(16),
                            backgroundColor: reason == entry.key
                                ? cs.primaryContainer
                                : null,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(entry.value),
                          ),
                        ),
                      ),
                    if (reason == 'chat') ...[
                      if (r.protectedSource)
                        const Text('등록한 금융 앱은 숨기지 않아요. 이번 알림만 제외해요.')
                      else
                        DropdownButtonFormField<String>(
                          initialValue: scope,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '다음부터 어떻게 할까요?',
                          ),
                          items: [
                            if (r.title.isNotEmpty)
                              const DropdownMenuItem(
                                value: 'title',
                                child: Text('이 대화방은 묻지 않기'),
                              ),
                            const DropdownMenuItem(
                              value: 'none',
                              child: Text('이번 알림만 제외하기'),
                            ),
                            const DropdownMenuItem(
                              value: 'app',
                              child: Text('이 앱 전체는 묻지 않기'),
                            ),
                          ],
                          onChanged: (v) => setState(() => scope = v!),
                        ),
                    ],
                    if (reason == 'duplicate')
                      DropdownButtonFormField<String>(
                        initialValue: duplicate,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '같은 거래 선택',
                        ),
                        items: [
                          for (final d in duplicates)
                            DropdownMenuItem(
                              value: d.id,
                              child: Text(
                                '${d.occurredAt.month}/${d.occurredAt.day} · ${d.title} · ${d.amount}원',
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => duplicate = v),
                      ),
                    if (reason == 'other')
                      TextField(
                        controller: note,
                        decoration: const InputDecoration(
                          labelText: '어떤 점이 달랐나요?',
                        ),
                      ),
                    if (reason == 'ad' || reason == 'otp')
                      const Text('이 앱의 비슷한 알림을 판독할 때 오답 사례로 참고해요.'),
                  ],
                  if (autoProgress != null && stage != 'reason')
                    AutoProgressCard(
                      autoProgress!,
                      onEnable: busy ? null : enablePattern,
                      onPause: busy
                          ? null
                          : () async {
                              await widget.s.repo.setAutoPosting(
                                autoProgress!.key,
                                false,
                              );
                              final updated = await widget.s.repo.autoProgress(
                                autoProgress!.key,
                              );
                              if (mounted) {
                                setState(() => autoProgress = updated);
                              }
                            },
                    ),
                  if (busy) const Center(child: CircularProgressIndicator()),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error!, style: TextStyle(color: cs.error)),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: busy || (stage == 'reason' && reason == null)
                        ? null
                        : () => save(reject: stage == 'reason'),
                    child: Text(
                      stage == 'reason'
                          ? '이유를 반영하고 학습'
                          : stage == 'correct'
                          ? '이 내용으로 반영하고 학습'
                          : '맞아요, 거래예요',
                    ),
                  ),
                  if (stage == 'review')
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() => stage = 'correct'),
                            child: const Text('고쳐서 맞아요'),
                          ),
                        ),
                        Expanded(
                          child: TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                    stage = 'reason';
                                    scope = r.title.isEmpty ? 'none' : 'title';
                                  }),
                            child: const Text('아니에요'),
                          ),
                        ),
                      ],
                    )
                  else
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() => stage = 'review'),
                      child: const Text('다시 확인할게요'),
                    ),
                  const Text(
                    '휴대폰 안에서 학습 · 답변은 되돌릴 수 있어요',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _kind(String type) => type == 'income'
    ? '수입'
    : type == 'transfer'
    ? '내 계좌 이체'
    : '지출';
String _source(String package) =>
    {
      'com.kakaobank.channel': '카카오뱅크',
      'com.nonghyup.nhallonebank': 'NH올원뱅크',
      'viva.republica.toss': '토스',
      'com.kakao.talk': '카카오톡',
      'com.samsung.android.messaging': '문자',
      'com.google.android.apps.messaging': '문자',
    }[package] ??
    package;

class HiddenNotificationsScreen extends StatefulWidget {
  const HiddenNotificationsScreen(this.s, {super.key});
  final AppState s;
  @override
  State<HiddenNotificationsScreen> createState() =>
      _HiddenNotificationsScreenState();
}

class _HiddenNotificationsScreenState extends State<HiddenNotificationsScreen> {
  late Future<(List<Map<String, Object?>>, List<Map<String, Object?>>)> data;
  @override
  void initState() {
    super.initState();
    reload();
  }

  void reload() {
    data = (() async => (
      await widget.s.repo.hiddenNotificationFeedback(),
      await widget.s.repo.notificationMuteRules(),
    ))();
  }

  Future<void> act(Future<void> Function() fn) async {
    try {
      await fn();
      await widget.s.refresh();
      if (mounted) setState(reload);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('처리하지 못했어요. 다시 시도해 주세요.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('숨긴 알림')),
    body: FutureBuilder(
      future: data,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (feedback, rules) = snap.data!;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('대화 숨김 규칙'),
            for (final r in rules)
              Card(
                child: ListTile(
                  title: Text(
                    '${_source(r['package'] as String)} · ${r['title'] == '' ? '앱 전체' : r['title']}',
                  ),
                  subtitle: Text('제외 ${r['blocked_count'] ?? 0}건'),
                  trailing: TextButton(
                    onPressed: () => act(
                      () => widget.s.repo.removeNotificationMute(
                        r['package'] as String,
                        r['title'] as String,
                      ),
                    ),
                    child: const Text('해제'),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            const Text('아니에요로 답한 알림'),
            for (final f in feedback)
              Card(
                child: ListTile(
                  title: Text(
                    '${_source(f['package'] as String)} · ${f['title'] ?? ''}',
                  ),
                  subtitle: Text(
                    '${notificationReasons[f['reason']] ?? f['reason']}\n${f['snippet'] ?? '학습 조각 보관 기간이 지난 알림'}',
                  ),
                  trailing: TextButton(
                    onPressed: () => act(
                      () => widget.s.repo.restoreNotification(
                        f['notification_key'] as String,
                      ),
                    ),
                    child: const Text('되돌리기'),
                  ),
                ),
              ),
            if (rules.isEmpty && feedback.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('숨긴 알림이 없어요.'),
              ),
          ],
        );
      },
    ),
  );
}

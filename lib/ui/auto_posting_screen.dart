import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/repo.dart';
import 'theme.dart';

Map<String, String> autoAccountLabels(AppState state) => {
  for (final a in state.accounts) a.key: a.label,
  for (final a in state.accounts)
    if (a.bankCode != null && a.accountNumber != null)
      '${a.bankCode}:${a.accountNumber}': a.label,
};

Future<bool> askAutoPosting(
  BuildContext context,
  AutoPostingProgress progress, {
  String? sourceName,
  Map<String, String> accountLabels = const {},
}) async {
  final scope = jsonDecode(
    progress.pattern['scope_json'] as String,
  ) as Map<String, dynamic>;
  String accountLabel(Object? value) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) return '알림에서 확인';
    if (accountLabels.containsKey(text)) return accountLabels[text]!;
    final number = text.contains(':') ? text.split(':').last : '';
    return RegExp(r'^\d{6,}$').hasMatch(number)
        ? '등록 통장 · 끝자리 ${number.substring(number.length - 4)}'
        : text;
  }

  final source =
      sourceName ??
      {
        'com.nonghyup.nhallonebank': 'NH올원뱅크',
        'com.kakaobank.channel': '카카오뱅크',
        'viva.republica.toss': '토스',
      }[scope['package']] ??
      scope['package'];
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('이 패턴만 자동 반영할까요?'),
          content: SingleChildScrollView(
            child: Text(
              '${progress.pattern['label']}\n\n출처: $source\n보내는/받는 통장: ${accountLabel(scope['account'])}\n상대 통장: ${accountLabel(progress.pattern['destination'] ?? scope['destination'])}\n알림 제목: ${scope['title']}\n거래 문구: ${scope['snippet']}\n\n같은 출처·통장·문구의 새 알림을 ${progress.pattern['category'] ?? '현재 선택한 분류'}로 기록해요. 금액은 새 알림에서 읽어요.\n\n수정하거나 되돌리면 이 패턴은 멈추고 다시 확인받아요.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('계속 확인받기'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('이 패턴만 자동 반영'),
            ),
          ],
        ),
      ) ??
      false;
}

class AutoProgressCard extends StatelessWidget {
  const AutoProgressCard(
    this.progress, {
    this.onEnable,
    this.onPause,
    super.key,
  });
  final AutoPostingProgress progress;
  final VoidCallback? onEnable, onPause;
  @override
  Widget build(BuildContext context) {
    final p = progress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.enabled
                  ? '자동 반영 중'
                  : p.paused
                  ? '자동 반영 일시중지'
                  : p.ready
                  ? '자동 반영 전환 조건을 충족했어요'
                  : p.checked >= 10
                  ? '아직 확인이 더 필요해요'
                  : '확인 ${10 - p.checked}건이 더 필요해요',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Dsn.blue,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${p.checked}/10건 확인 · ${p.correct}건 제안 일치 · 최근 ${p.streak}건 연속 일치',
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: p.checked / 10),
            const SizedBox(height: 12),
            const Text(
              '같은 패턴 최근 10건 중 9건 이상 일치하고, 최근 5건 연속 수정이 없으면 전환을 제안해요.',
              style: TextStyle(fontSize: 12),
            ),
            if (p.checked == 10 && !p.ready && !p.enabled)
              const Text(
                '일치 조건이 충족될 때까지 새 확인 결과로 다시 계산해요.',
                style: TextStyle(fontSize: 12),
              ),
            if (p.enabled)
              TextButton(onPressed: onPause, child: const Text('자동 반영 일시중지'))
            else
              TextButton(
                onPressed: onEnable,
                child: Text(p.ready ? '이 패턴 자동 반영 켜기' : '이 패턴은 지금부터 자동 반영'),
              ),
          ],
        ),
      ),
    );
  }
}

class AutoPostingScreen extends StatefulWidget {
  const AutoPostingScreen(this.s, {super.key});
  final AppState s;
  @override
  State<AutoPostingScreen> createState() => _AutoPostingScreenState();
}

class _AutoPostingScreenState extends State<AutoPostingScreen> {
  late Future<List<AutoPostingProgress>> data;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    reload();
  }

  void reload() {
    data = widget.s.repo.autoPatterns();
  }

  Future<void> change(AutoPostingProgress p, bool enabled) async {
    if (enabled &&
        !await askAutoPosting(
          context,
          p,
          accountLabels: autoAccountLabels(widget.s),
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await widget.s.repo.setAutoPosting(p.key, enabled, manual: true);
      if (mounted) setState(reload);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is StateError ? e.message.toString() : '설정을 바꾸지 못했어요.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('패턴 학습과 자동 반영')),
    body: FutureBuilder(
      future: data,
      builder: (context, snap) {
        if (snap.hasError) {
          return const Center(child: Text('목록을 불러오지 못했어요. 다시 열어 주세요.'));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              '직접 허용한 패턴만 자동 반영해요. 기존 학습은 유지하고, 전환 기준은 새로 확인한 추천 결과부터 계산해요.',
            ),
            const SizedBox(height: 12),
            if (snap.data!.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('통장이 확인되는 알림에서 분류를 확인하면 패턴이 쌓여요.'),
              ),
            for (final p in snap.data!) ...[
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(p.pattern['label'] as String),
              ),
              AutoProgressCard(
                p,
                onEnable: busy ? null : () => change(p, true),
                onPause: busy ? null : () => change(p, false),
              ),
            ],
          ],
        );
      },
    ),
  );
}

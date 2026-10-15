import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/repo.dart';
import 'theme.dart';

String classificationLabel(String type, String? category) =>
    '${switch (type) {
      'transfer' => '내 계좌 이체',
      'income' => '수입',
      _ => '지출',
    }} · ${category ?? '미분류'}';

class PersonalReviewScreen extends StatefulWidget {
  const PersonalReviewScreen(
    this.s,
    this.tx,
    this.suggestion, {
    required this.amountLabel,
    required this.onDetails,
    super.key,
  });
  final AppState s;
  final TxRow tx;
  final PersonalSuggestion suggestion;
  final String amountLabel;
  final Future<void> Function() onDetails;
  @override
  State<PersonalReviewScreen> createState() => _PersonalReviewScreenState();
}

class _PersonalReviewScreenState extends State<PersonalReviewScreen> {
  bool correcting = false, busy = false;
  String? error;
  late String type = widget.suggestion.type;
  late String category = widget.suggestion.category;
  List<String> get choices => type == 'transfer'
      ? transferPurposes
      : type == 'income'
      ? ['월급', '용돈', '기타수입']
      : allCategories;

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (correcting) {
        await widget.s.repo.correctPersonalSuggestion(
          widget.suggestion,
          type: type,
          category: category,
        );
      } else {
        await widget.s.repo.approvePersonalSuggestion(widget.suggestion);
      }
      await widget.s.refresh();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final app = widget.s;
      final txId = widget.tx.id;
      Navigator.pop(context, true);
      messenger.showSnackBar(
        SnackBar(
          content: const Text('분류를 반영하고 학습했어요.'),
          action: SnackBarAction(
            label: '되돌리기',
            onPressed: () async {
              final restored = await app.repo.undoClassification(txId);
              await app.refresh();
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    restored
                        ? '분류와 학습을 되돌렸어요.'
                        : '이미 내역이 바뀌었어요. 거래 상세에서 확인해 주세요.',
                  ),
                ),
              );
            },
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e is StateError
              ? e.message.toString()
              : '저장하지 못했어요. 다시 시도해 주세요.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tx = widget.tx;
    final suggestion = widget.suggestion;
    final labelOf = {for (final a in widget.s.accounts) a.key: a.label};
    final route =
        tx.route ??
        (tx.destination != null
            ? '${labelOf[tx.account] ?? tx.account ?? '통장'} → ${labelOf[tx.destination] ?? tx.destination}'
            : labelOf[tx.account] ?? tx.account ?? '통장 미지정');
    final allowedTypes = tx.pairId != null
        ? ['transfer']
        : tx.direction == 'in' || tx.type == 'income'
        ? ['income', 'transfer']
        : ['expense', 'transfer'];
    final categoryChoices = {category, ...choices}.toList();
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('분류 도우미')),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 16),
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.verified_user_outlined,
                        size: 16,
                        color: Dsn.mint,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '휴대폰 안에서 학습 · 승인 후 반영',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  const Center(
                    child: RoundIcon(
                      Icons.auto_awesome_rounded,
                      Dsn.blue,
                      size: 48,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '${suggestion.category}${suggestion.category.endsWith('금') ? '으로' : ' 분류로'} 보입니다',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '이번 거래가 어떤 돈인지 확인해 주세요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${tx.occurredAt.month}월 ${tx.occurredAt.day}일 · ${tx.title}',
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 8),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              widget.amountLabel,
                              style: const TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(route),
                          const SizedBox(height: 16),
                          const Divider(height: 1),
                          const SizedBox(height: 12),
                          Text(
                            '추천 분류',
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Dsn.mint.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              classificationLabel(
                                suggestion.type,
                                suggestion.category,
                              ),
                              style: const TextStyle(
                                color: Dsn.mint,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '현재: ${classificationLabel(tx.type, tx.category)}',
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.lightbulb_outline_rounded,
                        color: Dsn.blue,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '이렇게 판단했어요',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              suggestion.evidence,
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (correcting) ...[
                    const SizedBox(height: 22),
                    DropdownButtonFormField<String>(
                      initialValue: type,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '돈의 성격'),
                      items: [
                        for (final value in allowedTypes)
                          DropdownMenuItem(
                            value: value,
                            child: Text(switch (value) {
                              'transfer' => '내 계좌 이체',
                              'income' => '수입',
                              _ => '지출',
                            }),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (value) => setState(() {
                              type = value!;
                              category = choices.first;
                            }),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey(type),
                      initialValue: category,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: type == 'transfer' ? '이체 목적' : '맞는 분류',
                      ),
                      items: [
                        for (final value in categoryChoices)
                          DropdownMenuItem(value: value, child: Text(value)),
                      ],
                      onChanged: busy
                          ? null
                          : (value) => setState(() => category = value!),
                    ),
                  ],
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(error!, style: TextStyle(color: cs.error)),
                    ),
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            final app = widget.s;
                            await widget.onDetails();
                            if (!mounted) return;
                            final latest = await app.repo.personalSuggestions();
                            if (context.mounted && !latest.containsKey(tx.id)) {
                              Navigator.pop(context);
                            }
                          },
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: const Text('원래 내역 확인·수정'),
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  22,
                  10,
                  22,
                  16 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton(
                      onPressed: busy ? null : save,
                      child: Text(
                        busy
                            ? '반영 중…'
                            : correcting
                            ? '이 분류로 반영하고 학습'
                            : '맞아요, 반영하고 학습',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() => correcting = !correcting),
                      child: Text(correcting ? '추천 분류로 돌아가기' : '다른 분류예요'),
                    ),
                    Text(
                      '승인한 거래만 배워요. 나중에 되돌릴 수 있어요.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

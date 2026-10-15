import 'package:flutter/material.dart';
import 'notification_review.dart';

import '../app_state.dart';
import '../data/settlement_repo.dart';
import '../lock.dart';
import 'extras_screens.dart';
import 'screens.dart';
import 'theme.dart';

String _sourceLabel(String pkg) => switch (pkg) {
      'com.kakaobank.channel' => '카카오뱅크',
      'viva.republica.toss' => '토스',
      'com.kakao.talk' => '카카오톡 (삼성카드)',
      'com.samsung.android.messaging' ||
      'com.google.android.apps.messaging' =>
        '문자',
      _ => pkg,
    };

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '방금';
  if (d.inHours < 1) return '${d.inMinutes}분 전';
  if (d.inDays < 1) return '${d.inHours}시간 전';
  return '${d.inDays}일 전';
}

/// 아이콘 + 제목 + 값 한 줄. 입력은 눌러서 따로 연다 (폼처럼 늘어놓지 않는다).
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.color,
    required this.title,
    this.value,
    this.trailing,
    this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          RoundIcon(icon, color, size: 40),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ?(value == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(value!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: grey)),
                    )),
            ]),
          ),
          ?trailing,
          if (trailing == null && onTap != null)
            Icon(Icons.chevron_right_rounded, color: grey),
        ]),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title, this.children);
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
          child: Text(title,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Column(children: children),
          ),
        ),
      ]);
}

/// 글자체 드롭다운. 각 항목이 자기 글자체로 보인다.
class _FontDropdown extends StatelessWidget {
  const _FontDropdown(this.s);
  final AppState s;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: s.font,
          borderRadius: BorderRadius.circular(16),
          icon: const Icon(Icons.expand_more_rounded),
          items: [
            for (final e in fontChoices.entries)
              DropdownMenuItem(
                value: e.key,
                child: Text(e.value,
                    style: fontStyle(e.key, const TextStyle(fontSize: 16))),
              ),
          ],
          onChanged: (v) {
            if (v != null) s.setFont(v);
          },
        ),
      ),
    );
  }
}

class _ScaleRow extends StatefulWidget {
  const _ScaleRow(this.s);
  final AppState s;
  @override
  State<_ScaleRow> createState() => _ScaleRowState();
}

class _ScaleRowState extends State<_ScaleRow> {
  late double _v = widget.s.textScale;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Row(children: [
        const RoundIcon(Icons.format_size_rounded, Dsn.amber, size: 40),
        const SizedBox(width: 14),
        const Text('글자 크기',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        Expanded(
          child: Slider(
            value: _v,
            min: 0.85,
            max: 1.3,
            divisions: 9,
            label: '${(_v * 100).round()}%',
            onChanged: (v) => setState(() => _v = v),
            onChangeEnd: widget.s.setTextScale,
          ),
        ),
      ]),
    );
  }
}

Future<void> _editText(BuildContext context,
    {required String title,
    required String hint,
    String? help,
    required String initial,
    int maxLines = 1,
    required Future<void> Function(String) onSave}) {
  final ctl = TextEditingController(text: initial);
  return showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        if (help != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(help,
                style: TextStyle(
                    fontSize: 13, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: ctl,
          autofocus: true,
          maxLines: maxLines,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: maxLines > 1
              ? null
              : (v) async {
                  await onSave(v.trim());
                  if (ctx.mounted) Navigator.pop(ctx);
                },
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () async {
              await onSave(ctl.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('저장'),
          ),
        ),
      ]),
    ),
  );
}

Future<void> _editCategoryBudgets(BuildContext context, AppState s) async {
  final current = await s.repo.budget.budgets();
  if (!context.mounted) return;
  final ctls = {
    for (final c in allCategories)
      c: TextEditingController(text: current[c]?.toString() ?? ''),
  };
  await showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('카테고리 예산',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('비워 두면 예산 없음'),
          const SizedBox(height: 12),
          for (final c in allCategories)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                RoundIcon(catIcon(c), Dsn.cat(c), size: 34),
                const SizedBox(width: 12),
                Expanded(child: Text(c)),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: ctls[c],
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(suffixText: '원', isDense: true),
                  ),
                ),
              ]),
            ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () async {
                for (final e in ctls.entries) {
                  await s.repo.budget
                      .setBudget(e.key, int.tryParse(e.value.text.replaceAll(',', '')));
                }
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

class SettingsScreen extends StatelessWidget {
  const SettingsScreen(this.s, {super.key});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(10, 8, 10, 0),
        child: Text('설정', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
      ),
      // 미리보기: 고른 글자체와 크기가 바로 보인다.
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              const RoundIcon(Icons.local_cafe_rounded, Color(0xFFB08968), size: 46),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('커피브레이크',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  Text('카페 · 삼성카드 · 10월 13일', style: TextStyle(fontSize: 13)),
                ]),
              ),
              Text('−4,500원',
                  style: TextStyle(
                      color: Dsn.coral, fontSize: 17, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
      _Group('화면', [
        _Row(icon: Icons.widgets_outlined, color: Dsn.blue,
          title: '홈 화면 위젯 추가', value: '이번 달 지출 · 남은 예산 · 직접 입력',
          onTap: () async {
            final accepted = await s.pinWidget();
            if (!context.mounted || accepted) return;
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('홈 화면을 길게 눌러 위젯 목록에서 주머니를 선택하세요.')));
          }),
        _Row(
          icon: Icons.font_download_rounded,
          color: Dsn.blue,
          title: '글자체',
          trailing: _FontDropdown(s),
        ),
        _ScaleRow(s),
      ]),
      _Group('개인화 학습', [
        _Row(icon: Icons.auto_awesome_rounded, color: Dsn.blue,
          title:'분류 도우미',value:'승인 자료 ${s.personalLearnedCount}건 · 추천 후 확인',
          onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>ReviewScreen(s)))),
      ]),
      _Group('예산', [
        _Row(
          icon: Icons.savings_rounded,
          color: Dsn.coral,
          title: '한 달 예산',
          value: () {
            final t = s.budgetLines.where((b) => b.category == null).firstOrNull;
            return t == null ? '정하면 홈에서 남은 돈과 하루 사용 가능 금액을 보여 줘요' : '${fmt(t.limit)}원';
          }(),
          onTap: () => _editText(context,
              title: '한 달 예산',
              hint: '예: 1500000',
              help: '비우거나 0이면 예산을 지워요.',
              initial: (s.budgetLines.where((b) => b.category == null).firstOrNull?.limit ?? '')
                  .toString(),
              onSave: (v) => s.setBudget(null, int.tryParse(v.replaceAll(',', '')))),
        ),
        _Row(
          icon: Icons.category_rounded,
          color: Dsn.coral,
          title: '카테고리 예산',
          value: () {
            final n = s.budgetLines.where((b) => b.category != null).length;
            return n == 0 ? '식비, 카페처럼 따로 한도를 정해요' : '$n개 설정됨';
          }(),
          onTap: () => _editCategoryBudgets(context, s),
        ),
      ]),
      _Group('보안', [
        _Row(
          icon: Icons.lock_rounded,
          color: Dsn.mint,
          title: '앱 잠금',
          value: s.lock.enabled ? 'PIN 6자리 사용 중' : '꺼짐',
          trailing: Switch(
            value: s.lock.enabled,
            onChanged: (on) async {
              if (on) {
                final pin = await askNewPin(context);
                if (pin != null) await s.setPin(pin);
              } else {
                await s.disableLock();
              }
            },
          ),
        ),
        if (s.lock.enabled) ...[
          FutureBuilder<bool>(
            future: biometricAvailable(),
            builder: (c, snap) => _Row(
              icon: Icons.fingerprint_rounded,
              color: Dsn.mint,
              title: '지문/얼굴로 열기',
              value: snap.data == false ? '이 기기에 등록된 생체 정보가 없어요' : null,
              trailing: Switch(
                value: s.lock.biometric,
                onChanged: snap.data == true ? s.setBiometric : null,
              ),
            ),
          ),
          _Row(
            icon: Icons.timer_rounded,
            color: Dsn.mint,
            title: '다시 잠기는 시간',
            trailing: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: s.lock.delaySec,
                borderRadius: BorderRadius.circular(16),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('즉시')),
                  DropdownMenuItem(value: 60, child: Text('1분 후')),
                  DropdownMenuItem(value: 300, child: Text('5분 후')),
                ],
                onChanged: (v) => s.setLockDelay(v ?? 60),
              ),
            ),
          ),
        ],
      ]),
      _Group('정산', [
        _Row(
          icon: Icons.account_balance_rounded,
          color: Dsn.amber,
          title: '입금 받을 계좌',
          value: s.payAccount.isEmpty ? '정산 요청 문구에 들어가요' : s.payAccount,
          onTap: () => _editText(context,
              title: '입금 받을 계좌',
              hint: '예: 카카오뱅크 3333-00-0000000 홍길동',
              help: '정산 요청 문구 아래에 같이 보내져요.',
              initial: s.payAccount,
              onSave: s.setPayAccount),
        ),
        _Row(
          icon: Icons.chat_bubble_outline_rounded,
          color: Dsn.mint,
          title: '요청 문구',
          value: s.requestTemplate.replaceAll('\n', ' / '),
          onTap: () => _editText(context,
              title: '요청 문구',
              hint: defaultRequestTemplate,
              help: '{이름} {정산명} {금액} {계좌}가 자동으로 채워져요.',
              initial: s.requestTemplate,
              maxLines: 4,
              onSave: s.setRequestTemplate),
        ),
        _Row(
          icon: Icons.person_rounded,
          color: Dsn.blue,
          title: '내 이름',
          value: s.myNames.isEmpty
              ? '입력하면 본인 이체를 지출에서 빼요'
              : s.myNames,
          onTap: () => _editText(context,
              title: '내 이름',
              hint: '홍길동',
              help: '쉼표로 여러 개 입력할 수 있어요. 홍*동처럼 가려진 이름도 같이 인식해요.',
              initial: s.myNames,
              onSave: s.setMyNames),
        ),
      ]),
      _Group('데이터', [
        _Row(
          icon: Icons.cloud_upload_rounded,
          color: Dsn.blue,
          title: '백업 내보내기',
          value: s.lastBackupAt == null
              ? '암호로 잠근 파일로 저장해요'
              : '마지막 백업 ${s.lastBackupAt!.month}월 ${s.lastBackupAt!.day}일',
          onTap: () => exportBackup(context, s),
        ),
        _Row(
          icon: Icons.table_view_rounded,
          color: Dsn.mint,
          title: 'CSV로 내보내기',
          value: '엑셀에서 바로 열 수 있어요',
          onTap: () => showModalBottomSheet(
            context: context,
            useSafeArea: true,
            showDragHandle: true,
            builder: (ctx) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                  leading: const Icon(Icons.calendar_month_rounded),
                  title: Text('${s.month.year}년 ${s.month.month}월'),
                  onTap: () {
                    Navigator.pop(ctx);
                    exportCsvFile(context, s, month: s.month);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.all_inclusive_rounded),
                  title: const Text('전체 기간'),
                  onTap: () {
                    Navigator.pop(ctx);
                    exportCsvFile(context, s);
                  },
                ),
              ]),
            ),
          ),
        ),
        _Row(
          icon: Icons.cloud_download_rounded,
          color: Dsn.mint,
          title: '백업 불러오기',
          value: '기존 내역과 합쳐져요',
          onTap: () => importBackup(context, s),
        ),
        _Row(
          icon: Icons.history_rounded,
          color: const Color(0xFF94A3B8),
          title: '알림 원문 보관 기간',
          value: '원문만 지우고 내역은 남아요',
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: s.rawKeepDays,
              borderRadius: BorderRadius.circular(16),
              items: const [
                DropdownMenuItem(value: 30, child: Text('30일')),
                DropdownMenuItem(value: 90, child: Text('90일')),
                DropdownMenuItem(value: 180, child: Text('180일')),
                DropdownMenuItem(value: 0, child: Text('무기한')),
              ],
              onChanged: (v) => s.setRawKeepDays(v ?? 90),
            ),
          ),
        ),
      ]),
      _Group('알림 수집', [
        _Row(icon:Icons.notifications_off_outlined,color:Dsn.blue,title:'숨긴 알림',value:'거절한 알림 확인 · 숨김 해제 · 되돌리기',onTap:()=>Navigator.of(context).push(MaterialPageRoute(builder:(_)=>HiddenNotificationsScreen(s)))),
        _Row(icon: Icons.notifications_active_outlined, color: Dsn.blue,
          title: '반영·확인 필요 알림', value: '자동 기록 결과를 알림으로 받아요 · 유형별 끄기는 알림 설정에서',
          onTap: s.requestResultNotifications),
        _Row(
          icon: s.listenerOn
              ? Icons.notifications_active_rounded
              : Icons.notifications_off_rounded,
          color: s.listenerOn ? Dsn.mint : Dsn.coral,
          title: s.listenerOn ? '알림 수집 켜짐' : '알림 접근이 꺼져 있어요',
          value: '저장된 알림 ${s.rawTotal}건',
          trailing: TextButton(
              onPressed: s.openListenerSettings, child: const Text('권한')),
        ),
        _Row(
          icon: Icons.bolt_rounded,
          color: Dsn.amber,
          title: '백그라운드 처리',
          value: s.bgLastRun == null
              ? '아직 없어요 (알림이 오면 앱을 열지 않아도 바로 변환해요)'
              : '마지막 ${_ago(s.bgLastRun!)} · 지금까지 ${s.bgTotalSaved}건',
        ),
        for (final src in s.sources)
          _Row(
            icon: Icons.sms_rounded,
            color: const Color(0xFF94A3B8),
            title: _sourceLabel(src.package),
            value: '마지막 수신 ${_ago(src.last)}',
            trailing: DateTime.now().difference(src.last).inDays >= 7
                ? const Icon(Icons.warning_amber_rounded, color: Dsn.coral)
                : null,
          ),
        _Row(
          icon: Icons.add_alert_rounded,
          color: Dsn.blue,
          title: '추가 수집 앱 관리',
          value: '입출금 형태는 자동 수집 · 필요한 앱만 추가 지정',
          onTap: () => _pickApps(context, s),
        ),
        _Row(
          icon: Icons.fact_check_rounded,
          color: Dsn.blue,
          title: '확인이 필요한 내역',
          value: '미분류, 중복 의심, 인식 못 한 알림',
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => ReviewScreen(s))),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Center(
          child: Text('주머니 · 데이터는 이 폰 안에만 저장돼요',
              style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
        ),
      ),
    ]);
  }
}

/// 설치된 앱 중 알림을 모을 금융 앱을 고른다. 금융 키워드가 있는 알림만 저장된다.
Future<void> _pickApps(BuildContext context, AppState s) async {
  final apps = await s.installedApps();
  final chosen = {...await s.extraPackages()};
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) {
      var q = '';
      return StatefulBuilder(builder: (ctx, set) {
        final shown = apps
            .where((a) => chosen.contains(a.package) || a.name.contains(q))
            .toList();
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.8,
          builder: (_, sc) => Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                decoration: const InputDecoration(
                    hintText: '앱 이름 검색 (예: 국민, 신한)',
                    prefixIcon: Icon(Icons.search_rounded)),
                onChanged: (v) => set(() => q = v.trim()),
              ),
            ),
            Expanded(
              child: ListView(controller: sc, children: [
                for (final a in shown)
                  CheckboxListTile(
                    title: Text(a.name),
                    subtitle: Text(a.package, style: const TextStyle(fontSize: 11)),
                    value: chosen.contains(a.package),
                    onChanged: (on) async {
                      on == true ? chosen.add(a.package) : chosen.remove(a.package);
                      await s.setExtraPackages(chosen.toList());
                      set(() {});
                    },
                  ),
              ]),
            ),
          ]),
        );
      });
    },
  );
}

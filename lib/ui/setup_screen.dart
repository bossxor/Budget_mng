import 'package:flutter/material.dart';

import '../app_state.dart';
import '../lock.dart';
import 'theme.dart';

/// 처음 한 번 거치는 초기 설정. 이름과 알림 접근을 마치기 전에는 앱 본문으로 못 간다.
class SetupScreen extends StatefulWidget {
  const SetupScreen(this.s, {super.key});
  final AppState s;
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _name = TextEditingController();
  final _account = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _account.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final ready = _name.text.trim().isNotEmpty && s.listenerOn;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 32), children: [
          const Text('주머니에 오신 걸 환영해요',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('시작 전에 두 가지만 정해 주세요.', style: TextStyle(color: grey)),
          const SizedBox(height: 22),
          const Text('1. 내 이름 (필수)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('내 계좌끼리의 이체와 남이 보낸 돈을 구분하는 데 써요. 여러 개면 쉼표로 나눠 주세요.',
              style: TextStyle(fontSize: 13, color: grey)),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: '예: 홍길동, 길동이'),
          ),
          const SizedBox(height: 22),
          const Text('2. 알림 접근 허용 (필수)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('결제·입금 알림을 읽어 자동으로 기록해요. 알림 내용은 이 폰 안에만 저장돼요.',
              style: TextStyle(fontSize: 13, color: grey)),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: Icon(
                  s.listenerOn ? Icons.check_circle_rounded : Icons.notifications_off_rounded,
                  color: s.listenerOn ? Dsn.mint : Dsn.coral),
              title: Text(s.listenerOn ? '허용됨' : '아직 허용되지 않았어요'),
              trailing: s.listenerOn
                  ? null
                  : FilledButton(
                      onPressed: s.openListenerSettings, child: const Text('열기')),
            ),
          ),
          if (!s.listenerOn)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: s.refresh, child: const Text('허용했어요, 다시 확인')),
            ),
          const SizedBox(height: 22),
          const Text('나중에 해도 돼요',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          TextField(
            controller: _account,
            decoration: const InputDecoration(
                labelText: '입금 받을 계좌', hintText: '예: 카카오뱅크 3333-00-0000000 홍길동'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.lock_rounded),
            label: Text(s.lock.enabled ? 'PIN 사용 중' : '앱 잠금 PIN 설정'),
            onPressed: s.lock.enabled
                ? null
                : () async {
                    final pin = await askNewPin(context);
                    if (pin != null) await s.setPin(pin);
                  },
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: ready
                ? () => s.finishSetup(_name.text.trim(), _account.text.trim())
                : null,
            child: const Text('시작하기'),
          ),
        ]),
      ),
    );
  }
}

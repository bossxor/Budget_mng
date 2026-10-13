import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'app_state.dart';

const pinLength = 6;

String hashPin(String pin, String salt) {
  List<int> h = utf8.encode('$salt:$pin');
  for (var i = 0; i < 20000; i++) {
    h = sha256.convert(h).bytes;
  }
  return base64.encode(h);
}

String newSalt() {
  final r = Random.secure();
  return base64.encode(List.generate(16, (_) => r.nextInt(256)));
}

/// 앱 잠금 상태. AppState가 보관하고 화면은 [LockGate]가 가린다.
class AppLock {
  bool enabled = false;
  bool locked = false;
  bool biometric = false;
  int delaySec = 60; // 0이면 앱을 벗어나는 즉시 잠김
  String? hash;
  String? salt;
  DateTime? pausedAt;
  int failures = 0;
  DateTime? blockedUntil;

  bool checkPin(String pin) =>
      hash != null && salt != null && hashPin(pin, salt!) == hash;
}

const _native = MethodChannel('jumeoni/native');

Future<void> applySecureFlag(bool on) async {
  try {
    await _native.invokeMethod('setSecure', on);
  } catch (_) {}
}

Future<bool> biometricAvailable() async {
  try {
    final a = LocalAuthentication();
    return await a.canCheckBiometrics && (await a.getAvailableBiometrics()).isNotEmpty;
  } catch (_) {
    return false;
  }
}

Future<bool> authenticateBiometric() async {
  try {
    return await LocalAuthentication().authenticate(
      localizedReason: '주머니 잠금을 해제합니다',
      biometricOnly: true,
    );
  } catch (_) {
    return false;
  }
}

/// 잠겨 있으면 앱 내용 대신 PIN 입력 화면을 보여준다.
class LockGate extends StatelessWidget {
  const LockGate(this.s, {super.key, required this.child});
  final AppState s;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      s.lock.enabled && s.lock.locked ? LockScreen(s) : child;
}

class LockScreen extends StatefulWidget {
  const LockScreen(this.s, {super.key});
  final AppState s;
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  String? _msg;

  @override
  void initState() {
    super.initState();
    if (widget.s.lock.biometric) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bio());
    }
  }

  Future<void> _bio() async {
    if (await authenticateBiometric()) widget.s.unlock();
  }

  void _tap(String d) {
    final l = widget.s.lock;
    if (l.blockedUntil != null && DateTime.now().isBefore(l.blockedUntil!)) {
      final sec = l.blockedUntil!.difference(DateTime.now()).inSeconds + 1;
      setState(() => _msg = '$sec초 후에 다시 시도하세요');
      return;
    }
    if (_pin.length >= pinLength) return;
    setState(() {
      _pin += d;
      _msg = null;
    });
    if (_pin.length == pinLength) {
      if (l.checkPin(_pin)) {
        widget.s.unlock();
      } else {
        l.failures++;
        if (l.failures % 5 == 0) {
          l.blockedUntil = DateTime.now().add(const Duration(seconds: 30));
        }
        setState(() {
          _pin = '';
          _msg = 'PIN이 맞지 않아요';
        });
        HapticFeedback.mediumImpact();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget key(String label, {VoidCallback? onTap, IconData? icon}) => SizedBox(
          width: 80,
          height: 64,
          child: TextButton(
            onPressed: onTap,
            child: icon != null
                ? Icon(icon)
                : Text(label, style: const TextStyle(fontSize: 26)),
          ),
        );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 40),
            const SizedBox(height: 12),
            const Text('PIN을 입력하세요', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 20),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < pinLength; i++)
                Container(
                  margin: const EdgeInsets.all(6),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? cs.primary : null,
                    border: Border.all(color: cs.outline),
                  ),
                ),
            ]),
            SizedBox(
                height: 28,
                child: Text(_msg ?? '', style: TextStyle(color: cs.error))),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final d in row) key(d, onTap: () => _tap(d)),
              ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              widget.s.lock.biometric
                  ? key('', icon: Icons.fingerprint, onTap: _bio)
                  : const SizedBox(width: 80),
              key('0', onTap: () => _tap('0')),
              key('', icon: Icons.backspace_outlined, onTap: () {
                if (_pin.isNotEmpty) {
                  setState(() => _pin = _pin.substring(0, _pin.length - 1));
                }
              }),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// PIN을 두 번 입력받아 반환한다. 취소하면 null.
Future<String?> askNewPin(BuildContext context) {
  final a = TextEditingController();
  final b = TextEditingController();
  String? err;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('PIN 설정'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: a,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: pinLength,
            decoration: const InputDecoration(labelText: 'PIN $pinLength자리'),
          ),
          TextField(
            controller: b,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: pinLength,
            decoration: InputDecoration(labelText: '한 번 더 입력', errorText: err),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          FilledButton(
            onPressed: () {
              if (!RegExp(r'^\d{6}$').hasMatch(a.text)) {
                setS(() => err = '숫자 $pinLength자리를 입력하세요');
              } else if (a.text != b.text) {
                setS(() => err = '두 PIN이 달라요');
              } else {
                Navigator.pop(ctx, a.text);
              }
            },
            child: const Text('저장'),
          ),
        ],
      ),
    ),
  );
}

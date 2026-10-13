import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/repo.dart';
import 'data/planning_repo.dart';
import 'data/settlement_repo.dart';
import 'lock.dart';

const fontChoices = {
  'noto': 'Noto Sans KR',
  'nanum': '나눔고딕',
  'gowun': '고운돋움',
  'plex': 'IBM Plex Sans KR',
  'serif': 'Noto Serif KR',
};

/// 글자체 키 -> Google Fonts 이름.
const fontGoogleNames = {
  'noto': 'Noto Sans KR',
  'nanum': 'Nanum Gothic',
  'gowun': 'Gowun Dodum',
  'plex': 'IBM Plex Sans KR',
  'serif': 'Noto Serif KR',
};

const _channel = MethodChannel('jumeoni/native');

class AppState extends ChangeNotifier {
  AppState(this.repo);
  final Repo repo;

  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  String font = 'noto';
  double textScale = 1.0;
  List<TxRow> rows = [];
  MonthSummary summary = MonthSummary(0, 0, {}, 0);
  List<AccountRow> accounts = [];
  bool listenerOn = true;
  int rawTotal = 0;
  String myNames = '';
  int receivable = 0; // 아직 못 받은 정산 금액
  List<LinkSuggestion> suggestions = [];
  SavingsSummary savings = SavingsSummary(0, 0);
  List<PlanStatus> plans = [];
  List<GapAlert> gaps = [];
  List<SourceStatus> sources = [];
  DateTime? lastBackupAt;
  int rawKeepDays = 90;
  String payAccount = '';
  final lock = AppLock();

  Future<void> load() async {
    await repo.recoverClaims();
    await repo.purgeNoise();
    final keep = int.tryParse(await repo.getKv('raw_keep_days') ?? '') ?? 90;
    await repo.purgeRaw(keep);
    font = (await repo.getKv('font')) ?? 'noto';
    textScale = double.tryParse(await repo.getKv('text_scale') ?? '') ?? 1.0;
    myNames = (await repo.getKv('my_names')) ?? '';
    payAccount = (await repo.getKv('pay_account')) ?? '';
    await _loadLock();
    await refresh();
  }

  /// 쌓인 알림을 거래로 변환하고 화면 데이터를 다시 읽는다.
  Future<void> refresh() async {
    await repo.processPending();
    rows = await repo.monthTx(month);
    summary = await repo.summary(month);
    accounts = await repo.accounts();
    rawTotal = await repo.rawCount();
    receivable =
        (await repo.settlements.all()).fold(0, (a, x) => a + x.outstanding);
    suggestions = await repo.settlements.suggestions();
    savings = await repo.planning.savings(month);
    plans = await repo.planning.status(month);
    gaps = await repo.gaps();
    sources = await repo.sourceStatus();
    final lb = int.tryParse(await repo.getKv('last_backup_at') ?? '');
    lastBackupAt = lb == null ? null : DateTime.fromMillisecondsSinceEpoch(lb);
    rawKeepDays = int.tryParse(await repo.getKv('raw_keep_days') ?? '') ?? 90;
    try {
      listenerOn = await _channel.invokeMethod<bool>('isListenerEnabled') ?? false;
    } catch (_) {
      listenerOn = false;
    }
    notifyListeners();
  }

  Future<void> openListenerSettings() async {
    try {
      await _channel.invokeMethod('openListenerSettings');
    } catch (_) {}
  }

  Future<void> shiftMonth(int d) async {
    month = DateTime(month.year, month.month + d);
    await refresh();
  }

  Future<void> setFont(String f) async {
    font = f;
    await repo.setKv('font', f);
    notifyListeners();
  }

  Future<void> setTextScale(double s) async {
    textScale = s;
    await repo.setKv('text_scale', s.toString());
    notifyListeners();
  }

  Future<void> _loadLock() async {
    final h = await repo.getKv('lock_hash');
    lock.hash = (h == null || h.isEmpty) ? null : h;
    lock.salt = await repo.getKv('lock_salt');
    lock.enabled = lock.hash != null;
    lock.biometric = (await repo.getKv('lock_bio')) == '1';
    lock.delaySec = int.tryParse(await repo.getKv('lock_delay') ?? '') ?? 60;
    lock.locked = lock.enabled; // 앱을 새로 켜면 항상 잠금
    await applySecureFlag(lock.enabled);
  }

  Future<void> setPin(String pin) async {
    lock.salt = newSalt();
    lock.hash = hashPin(pin, lock.salt!);
    lock.enabled = true;
    lock.locked = false;
    await repo.setKv('lock_hash', lock.hash!);
    await repo.setKv('lock_salt', lock.salt!);
    await applySecureFlag(true);
    notifyListeners();
  }

  Future<void> disableLock() async {
    lock
      ..enabled = false
      ..locked = false
      ..biometric = false
      ..hash = null
      ..salt = null;
    await repo.setKv('lock_hash', '');
    await repo.setKv('lock_bio', '0');
    await applySecureFlag(false);
    // kv에 빈 문자열이 남지 않게 정리: 빈 값은 해시 없음으로 취급.
    lock.hash = null;
    notifyListeners();
  }

  Future<void> setBiometric(bool on) async {
    lock.biometric = on;
    await repo.setKv('lock_bio', on ? '1' : '0');
    notifyListeners();
  }

  Future<void> setLockDelay(int sec) async {
    lock.delaySec = sec;
    await repo.setKv('lock_delay', '$sec');
    notifyListeners();
  }

  void unlock() {
    lock.locked = false;
    lock.failures = 0;
    lock.blockedUntil = null;
    notifyListeners();
  }

  void appPaused() => lock.pausedAt = DateTime.now();

  void appResumed() {
    final p = lock.pausedAt;
    if (lock.enabled && !lock.locked && p != null &&
        DateTime.now().difference(p).inSeconds >= lock.delaySec) {
      lock.locked = true;
      notifyListeners();
    }
  }

  /// 백업한 지 14일이 넘었고 기록이 있으면 홈에서 알려 준다.
  bool get backupDue {
    if (rows.isEmpty && accounts.isEmpty) return false;
    final lb = lastBackupAt;
    return lb == null || DateTime.now().difference(lb).inDays >= 14;
  }

  Future<void> markBackupDone() async {
    lastBackupAt = DateTime.now();
    await repo.setKv('last_backup_at', '${lastBackupAt!.millisecondsSinceEpoch}');
    notifyListeners();
  }

  Future<void> setRawKeepDays(int d) async {
    rawKeepDays = d;
    await repo.setKv('raw_keep_days', '$d');
    await repo.purgeRaw(d);
    notifyListeners();
  }

  Future<void> setPayAccount(String v) async {
    payAccount = v;
    await repo.setKv('pay_account', v);
    notifyListeners();
  }

  Future<void> setMyNames(String v) async {
    myNames = v;
    await repo.setKv('my_names', v);
    notifyListeners();
  }
}

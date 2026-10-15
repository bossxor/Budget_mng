// 알림 원문 -> ParsedTx. 수집원별 정규식 템플릿 (DESIGN.md 12절).

class ParsedTx {
  ParsedTx({
    required this.source,
    required this.type,
    required this.amount,
    required this.occurredAt,
    this.merchant,
    this.counterparty,
    this.account,
    this.balance,
    this.card,
    this.installment,
    this.installmentMonths,
    this.cumulative,
    this.kind,
    this.via,
    this.actor,
    this.category,
  });

  final String source;
  String type; // expense | income | transfer | group
  final int amount;
  final DateTime occurredAt;
  final String? merchant;
  final String? counterparty;
  final String? account;
  final int? balance;
  final String? card;
  final String? installment;
  final int? installmentMonths;
  final int? cumulative;
  final String? kind;
  final String? via;
  final String? actor;
  String? category;

  /// 가맹점/상대 표시용 이름.
  String get title => merchant ?? counterparty ?? '(알 수 없음)';

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
      'T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Map<String, Object?> toMap() => {
        'source': source,
        'type': type,
        'amount': amount,
        'occurred_at': _iso(occurredAt),
        'merchant': merchant,
        'counterparty': counterparty,
        'account': account,
        'balance': balance,
        'card': card,
        'installment': installment,
        'installment_months': installmentMonths,
        'cumulative': cumulative,
        'kind': kind,
        'via': via,
        'actor': actor,
        'category': category,
      };
}

String _normalize(String s) => s
    .replaceAll('\r\n', '\n')
    .replaceAll('　', ' ')
    .split('\n')
    .map((l) => l.trimRight())
    .join('\n')
    .trim();

int _n(String s) => int.parse(s.replaceAll(',', ''));

/// 본문에 연도가 없어서 수신 시각 기준으로 추정. 미래 날짜면 전년도.
DateTime _inferDate(DateTime received, int m, int d, int hh, int mm) {
  var c = DateTime(received.year, m, d, hh, mm);
  if (c.isAfter(received.add(const Duration(days: 1)))) {
    c = DateTime(received.year - 1, m, d, hh, mm);
  }
  return c;
}

final _card = RegExp(
    r'^(\S+?)(\d{4})(승인취소|승인|취소)\s+(\S+)\n(-?[\d,]+)원\s*(일시불|\d+개월)\n(\d\d)/(\d\d)\s+(\d\d):(\d\d)\s+(.+)\n누적([\d,]+)원',
    multiLine: true);
final _kakaoBank = RegExp(
    r'^(입금|출금)\s+([\d,]+)원\n(.+?)\s*(?:->|→)\s*(.+?)\s*\n잔액\s*([\d,]+)원',
    multiLine: true);
final _sms = RegExp(
    r'^(입금|출금)\n(\d\d)/(\d\d)\s+(\d\d):(\d\d)\s+([\d,]+)\n계좌\s+(\S+)\n내용[ \t]*(.*)\n(?:메모[ \t]*(.*)\n)?잔액\s+([\d,]+)',
    multiLine: true);
final _tossGroup = RegExp(
    r'\[출금 안내\]\n(.+?)에서\n([\d,]+)원이 출금됐어요\.\n(\d\d)/(\d\d)\s+(\d\d):(\d\d)\n(.+)\n거래한 모임원\s*:\s*(.+)');
final _tossMove = RegExp(r'^([\d,]+)원 (입금|출금)\n(.+?)\s*(?:->|→)\s*(.+)$',
    multiLine: true);
final _viaName = RegExp(r'^(토스|카카오페이|카카오뱅크)\s+(.+)$');

/// 지원하는 모든 템플릿을 순서대로 시도한다. 맞는 게 없으면 null.
ParsedTx? parseNotification(String raw, DateTime received) {
  final t = _normalize(raw);

  var m = _card.firstMatch(t);
  if (m != null) {
    final cancel = m[3]!.contains('취소');
    var amt = _n(m[5]!);
    if (cancel && amt > 0) amt = -amt;
    final inst = m[6]!;
    return ParsedTx(
      source: 'card',
      type: 'expense',
      amount: amt,
      occurredAt: _inferDate(received, int.parse(m[7]!), int.parse(m[8]!),
          int.parse(m[9]!), int.parse(m[10]!)),
      merchant: m[11],
      card: '${m[1]}${m[2]}',
      installment: inst,
      installmentMonths:
          inst == '일시불' ? null : int.parse(inst.replaceAll('개월', '')),
      cumulative: _n(m[12]!),
      kind: cancel ? 'cancel' : 'approve',
    );
  }

  m = _kakaoBank.firstMatch(t);
  if (m != null) {
    final incoming = m[1] == '입금';
    final from = m[3]!, to = m[4]!;
    return ParsedTx(
      source: 'kakaobank',
      type: incoming ? 'income' : 'expense',
      amount: _n(m[2]!),
      occurredAt: received, // 알림에 시각 없음
      counterparty: incoming ? from : to,
      account: incoming ? to : from,
      balance: _n(m[5]!),
    );
  }

  m = _sms.firstMatch(t);
  if (m != null) {
    final incoming = m[1] == '입금';
    final desc = (m[8] ?? '').trim();
    final memo = (m[9] ?? '').trim();
    String? via;
    String? who = desc.isNotEmpty ? desc : null;
    if (who == null && memo.isNotEmpty) {
      final vn = _viaName.firstMatch(memo);
      if (vn != null) {
        via = vn[1];
        who = vn[2];
      } else {
        who = memo;
      }
    }
    return ParsedTx(
      source: 'sms',
      type: incoming ? 'income' : 'expense',
      amount: _n(m[6]!),
      occurredAt: _inferDate(received, int.parse(m[2]!), int.parse(m[3]!),
          int.parse(m[4]!), int.parse(m[5]!)),
      counterparty: who,
      account: m[7],
      balance: _n(m[10]!),
      via: via,
    );
  }

  m = _tossGroup.firstMatch(t);
  if (m != null) {
    return ParsedTx(
      source: 'toss',
      type: 'group',
      amount: _n(m[2]!),
      occurredAt: _inferDate(received, int.parse(m[3]!), int.parse(m[4]!),
          int.parse(m[5]!), int.parse(m[6]!)),
      account: m[1],
      counterparty: m[7],
      actor: m[8],
    );
  }

  m = _tossMove.firstMatch(t);
  if (m != null) {
    final incoming = m[2] == '입금';
    return ParsedTx(
      source: 'toss',
      type: incoming ? 'income' : 'expense',
      amount: _n(m[1]!),
      occurredAt: received,
      counterparty: incoming ? m[3] : m[4],
      account: incoming ? m[4] : m[3],
    );
  }

  return parseBankTransfer(t, received);
}

/// 알림의 제목과 본문을 한 덩어리로 합친다. 카카오뱅크처럼 '입금 82원'이 제목에 오는 경우가 있다.
String joinNotification(String? title, String text) =>
    (title == null || title.trim().isEmpty) ? text : '${title.trim()}\n$text';

/// 템플릿이 없는 알림에서 금액과 입출금 방향을 짐작한다 (수동 입력 기본값용).
({int? amount, String type, String title}) guessFromText(String raw) {
  final t = _normalize(raw);
  final a = RegExp(r'([\d,]{1,15})\s*원').firstMatch(t) ??
      RegExp(r'(?:입금|출금|승인|결제|이체|송금)\D{0,6}?([\d,]{1,15})').firstMatch(t);
  final digits = a?.group(1)?.replaceAll(',', '');
  final amount = (digits == null || digits.isEmpty) ? null : int.tryParse(digits);
  final type = RegExp(r'입금|받았|들어왔').hasMatch(t) ? 'income' : 'expense';
  final first = t.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  final title = first.length > 20 ? first.substring(0, 20) : first;
  return (amount: amount, type: type, title: title);
}

/// NH 실측 형식과 앱에 종속되지 않는 명확한 입출금/결제 알림.
ParsedTx? parseBankTransfer(String raw, DateTime received) {
  final text = _normalize(raw).replaceAll('입출금 알림', '');
  if (RegExp(r'\(광고\)|수신거부|알림\s*끄기|인증번호|인증코드|OTP|입금\s*요청|송금\s*요청|출금\s*예정|입금\s*예정|결제\s*예정|이체\s*예정|예약|실패|거절|취소|환불|해주세요|부탁', caseSensitive: false).hasMatch(text)) { return null; }
  final nh = RegExp(r'(?:농협|NH농협|NH올원뱅크)\s*(입금|출금)\s*([\d,]{1,18})원\s*\n(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})\s+([\d*•Xx-]{6,})\s*(.*?)\s*잔액\s*([\d,]{1,18})원', multiLine: true).firstMatch(text);
  if (nh != null) {
    return ParsedTx(source: 'nhallone', type: nh[1] == '입금' ? 'income' : 'expense',
      amount: _n(nh[2]!), occurredAt: _inferDate(received, int.parse(nh[3]!), int.parse(nh[4]!), int.parse(nh[5]!), int.parse(nh[6]!)),
      account: '농협 ${nh[7]}', counterparty: nh[8]!.trim().isEmpty ? null : nh[8]!.trim(), balance: _n(nh[9]!));
  }
  final forward = RegExp(r'(입금|출금|입금액|출금액|결제|승인)(?:완료)?\s*[:：]?\s*([\d,]{1,18})\s*원').firstMatch(text);
  final backward = RegExp(r'([\d,]{1,18})\s*원(?:이|을)?\s*(입금|출금|결제|승인)').firstMatch(text);
  final direction = forward?[1] ?? backward?[2];
  final value = forward?[2] ?? backward?[1];
  if (direction == null || value == null || _n(value) <= 0) { return null; }
  // 서로 다른 방향이 함께 나타나면 추측 저장 대신 검토함에 남긴다.
  if (RegExp(r'입금\s*[:：]?\s*[\d,]{1,18}\s*원').hasMatch(text) &&
      RegExp(r'출금\s*[:：]?\s*[\d,]{1,18}\s*원').hasMatch(text)) { return null; }
  final incoming = direction.startsWith('입금');
  final account = RegExp(r'(?:계좌|통장)(?:번호)?\s*[:：]\s*([^\n]+)').firstMatch(text)?[1]?.trim();
  final balance = RegExp(r'잔액\s*[:：]?\s*([\d,]{1,18})\s*원').firstMatch(text)?[1];
  final party = RegExp(r'(?:내용|입금자|출금처|가맹점)\s*[:：]\s*([^\n]+)').firstMatch(text)?[1]?.trim();
  return ParsedTx(source: 'auto', type: incoming ? 'income' : 'expense', amount: _n(value), occurredAt: received,
    account: account, balance: balance == null ? null : _n(balance),
    counterparty: incoming ? party ?? '입금' : null, merchant: incoming ? null : party ?? '출금·결제');
}
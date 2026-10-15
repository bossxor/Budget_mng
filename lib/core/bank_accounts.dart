const bankNames = <String, String>{
  'nh': 'NH농협은행',
  'nh_local': '지역농축협',
  'kb': 'KB국민은행',
  'shinhan': '신한은행',
  'hana': '하나은행',
  'woori': '우리은행',
  'ibk': 'IBK기업은행',
  'kakao': '카카오뱅크',
  'toss': '토스뱅크',
  'kbank': '케이뱅크',
  'sc': 'SC제일은행',
  'citi': '한국씨티은행',
  'im': 'iM뱅크',
  'busan': '부산은행',
  'kyongnam': '경남은행',
  'gwangju': '광주은행',
  'jeonbuk': '전북은행',
  'jeju': '제주은행',
  'suhyup': '수협은행',
  'mg': '새마을금고',
  'cu': '신협',
  'post': '우체국',
};

const _bankAliases = <String, String>{
  'NH농협은행': 'nh',
  'NH농협': 'nh',
  '농협은행': 'nh',
  '농협': 'nh',
  '지역농축협': 'nh_local',
  '농축협': 'nh_local',
  'KB국민은행': 'kb',
  '국민은행': 'kb',
  'KB국민': 'kb',
  '국민': 'kb',
  '신한은행': 'shinhan',
  '신한': 'shinhan',
  '하나은행': 'hana',
  '하나': 'hana',
  '우리은행': 'woori',
  '우리': 'woori',
  'IBK기업은행': 'ibk',
  '기업은행': 'ibk',
  '기업': 'ibk',
  '카카오뱅크': 'kakao',
  '토스뱅크': 'toss',
  '케이뱅크': 'kbank',
  'SC제일은행': 'sc',
  '제일은행': 'sc',
  '한국씨티은행': 'citi',
  '씨티은행': 'citi',
  'iM뱅크': 'im',
  '대구은행': 'im',
  '부산은행': 'busan',
  '경남은행': 'kyongnam',
  '광주은행': 'gwangju',
  '전북은행': 'jeonbuk',
  '제주은행': 'jeju',
  '수협은행': 'suhyup',
  '수협': 'suhyup',
  '새마을금고': 'mg',
  '신협': 'cu',
  '우체국': 'post',
};

String normalizeAccountNumber(String value) {
  if (!RegExp(r'^[0-9\s-]+$').hasMatch(value)) {
    throw ArgumentError('계좌번호는 숫자와 하이픈으로 입력해 주세요.');
  }
  final digits = value.replaceAll(RegExp(r'[\s-]'), '');
  if (digits.length < 6 || digits.length > 20) {
    throw ArgumentError('계좌번호의 길이를 확인해 주세요.');
  }
  return digits;
}

String maskedAccountNumber(String? value) {
  if (value == null || value.isEmpty) return '';
  return '•••• ${value.length <= 4 ? value : value.substring(value.length - 4)}';
}

/// 은행+전체 번호가 있는 경우만 식별한다. 마스킹/끝자리만으로는 자동 연결하지 않는다.
({String bank, String number})? parseAccountReference(String value) {
  final text = value.replaceAll(RegExp(r'[\s()]'), '').toLowerCase();
  final aliases = _bankAliases.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final alias in aliases) {
    if (!text.startsWith(alias.toLowerCase())) continue;
    final rest = text.substring(alias.length);
    try {
      return (bank: _bankAliases[alias]!, number: normalizeAccountNumber(rest));
    } on ArgumentError {
      return null;
    }
  }
  return null;
}

class BankAccountDraft {
  const BankAccountDraft({
    required this.bank,
    required this.number,
    this.label = '',
    this.role = 'unset',
    this.existingKey,
  });
  final String bank, number, label, role;
  final String? existingKey;
}

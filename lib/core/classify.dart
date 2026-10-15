import 'parsers.dart';
import 'bank_accounts.dart';

/// 본인 판정에 쓰는 사용자 입력값 (온보딩/설정에서 등록).
class Identity {
  Identity({Set<String>? names, Set<String>? accountAliases})
      : names = names ?? {},
        accountAliases = accountAliases ?? {};
  final Set<String> names;
  final Set<String> accountAliases;

  bool _isOwnName(String s) {
    for (final n in names) {
      if (s == n) return true;
      if (n.length >= 2 &&
          s.length == n.length &&
          s[0] == n[0] &&
          s[s.length - 1] == n[n.length - 1] &&
          s.substring(1, s.length - 1).split('').every((c) => c == '*')) {
        return true;
      }
    }
    return false;
  }

  /// 상대가 내 계좌/본인인지.
  bool isOwn(String? s) {
    if (s == null || s.isEmpty) return false;
    final reference=parseAccountReference(s);
    if(reference!=null && accountAliases.any((a)=>parseAccountReference(a)==reference))return true;
    return s.startsWith('내 ') ||
        RegExp(r'^.+\(\d{4}\)$').hasMatch(s) || // 카카오뱅크 내 상품
        accountAliases.contains(s) ||
        _isOwnName(s);
  }
}

const seedRules = <String, List<String>>{
  '카페': ['스타벅스', '이디야', '메가커피', '커피브레이크', '투썸', '컴포즈', '할리스'],
  '편의점': ['GS25', 'CU', '세븐일레븐', '이마트24'],
  '교통': ['티머니', '한국철도공사', '코레일', '택시', '카카오T', '버스', '지하철'],
  '배달': ['배달의민족', '우아한형제들', '쿠팡이츠', '요기요'],
  '쇼핑': ['쿠팡', '이마트', '11번가', '지마켓', '올리브영', '와디즈'],
  '구독': ['넷플릭스', '유튜브', '스포티파이', '왓챠', '멜론'],
  '식비': ['식당', '치킨', '맥도날드', '버거킹', '롯데리아', '김밥', '국밥'],
  '의료': ['병원', '약국', '의원', '치과'],
};

/// 학습된 규칙(사용자가 바꾼 분류)을 먼저, 그다음 가장 긴 시드 키워드.
String? categorize(String? name, [Map<String, String> learned = const {}]) {
  if (name == null) return null;
  for (final e in learned.entries) {
    if (name.contains(e.key)) return e.value;
  }
  String? best;
  var bestLen = 0;
  seedRules.forEach((cat, kws) {
    for (final k in kws) {
      if (name.contains(k) && k.length > bestLen) {
        best = cat;
        bestLen = k.length;
      }
    }
  });
  return best;
}

/// 파싱 결과에 이체 판정과 분류를 적용한다.
ParsedTx classify(ParsedTx t, Identity me,
    [Map<String, String> learned = const {}]) {
  if (t.type == 'income' || t.type == 'expense') {
    final explicitParty=t.counterparty??
      (t.source=='auto' && parseAccountReference(t.merchant??'')!=null?t.merchant:null);
    if (me.isOwn(explicitParty)) t.type = 'transfer';
    // 카드대금은 카드 결제와 이중 집계되므로 이체 처리.
    if (t.type != 'transfer' &&
        t.merchant == null &&
        RegExp(r'카드대금|카드 대금').hasMatch(t.counterparty ?? '')) {
      t.type = 'transfer';
    }
  }
  if (t.type == 'expense') {
    t.category = categorize(t.merchant ?? t.counterparty, learned) ??
        (t.via != null ? '송금' : null);
  }
  return t;
}

import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/core/parsers.dart';
void main() {
  final date = DateTime(2026, 10, 15, 12);
  test('NH 실측 줄 구조에서 거래 금액과 잔액·계좌를 따로 읽는다', () {
    final tx = parseNotification('입출금 알림\n농협 입금123,456원\n10/15 11:30 123-****-5678-90 홍길동 잔액654,321원', date)!;
    expect(tx.source, 'nhallone'); expect(tx.type, 'income');
    expect(tx.amount, 123456); expect(tx.balance, 654321);
    expect(tx.account, '농협 123-****-5678-90');
    expect(tx.counterparty, '홍길동');
    expect(tx.occurredAt, DateTime(2026, 10, 15, 11, 30));
  });
  test('NH 출금과 미등록 앱의 방향/잔액을 구분한다', () {
    expect(parseNotification('농협 출금12,000원\n10/15 10:10 123-****-5678-90 식당 잔액20,000원', date)!.type, 'expense');
    final tx = parseNotification('입출금 알림\n잔액: 900,000원\n출금: 20,000원\n계좌: 생활비 통장\n내용: 마트', date)!;
    expect(tx.amount, 20000); expect(tx.type, 'expense'); expect(tx.balance, 900000);
    expect(tx.account, '생활비 통장');
    expect(parseNotification('9,000원이 입금되었습니다', date)!.amount, 9000);
  });
  test('금융 광고·인증·예정·요청·잔액만 있는 알림은 거래로 만들지 않는다', () {
    for (final raw in ['(광고) 입금 5,000원 혜택', '출금 예정 5,000원', '결제 예정 9,000원',
      '입금 5,000원 부탁합니다', '입금 5,000원 인증번호 123456', '잔액 30,000원',
      '출금 5,000원 실패', '입금 5,000원\n출금 3,000원', '결제 5,000원 취소']) {
      expect(parseNotification(raw, date), isNull, reason: raw);
    }
  });
}

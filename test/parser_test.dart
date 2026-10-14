import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/core/classify.dart';
import 'package:jumeoni/core/parsers.dart';

void main() {
  final samples =
      jsonDecode(File('parser_samples.json').readAsStringSync())['samples']
          as List;
  final me = Identity(names: {'홍길동'});

  for (var i = 0; i < samples.length; i++) {
    final s = samples[i] as Map<String, dynamic>;
    test('sample $i ${s['source']}', () {
      final tx = parseNotification(
          s['text'] as String, DateTime.parse(s['received_at'] as String));
      expect(tx, isNotNull, reason: s['text'] as String);
      classify(tx!, me);
      final got = tx.toMap();
      (s['expect'] as Map<String, dynamic>).forEach((k, v) {
        expect(got[k], v, reason: k);
      });
    });
  }

  test('unrelated text is not parsed', () {
    expect(parseNotification('새 메시지가 도착했습니다', DateTime(2026, 10, 13)), isNull);
  });

  test('year rolls back for future dates', () {
    final tx = parseNotification(
        '삼성1234승인 홍*동\n1,000원 일시불\n12/31 23:50 테스트\n누적1,000원',
        DateTime(2027, 1, 1, 0, 5))!;
    expect(tx.occurredAt.year, 2026);
  });

  test('템플릿 없는 알림에서 금액·방향 짐작', () {
    var g = guessFromText('[KB국민] 홍길동님 10/14 12:30\n출금 12,300원 스타벅스\n잔액 50,000원');
    expect(g.amount, 12300);
    expect(g.type, 'expense');
    expect(g.title, '[KB국민] 홍길동님 10/14 12');
    g = guessFromText('신한 입금 1,000,000 월급');
    expect(g.amount, 1000000);
    expect(g.type, 'income');
    g = guessFromText('금액 정보 없음');
    expect(g.amount, isNull);
  });
}

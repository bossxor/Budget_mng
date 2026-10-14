import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jumeoni/app_state.dart';
import 'package:jumeoni/ui/theme.dart';

void main() {
  test('번들 글자체는 pubspec family 이름을 쓰고 기존 스타일은 유지한다', () {
    final p = fontStyle('pretendard', const TextStyle(fontSize: 16, fontWeight: FontWeight.w700));
    expect(p.fontFamily, 'Pretendard');
    expect(p.fontSize, 16);
    expect(p.fontWeight, FontWeight.w700);
    expect(fontStyle('nanumsquare').fontFamily, 'NanumSquare');
  });

  test('글자체 선택지마다 번들 또는 Google Fonts 이름이 있다', () {
    for (final k in fontChoices.keys) {
      expect(bundledFonts.containsKey(k) || fontGoogleNames.containsKey(k), isTrue, reason: k);
    }
  });
}

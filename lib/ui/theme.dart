import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_state.dart';

/// 글자체 키에 맞는 스타일. 번들 글자체는 바로, 나머지는 Google Fonts로.
TextStyle fontStyle(String key, [TextStyle? base]) {
  final bundled = bundledFonts[key];
  if (bundled != null) {
    return (base ?? const TextStyle()).copyWith(fontFamily: bundled);
  }
  return GoogleFonts.getFont(fontGoogleNames[key] ?? 'Noto Sans KR', textStyle: base);
}

/// 주머니 디자인 토큰. 따뜻한 배경 + 둥근 카드 + 파스텔 카테고리 색.
class Dsn {
  static const blue = Color(0xFF4F7CFF);
  static const blueDeep = Color(0xFF3A5FE0);
  static const coral = Color(0xFFFF6B6B); // 지출
  static const mint = Color(0xFF1FB57A); // 입금
  static const amber = Color(0xFFFFB020); // 확인 필요

  static const lightBg = Color(0xFFF5F7FF);
  static const darkBg = Color(0xFF101423);

  static const _cat = {
    '식비': Color(0xFFFF9F43),
    '카페': Color(0xFFB08968),
    '편의점': Color(0xFF2ECC71),
    '배달': Color(0xFFFF6B6B),
    '교통': Color(0xFF4FA3FF),
    '쇼핑': Color(0xFFB07CFF),
    '구독': Color(0xFFFF6BA8),
    '의료': Color(0xFF1ABC9C),
    '생활': Color(0xFF5BC0BE),
    '문화/여가': Color(0xFFF39C12),
    '경조사': Color(0xFFE17055),
    '송금': Color(0xFF5C7CFA),
  };

  static Color cat(String? c) => _cat[c] ?? const Color(0xFF94A3B8);

  static const _role = {
    'living': Color(0xFF4F7CFF),
    'saving': Color(0xFF1FB57A),
    'travel': Color(0xFFFF9F43),
    'bills': Color(0xFFB07CFF),
    'income': Color(0xFF1ABC9C),
    'emergency': Color(0xFFFF6B6B),
  };
  static Color role(String r) => _role[r] ?? const Color(0xFF94A3B8);

  static ThemeData theme(Brightness b, TextTheme Function(TextTheme) font) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: blue, brightness: b).copyWith(
      primary: dark ? const Color(0xFF8AA6FF) : blue,
      error: coral,
      surface: dark ? const Color(0xFF1A2036) : Colors.white,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? darkBg : lightBg,
    );
    return base.copyWith(
      textTheme: font(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? darkBg : lightBg,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 12),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: blue.withValues(alpha: dark ? 0.28 : 0.14),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: BorderSide.none,
        backgroundColor:
            dark ? const Color(0xFF252C47) : const Color(0xFFEAEFFF),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF252C47) : const Color(0xFFEFF2FF),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: blue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}

/// 카테고리별 파스텔 원형 아이콘.
class RoundIcon extends StatelessWidget {
  const RoundIcon(this.icon, this.color, {super.key, this.size = 44});
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(size * 0.36),
        ),
        child: Icon(icon, color: color, size: size * 0.5),
      );
}

/// 이름 이니셜 아바타 (정산 참여자).
class InitialAvatar extends StatelessWidget {
  const InitialAvatar(this.name, {super.key, this.size = 40});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) {
    final colors = [
      const Color(0xFF4F7CFF),
      const Color(0xFFFF9F43),
      const Color(0xFF1FB57A),
      const Color(0xFFB07CFF),
      const Color(0xFFFF6BA8),
      const Color(0xFF1ABC9C),
    ];
    final c = colors[name.runes.fold<int>(0, (a, r) => a + r) % colors.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.18), shape: BoxShape.circle),
      child: Text(name.isEmpty ? '?' : name.characters.first,
          style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: size * 0.4)),
    );
  }
}

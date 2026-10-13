import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_state.dart';
import 'data/repo.dart';
import 'lock.dart';
import 'ui/screens.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(await Repo.open());
  await state.load();
  runApp(BudgetApp(state));
}

const _googleName = {
  'noto': 'Noto Sans KR',
  'nanum': 'Nanum Gothic',
  'gowun': 'Gowun Dodum',
  'plex': 'IBM Plex Sans KR',
  'serif': 'Noto Serif KR',
};

/// 선택한 폰트를 Material 텍스트 스타일 전체에 적용한다.
TextTheme _fontTheme(String key, TextTheme t) {
  final name = _googleName[key] ?? 'Noto Sans KR';
  TextStyle? f(TextStyle? s) =>
      s == null ? null : GoogleFonts.getFont(name, textStyle: s);
  return TextTheme(
    displayLarge: f(t.displayLarge),
    displayMedium: f(t.displayMedium),
    displaySmall: f(t.displaySmall),
    headlineLarge: f(t.headlineLarge),
    headlineMedium: f(t.headlineMedium),
    headlineSmall: f(t.headlineSmall),
    titleLarge: f(t.titleLarge),
    titleMedium: f(t.titleMedium),
    titleSmall: f(t.titleSmall),
    bodyLarge: f(t.bodyLarge),
    bodyMedium: f(t.bodyMedium),
    bodySmall: f(t.bodySmall),
    labelLarge: f(t.labelLarge),
    labelMedium: f(t.labelMedium),
    labelSmall: f(t.labelSmall),
  );
}

class BudgetApp extends StatefulWidget {
  const BudgetApp(this.state, {super.key});
  final AppState state;
  @override
  State<BudgetApp> createState() => _BudgetAppState();
}

class _BudgetAppState extends State<BudgetApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // 앱으로 돌아올 때마다 그동안 쌓인 알림을 처리한다.
    if (s == AppLifecycleState.paused) widget.state.appPaused();
    if (s == AppLifecycleState.resumed) {
      widget.state.appResumed();
      widget.state.refresh();
    }
  }

  ThemeData _theme(Brightness b) =>
      Dsn.theme(b, (t) => _fontTheme(widget.state.font, t));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => MaterialApp(
        title: '주머니',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(widget.state.textScale)),
          child: child!,
        ),
        home: LockGate(widget.state, child: Shell(widget.state)),
      ),
    );
  }
}

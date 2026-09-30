import 'package:flutter/material.dart';

class AppPalette {
  final String name;
  final Color bg;
  final Color panel;
  final Color panelAlt;
  final Color border;
  final Color text;
  final Color textDim;
  final Color accent;
  final Color accent2;
  final Color ok;
  final Color bad;
  final Color warn;
  final Color chartBg;

  const AppPalette({
    required this.name,
    required this.bg,
    required this.panel,
    required this.panelAlt,
    required this.border,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.accent2,
    required this.ok,
    required this.bad,
    required this.warn,
    required this.chartBg,
  });

  static const dark = AppPalette(
    name: 'dark',
    bg: Color(0xFF0F1419),
    panel: Color(0xFF1A2028),
    panelAlt: Color(0xFF232B36),
    border: Color(0xFF2E3845),
    text: Color(0xFFE6EDF3),
    textDim: Color(0xFF8B96A5),
    accent: Color(0xFF00D9FF),
    accent2: Color(0xFF7C3AED),
    ok: Color(0xFF22C55E),
    bad: Color(0xFFEF4444),
    warn: Color(0xFFF59E0B),
    chartBg: Color(0xFF131A22),
  );

  static const light = AppPalette(
    name: 'light',
    bg: Color(0xFFF5F7FA),
    panel: Color(0xFFFFFFFF),
    panelAlt: Color(0xFFEEF2F7),
    border: Color(0xFFD0D7E2),
    text: Color(0xFF1A2028),
    textDim: Color(0xFF64748B),
    accent: Color(0xFF0284C7),
    accent2: Color(0xFF7C3AED),
    ok: Color(0xFF16A34A),
    bad: Color(0xFFDC2626),
    warn: Color(0xFFD97706),
    chartBg: Color(0xFFFFFFFF),
  );
}

class AppTheme {
  static ThemeData from(AppPalette p) {
    final base = p.name == 'dark' ? ThemeData.dark() : ThemeData.light();
    return base.copyWith(
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      cardColor: p.panel,
      dividerColor: p.border,
      colorScheme: base.colorScheme.copyWith(
        primary: p.accent,
        secondary: p.accent2,
        surface: p.panel,
        onSurface: p.text,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: p.text,
        displayColor: p.text,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: MaterialStateProperty.all(p.border),
        radius: const Radius.circular(6),
        thickness: MaterialStateProperty.all(10),
      ),
      
      tabBarTheme: TabBarThemeData(
        labelColor: p.accent,
        unselectedLabelColor: p.textDim,
        indicatorColor: p.accent,
      ),
    );
  }
}

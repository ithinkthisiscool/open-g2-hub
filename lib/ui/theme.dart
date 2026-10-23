/// App themes like the PC hub's Appearance setting: Automatic / Light / Dark, plus the two retro
/// looks (Phosphor green, Amber CRT: black, monospace, glowing text), with a user accent colour.
library;

import 'package:flutter/material.dart';

const Map<String, String> themeNames = {
  'system': 'Automatic (match system)',
  'light': 'Light',
  'dark': 'Dark',
  'green': 'Phosphor green (retro)',
  'amber': 'Amber CRT (retro)',
};

/// Accent choices (ARGB).
const Map<String, int> accentColors = {
  'Teal': 0xFF2E7D6B,
  'Blue': 0xFF0A84FF,
  'Indigo': 0xFF4F5BD5,
  'Purple': 0xFF8E44AD,
  'Pink': 0xFFD81B60,
  'Red': 0xFFE53935,
  'Orange': 0xFFF57C00,
  'Yellow': 0xFFF9A825,
  'Green': 0xFF43A047,
  'Graphite': 0xFF555555,
};

ThemeMode themeModeFor(String theme) => switch (theme) {
  'light' => ThemeMode.light,
  'dark' || 'green' || 'amber' => ThemeMode.dark,
  _ => ThemeMode.system,
};

ThemeData buildTheme(String theme, int accent, Brightness b) {
  if (theme == 'green' || theme == 'amber') return _retro(theme == 'green');
  final scheme = ColorScheme.fromSeed(seedColor: Color(accent), brightness: b);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 4)),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
  );
}

ThemeData _retro(bool green) {
  final text = green ? const Color(0xFF4DFF7A) : const Color(0xFFFFB000);
  final dim = green ? const Color(0xFF5FB87F) : const Color(0xFFC4893A);
  final panel = green ? const Color(0xFF061006) : const Color(0xFF120B02);
  final panel2 = green ? const Color(0xFF0A1A0A) : const Color(0xFF1C1204);
  final border = green ? const Color(0xFF1A5C1A) : const Color(0xFF6B4708);
  final scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: text,
    onPrimary: Colors.black,
    primaryContainer: panel2,
    onPrimaryContainer: text,
    secondary: dim,
    onSecondary: Colors.black,
    secondaryContainer: panel2,
    onSecondaryContainer: text,
    tertiary: green ? const Color(0xFF6FE3FF) : const Color(0xFF5FD7E8),
    onTertiary: Colors.black,
    error: const Color(0xFFFF6B6B),
    onError: Colors.black,
    surface: Colors.black,
    onSurface: text,
    onSurfaceVariant: dim,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: panel,
    surfaceContainer: panel,
    surfaceContainerHigh: panel2,
    surfaceContainerHighest: panel2,
    outline: border,
    outlineVariant: border,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, fontFamily: 'monospace', scaffoldBackgroundColor: Colors.black);
  final shadows = [Shadow(color: text.withValues(alpha: 0.35), blurRadius: 4)];
  return base.copyWith(
    textTheme: base.textTheme
        .apply(bodyColor: text, displayColor: text)
        .copyWith(
          headlineSmall: base.textTheme.headlineSmall?.copyWith(color: text, shadows: shadows, fontWeight: FontWeight.w700),
          titleLarge: base.textTheme.titleLarge?.copyWith(color: text, shadows: shadows),
        ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(3),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(3),
        borderSide: BorderSide(color: border),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: Colors.black, indicatorColor: panel2),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 4)),
  );
}

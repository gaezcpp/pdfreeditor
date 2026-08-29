import 'package:flutter/material.dart';

/// One seed colour, two brightnesses — Material 3 derives the rest.
abstract final class AppTheme {
  static const _seed = Color(0xFFB3261E);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // Height only. `Size.fromHeight` looks like it means "as wide as the
          // parent", but its width is double.infinity — which every button
          // then demands, crashing any Row or dialog action bar that offers
          // unbounded width. Buttons that should span the screen get that from
          // a stretching parent instead.
          minimumSize: const Size(64, 52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}

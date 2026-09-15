import 'package:flutter/material.dart';

// App-wide theming, ported from the PingPongTracker app. Public API (no leading
// underscores) so it can be shared across the app's multiple libraries.

// SharedPreferences keys for the theme controls.
const String kThemeModeKey = "themeMode";
const String kAppThemeKey = "appTheme";
const String kColorSwapKey = "colorSwap";

/// Colour theme, separate from the light/dark brightness.
enum AppTheme {
  blue,
  gray,
  sage,
  lavender,
  yellow,
  red,
  brown,
  pink,
  orange,
  teal,
  navy,
  magenta,
}

/// How each theme's two shades (a lighter and a darker tone of the same hue)
/// map to the top bar and the accent (text / toggles / sliders). Independent of
/// light/dark brightness, so the user controls it separately.
///   normal   - bar = lighter, accent = darker
///   reversed - bar = darker,  accent = lighter
///   allLight - both use the lighter shade
///   allDark  - both use the darker shade
enum ColorSwap { normal, reversed, allLight, allDark }

// App-wide theme mode + colour theme + colour-swap, driven by the Settings
// controls. Loaded before runApp so there's no flash of the wrong theme, then
// updated live (the MaterialApp listens to all three notifiers).
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.system,
);
final ValueNotifier<AppTheme> appThemeNotifier = ValueNotifier(AppTheme.blue);
final ValueNotifier<ColorSwap> colorSwapNotifier = ValueNotifier(
  ColorSwap.normal,
);

ThemeMode parseThemeMode(String? s) {
  switch (s) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

AppTheme parseAppTheme(String? s) {
  for (final v in AppTheme.values) {
    if (v.name == s) return v;
  }
  return AppTheme.blue;
}

ColorSwap parseColorSwap(String? s) {
  for (final v in ColorSwap.values) {
    if (v.name == s) return v;
  }
  return ColorSwap.normal;
}

/// The two canonical shades for each theme: a lighter tone and a darker tone of
/// the same hue, both independent of light/dark brightness. The colour-swap
/// setting decides which shade goes to the top bar and which to the accent.
({Color light, Color dark}) themeShades(AppTheme t) {
  switch (t) {
    case AppTheme.blue:
      return (light: const Color(0xFFA8D8F0), dark: const Color(0xFF3E6E8E));
    case AppTheme.gray:
      return (light: const Color(0xFFE4E4E6), dark: const Color(0xFF1F1F1F));
    case AppTheme.sage:
      return (light: const Color(0xFFA2EDBD), dark: const Color(0xFF3E7A5A));
    case AppTheme.lavender:
      return (light: const Color(0xFFCDBFF0), dark: const Color(0xFF6A5A9E));
    case AppTheme.yellow:
      return (light: const Color(0xFFEFE3A3), dark: const Color(0xFF7A6520));
    case AppTheme.red:
      return (light: const Color(0xFFF2B3AB), dark: const Color(0xFF8E3B34));
    case AppTheme.brown:
      return (light: const Color(0xFFE4C6A0), dark: const Color(0xFF5A4632));
    case AppTheme.pink:
      return (light: const Color(0xFFF4C4DB), dark: const Color(0xFF8E3C63));
    case AppTheme.orange:
      return (light: const Color(0xFFF8C69A), dark: const Color(0xFFA05A22));
    case AppTheme.teal:
      return (light: const Color(0xFFA6E1D9), dark: const Color(0xFF2D7D74));
    case AppTheme.navy:
      return (light: const Color(0xFFB2BEDE), dark: const Color(0xFF26356B));
    case AppTheme.magenta:
      return (light: const Color(0xFFF0AFE0), dark: const Color(0xFF9A2C82));
  }
}

/// Resolve the (top-bar, accent) colour pair for a theme under a swap mode.
(Color, Color) swapColors(AppTheme t, ColorSwap s) {
  final shades = themeShades(t);
  switch (s) {
    case ColorSwap.normal:
      return (shades.light, shades.dark);
    case ColorSwap.reversed:
      return (shades.dark, shades.light);
    case ColorSwap.allLight:
      return (shades.light, shades.light);
    case ColorSwap.allDark:
      return (shades.dark, shades.dark);
  }
}

/// Readable foreground (near-black or white) for text sitting on [c].
Color onColor(Color c) =>
    c.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

/// Build the ThemeData for a theme + swap + brightness.
ThemeData buildTheme(AppTheme t, ColorSwap s, Brightness b) {
  final (bar, accent) = swapColors(t, s);
  final Color seed = themeShades(t).dark;
  final ColorScheme base = t == AppTheme.gray
      ? ColorScheme.fromSeed(
          seedColor: seed,
          brightness: b,
          dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
        )
      : ColorScheme.fromSeed(seedColor: seed, brightness: b);
  final ColorScheme scheme = base.copyWith(
    primary: accent,
    onPrimary: onColor(accent),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: b == Brightness.dark
        ? const Color(0xFF0A0A0A)
        : null,
    appBarTheme: AppBarTheme(
      backgroundColor: bar,
      foregroundColor: onColor(bar),
    ),
  );
}

ThemeData lightTheme(AppTheme t, ColorSwap s) =>
    buildTheme(t, s, Brightness.light);

ThemeData darkTheme(AppTheme t, ColorSwap s) =>
    buildTheme(t, s, Brightness.dark);

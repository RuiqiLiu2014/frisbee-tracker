// Unit tests for pure (plugin-free) app logic. The full app pulls in BLE /
// storage plugins that aren't available in a plain widget test, so the smoke
// test here exercises the theme system instead.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/theme.dart';

void main() {
  test('parseAppTheme round-trips and falls back to blue', () {
    for (final t in AppTheme.values) {
      expect(parseAppTheme(t.name), t);
    }
    expect(parseAppTheme(null), AppTheme.blue);
    expect(parseAppTheme("nonsense"), AppTheme.blue);
  });

  test('buildTheme produces a ThemeData for every theme/swap/brightness', () {
    for (final t in AppTheme.values) {
      for (final s in ColorSwap.values) {
        final light = buildTheme(t, s, Brightness.light);
        final dark = buildTheme(t, s, Brightness.dark);
        expect(light.useMaterial3, isTrue);
        expect(dark.colorScheme.brightness, Brightness.dark);
      }
    }
  });
}

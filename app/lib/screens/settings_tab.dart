import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../settings.dart';
import '../theme.dart';

/// Settings tab. The Appearance + Theme section is a direct port of the
/// PingPongTracker settings page (same themes, order, and widget sizes), wired
/// to this app's shared notifiers. The whole app rebuilds when a notifier
/// changes (MaterialApp listens), so the swatches refresh without local state.
class SettingsTab extends StatelessWidget {
  final int storageBytes;
  const SettingsTab({super.key, required this.storageBytes});

  Future<void> _saveString(String key, String value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, value);
  }

  Future<void> _saveBool(String key, bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, value);
  }

  String _fmtBytes(int b) {
    if (b < 1024) return "$b B";
    if (b < 1024 * 1024) return "${(b / 1024).toStringAsFixed(1)} KB";
    return "${(b / (1024 * 1024)).toStringAsFixed(2)} MB";
  }

  // A split-circle swatch: left half = top-bar shade, right half = accent shade.
  Widget _themeSwatch(BuildContext context, AppTheme t) {
    final (bar, accent) = swapColors(t, colorSwapNotifier.value);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool selected = appThemeNotifier.value == t;
    return GestureDetector(
      onTap: () {
        appThemeNotifier.value = t; // repaints the whole app
        _saveString(kAppThemeKey, t.name);
      },
      child: Container(
        width: 54,
        height: 54,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : scheme.outlineVariant,
            width: selected ? 3 : 1.5,
          ),
        ),
        child: ClipOval(
          child: Row(
            children: [
              Expanded(child: Container(color: bar)),
              Expanded(child: Container(color: accent)),
            ],
          ),
        ),
      ),
    );
  }

  // The double-arrow button that cycles the four color-swap arrangements.
  Widget _colorSwapButton(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          onPressed: () {
            final next = ColorSwap.values[
                (colorSwapNotifier.value.index + 1) % ColorSwap.values.length];
            colorSwapNotifier.value = next; // repaints the whole app
            _saveString(kColorSwapKey, next.name);
          },
          icon: const Icon(Icons.autorenew),
          tooltip: "Cycle color arrangement",
        ),
        const SizedBox(height: 4),
        Text(
          _swapLabel(colorSwapNotifier.value),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  String _swapLabel(ColorSwap s) {
    switch (s) {
      case ColorSwap.normal:
        return "Normal";
      case ColorSwap.reversed:
        return "Swapped";
      case ColorSwap.allLight:
        return "Lighter";
      case ColorSwap.allDark:
        return "Darker";
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          "Appearance",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text("System")),
              ButtonSegment(value: ThemeMode.light, label: Text("Light")),
              ButtonSegment(value: ThemeMode.dark, label: Text("Dark")),
            ],
            selected: {themeModeNotifier.value},
            onSelectionChanged: (s) {
              final mode = s.first;
              themeModeNotifier.value = mode; // repaints the whole app
              _saveString(kThemeModeKey, mode.name);
            },
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          "Theme",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Grid of split-circle swatches, four per row, spread across the
            // width so the swap button sits alongside rather than stranded.
            Expanded(
              child: Column(
                children: [
                  for (int i = 0; i < AppTheme.values.length; i += 4)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 14),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (final t in AppTheme.values.skip(i).take(4))
                            _themeSwatch(context, t),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            _colorSwapButton(context),
          ],
        ),
        const Divider(height: 24),
        const Text(
          "Graphs",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: showAccelNotifier,
          builder: (context, v, _) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("Show accelerometer graph"),
            subtitle: const Text("The raw accelerometer (g) trace in each throw."),
            value: v,
            onChanged: (nv) {
              showAccelNotifier.value = nv;
              _saveBool(kShowAccelKey, nv);
            },
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: showGyroNotifier,
          builder: (context, v, _) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("Show gyroscope graph"),
            subtitle: const Text("The raw gyroscope (dps) trace in each throw."),
            value: v,
            onChanged: (nv) {
              showGyroNotifier.value = nv;
              _saveBool(kShowGyroKey, nv);
            },
          ),
        ),
        const Divider(height: 24),
        const Text(
          "Storage",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text("Saved throws use ${_fmtBytes(storageBytes)} of phone storage."),
        const SizedBox(height: 24),
        Center(
          child: Text(
            "Frisbee Tracker v$kAppVersion",
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

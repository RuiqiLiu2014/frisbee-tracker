import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../services/frisbee_ble.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/interactive_chart.dart';

/// Settings tab. The Appearance + Theme section is a direct port of the
/// PingPongTracker settings page (same themes, order, and widget sizes), wired
/// to this app's shared notifiers. The whole app rebuilds when a notifier
/// changes (MaterialApp listens), so the swatches refresh without local state.
class SettingsTab extends StatelessWidget {
  final int storageBytes;
  final FrisbeeBle ble;
  const SettingsTab({super.key, required this.storageBytes, required this.ble});

  Future<void> _saveString(String key, String value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, value);
  }

  Future<void> _saveBool(String key, bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, value);
  }

  Future<void> _saveInt(String key, int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(key, value);
  }

  // One checklist row (leading checkbox + graph name) in "Graphs to display",
  // matching the ping-pong tracker's `_graphToggle`.
  Widget _graphCheck(String name, ValueNotifier<bool> notifier, String prefKey) {
    return ValueListenableBuilder<bool>(
      valueListenable: notifier,
      builder: (context, v, _) => CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(name, style: const TextStyle(fontSize: 15)),
        value: v,
        onChanged: (nv) {
          final val = nv ?? false;
          notifier.value = val;
          _saveBool(prefKey, val);
        },
      ),
    );
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
        // Per-log chart checklist (mirrors the ping-pong tracker's "Graphs to
        // display": leading-checkbox rows rather than toggles).
        const Text(
          "Graphs to display",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        _graphCheck("Raw acceleration", showAccelNotifier, kShowAccelKey),
        _graphCheck("Raw gyroscope", showGyroNotifier, kShowGyroKey),
        const Divider(height: 24),
        // Throws-list + graph-hover behavior (ported from the ping-pong tracker).
        ValueListenableBuilder<bool>(
          valueListenable: alwaysShowLogsNotifier,
          builder: (context, v, _) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              "Always show logs list",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            subtitle: const Text(
              "Returning to the Throws tab shows the full list instead of the "
              "last-opened throw.",
            ),
            value: v,
            onChanged: (nv) {
              alwaysShowLogsNotifier.value = nv;
              _saveBool(kResetLogsKey, nv);
            },
          ),
        ),
        const Divider(height: 24),
        ValueListenableBuilder<bool>(
          valueListenable: hoverPersistsNotifier,
          builder: (context, v, _) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              "Persist graph hover",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            subtitle: const Text(
              "Keep the value readout on the graph after you lift your finger.",
            ),
            value: v,
            onChanged: (nv) {
              hoverPersistsNotifier.value = nv;
              _saveBool(kHoverPersistKey, nv);
            },
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          "Hover readout position",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          "Where the value box sits when you hover a graph.",
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<HoverReadoutPos>(
          valueListenable: hoverPosNotifier,
          builder: (context, pos, _) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<HoverReadoutPos>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: HoverReadoutPos.follow,
                  label: Text("Follow"),
                ),
                ButtonSegment(value: HoverReadoutPos.left, label: Text("Left")),
                ButtonSegment(
                  value: HoverReadoutPos.right,
                  label: Text("Right"),
                ),
                ButtonSegment(
                  value: HoverReadoutPos.adaptive,
                  label: Text("Adaptive"),
                ),
              ],
              selected: {pos},
              onSelectionChanged: (s) {
                hoverPosNotifier.value = s.first;
                _saveString(kHoverPosKey, s.first.name);
              },
            ),
          ),
        ),
        const Divider(height: 24),
        const Text(
          "Throw capture",
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        ValueListenableBuilder<int>(
          valueListenable: preRollMsNotifier,
          builder: (context, ms, _) {
            final clamped = ms
                .toDouble()
                .clamp(kMinPreRollMs.toDouble(), kMaxPreRollMs.toDouble());
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    "Pre-roll: ${(ms / 1000).toStringAsFixed(1)} s",
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  "How much windup the disc keeps before a throw is detected.",
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                Slider(
                  value: clamped,
                  min: kMinPreRollMs.toDouble(),
                  max: kMaxPreRollMs.toDouble(),
                  divisions:
                      ((kMaxPreRollMs - kMinPreRollMs) / kPreRollStepMs).round(),
                  label: "${(ms / 1000).toStringAsFixed(1)} s",
                  onChanged: (v) {
                    final snapped =
                        (v / kPreRollStepMs).round() * kPreRollStepMs;
                    preRollMsNotifier.value = snapped;
                  },
                  onChangeEnd: (v) {
                    final snapped =
                        (v / kPreRollStepMs).round() * kPreRollStepMs;
                    preRollMsNotifier.value = snapped;
                    _saveInt(kPreRollKey, snapped);
                    ble.sendPreRoll(snapped); // no-op while disconnected
                  },
                ),
              ],
            );
          },
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

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../frame.dart';
import '../models/throw_log.dart';
import '../services/frisbee_ble.dart';
import '../services/log_repository.dart';
import '../settings.dart';
import '../widgets/calibration_dialog.dart';
import '../widgets/interactive_chart.dart';
import '../widgets/rename_dialog.dart';
import 'settings_tab.dart';

// Throw labels offered in the connection tab (drive the FH-vs-BH data set).
const List<String> kThrowLabels = ["backhand", "forehand", "unlabeled"];

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  final FrisbeeBle _ble = FrisbeeBle();
  final LogRepository _repo = LogRepository();
  final List<ThrowLog> _logs = [];
  int _logSeq = 0;
  int _storageBytes = 0;
  String? _calibStatus; // null until we know; e.g. "Calibrated"
  List<double>? _calibFull; // current calibration [ax,ay,az,gxB,gyB,gzB], if any
  List<double>? _calibDown; // its gravity/"down" vector [ax,ay,az] (for live tilt)
  ThrowLog? _openLog; // non-null => Logs tab shows the detail view
  late final TabController _tab;
  StreamSubscription<ReceivedThrow>? _throwSub;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _ble.addListener(_onBleChanged);
    _throwSub = _ble.throws.listen(_onThrowReceived);
    _loadLogs();
    _loadCalibStatus();
    _loadLabel();
    _loadPreRoll();
  }

  Future<void> _loadPreRoll() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(kPreRollKey) ?? kDefaultPreRollMs;
    preRollMsNotifier.value = ms;
    // Seed the BLE service so it re-sends the right value on connect (the write
    // itself no-ops while disconnected).
    _ble.sendPreRoll(ms);
  }

  Future<void> _loadCalibStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(kCalibKey);
    List<double>? full;
    if (s != null) {
      final p = s.split(',').map(double.tryParse).toList();
      if (p.length >= 6 && !p.sublist(0, 6).contains(null)) {
        full = p.sublist(0, 6).cast<double>();
      }
    }
    if (!mounted) return;
    setState(() {
      _calibStatus = s != null ? "Calibrated" : "Not calibrated";
      _calibFull = full;
      _calibDown = full?.sublist(0, 3);
    });
  }

  Future<void> _loadLabel() async {
    final prefs = await SharedPreferences.getInstance();
    final l = prefs.getString(kLabelKey);
    if (l != null && kThrowLabels.contains(l)) _ble.sendLabel(l);
  }

  void _selectLabel(String l) {
    _ble.sendLabel(l);
    SharedPreferences.getInstance().then((p) => p.setString(kLabelKey, l));
  }

  // Tilt of the current accel vector from the calibrated "flat" reference (or
  // the sensor z-axis if not yet calibrated), in degrees.
  double _tiltDeg(double ax, double ay, double az) {
    final ref = _calibDown ?? const [0.0, 0.0, 1.0];
    final dot = ax * ref[0] + ay * ref[1] + az * ref[2];
    final ma = math.sqrt(ax * ax + ay * ay + az * az);
    final mr = math.sqrt(ref[0] * ref[0] + ref[1] * ref[1] + ref[2] * ref[2]);
    if (ma == 0 || mr == 0) return 0;
    final c = (dot / (ma * mr)).clamp(-1.0, 1.0);
    return 57.2958 * math.acos(c);
  }

  Future<void> _openCalibration() async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CalibrationDialog(ble: _ble),
    );
    _loadCalibStatus();
  }

  @override
  void dispose() {
    _throwSub?.cancel();
    _ble.removeListener(_onBleChanged);
    _ble.dispose();
    _tab.dispose();
    super.dispose();
  }

  void _onBleChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadLogs() async {
    final res = await _repo.loadAll();
    final prefs = await SharedPreferences.getInstance();
    final persistedSeq = prefs.getInt(kLogSeqKey) ?? 0;
    if (!mounted) return;
    setState(() {
      _logs
        ..clear()
        ..addAll(res.logs);
      _logSeq = math.max(persistedSeq, res.maxId);
    });
    _refreshStorage();
  }

  Future<void> _onThrowReceived(ReceivedThrow r) async {
    _logSeq++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kLogSeqKey, _logSeq);
    // Rotate the raw board-frame samples into the canonical disc frame (z = disc
    // normal) using the calibration active at capture, then store the rotated
    // floats. Rotation preserves magnitude, so the peaks carry over unchanged.
    // The calib is baked in too, so the raw board frame stays recoverable.
    final discAxes = toDiscFrame(r.axes, r.count, _calibFull);
    final log = ThrowLog(
      id: _logSeq,
      throwId: r.throwId,
      timestamp: DateTime.now(),
      t: r.t,
      axes: discAxes,
      count: r.count,
      durationSec: r.count > 0 ? r.t[r.count - 1] : 0,
      sampleRateHz: r.sampleRateHz,
      droppedSamples: r.droppedSamples,
      peakAccelG: r.peakAccelG,
      peakGyroDps: r.peakGyroDps,
      name: "",
      throwClass: r.label,
      calib: _calibFull, // bake in the calibration that was active at capture
    );
    await _repo.persist(log);
    if (!mounted) return;
    setState(() => _logs.insert(0, log));
    _refreshStorage();
  }

  Future<void> _refreshStorage() async {
    final bytes = await _repo.storageBytes();
    if (mounted && bytes != _storageBytes) {
      setState(() => _storageBytes = bytes);
    }
  }

  Future<void> _deleteLog(ThrowLog log) async {
    await _repo.delete(log);
    if (!mounted) return;
    setState(() {
      _logs.removeWhere((l) => l.id == log.id);
      if (_openLog?.id == log.id) _openLog = null;
    });
    _refreshStorage();
  }

  /// Ensure [desired] is unique among the *other* logs by appending " (1)",
  /// " (2)", ... to the newest / just-renamed one when it collides. Blank names
  /// are left as-is (they display as "Throw #id", already unique). [excludeId]
  /// skips the log being renamed so it never clashes with itself.
  String _uniqueName(String desired, {int? excludeId}) {
    final base = desired.trim();
    if (base.isEmpty) return base;
    bool taken(String candidate) =>
        _logs.any((l) => l.id != excludeId && l.name == candidate);
    if (!taken(base)) return base;
    int n = 1;
    while (taken('$base ($n)')) {
      n++;
    }
    return '$base ($n)';
  }

  Future<void> _renameLog(ThrowLog log) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) =>
          RenameDialog(initial: log.name, hint: "Throw #${log.id}"),
    );
    if (result == null) return;
    log.name = _uniqueName(result, excludeId: log.id);
    await _repo.persist(log);
    if (mounted) setState(() {});
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete all throws?"),
        content: Text("This removes all ${_logs.length} saved throws."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final log in List<ThrowLog>.from(_logs)) {
      await _repo.delete(log);
    }
    if (!mounted) return;
    setState(() {
      _logs.clear();
      _openLog = null;
    });
    _refreshStorage();
  }

  // =========================================================================
  // Build
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _openLog == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _openLog != null) setState(() => _openLog = null);
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text("Frisbee Tracker"),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                "v$kAppVersion",
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(icon: Icon(Icons.bluetooth), text: "Connect"),
            Tab(icon: Icon(Icons.list_alt), text: "Throws"),
            Tab(icon: Icon(Icons.settings), text: "Settings"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildConnectTab(),
          _buildThrowsTab(),
          SettingsTab(storageBytes: _storageBytes, ble: _ble),
        ],
      ),
      ),
    );
  }

  // ---- Connect tab ----
  Widget _buildConnectTab() {
    final connected = _ble.isConnected;
    final active = connected;
    final last = _logs.isNotEmpty ? _logs.first : null;
    final scheme = Theme.of(context).colorScheme;
    final Color dim = Theme.of(context).disabledColor;

    // Last-throw readouts reflect the most recent stored throw and stay shown
    // whether or not we're connected (it's historical data), graying only when
    // there are no throws yet.
    final String typeText = last != null ? last.throwClass : "—";
    final String spinText = last != null
        ? "${(last.peakGyroDps / 360).toStringAsFixed(1)} rev/s"
        : "0 rev/s";
    final String accelText = last != null
        ? "${last.peakAccelG.toStringAsFixed(1)} g"
        : "0 g";
    final String flightText = last != null
        ? "${last.durationSec.toStringAsFixed(2)} s"
        : "0 s";
    final String sampleText = last != null
        ? "${last.count}"
              "${last.droppedSamples > 0 ? " (${last.droppedSamples} dropped)" : ""}"
        : "0";

    // Live readouts (current tilt + accel magnitude) come from the ~20 Hz idle
    // stream and gray out when disconnected / before the first packet arrives.
    final bool haveLive = _ble.hasLive;
    final double liveAccelG = haveLive
        ? math.sqrt(
            _ble.liveAx! * _ble.liveAx! +
                _ble.liveAy! * _ble.liveAy! +
                _ble.liveAz! * _ble.liveAz!,
          )
        : 0;
    final String liveAccelText = haveLive
        ? "${liveAccelG.toStringAsFixed(2)} g"
        : "—";
    final String liveTiltText = haveLive
        ? "${_tiltDeg(_ble.liveAx!, _ble.liveAy!, _ble.liveAz!).toStringAsFixed(0)}°"
        : "—";

    return Column(
      children: [
        // Info scrolls in the middle; the action buttons stay pinned at the
        // bottom so they never overflow and are always in reach.
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Column(
              children: [
                Text(
                  _ble.status,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: connected ? Colors.green : Colors.red,
                  ),
                ),
                if (connected && _ble.firmwareVersion.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    "Firmware ${_ble.firmwareVersion}",
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                // Battery + signal share one row to save vertical space.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _batteryIndicator(
                      active ? _ble.batteryPct : 0,
                      active: active,
                    ),
                    const SizedBox(width: 18),
                    Text(
                      active && _ble.rssi != null
                          ? "Signal: ${_ble.rssi} dBm"
                          : "Signal: —",
                      style: TextStyle(
                        fontSize: 14,
                        color: active ? scheme.onSurfaceVariant : dim,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Live (current) — updates ~20 Hz while connected.
                Row(
                  children: [
                    Expanded(child: _readout("Tilt", liveTiltText, connected)),
                    Expanded(child: _readout("Accel", liveAccelText, connected)),
                  ],
                ),
                const SizedBox(height: 16),
                _readout("Last throw type", typeText, last != null),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _readout("Peak spin", spinText, last != null),
                    ),
                    Expanded(
                      child: _readout("Peak accel", accelText, last != null),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _readout("Flight time", flightText, last != null),
                    ),
                    Expanded(
                      child: _readout("Samples", sampleText, last != null),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  "Label (next throw)",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  children: [
                    for (final l in kThrowLabels)
                      ChoiceChip(
                        label: Text(l),
                        selected: _ble.label == l,
                        onSelected: (_) => _selectLabel(l),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => _ble.injectSyntheticThrow(),
                  child: const Text("add test throw (debug)"),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                // Single-pose calibration (disc flat on the floor). Opens the
                // wizard, which asks the disc for a one-shot still reading.
                onPressed: connected ? _openCalibration : null,
                icon: const Icon(Icons.explore),
                label: const Text("Calibrate"),
              ),
              if (_calibStatus != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _calibStatus!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              ElevatedButton(
                // Start scan when idle; from any other state this button stops
                // (which sets the manual-stop flag, so no auto-reconnect).
                onPressed: _ble.state == ConnState.disconnected
                    ? _ble.startScan
                    : _ble.disconnect,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 15,
                  ),
                ),
                child: Text(
                  switch (_ble.state) {
                    ConnState.connected => "Disconnect",
                    ConnState.scanning => "Stop scanning",
                    ConnState.connecting => "Connecting…",
                    ConnState.disconnected => "Start scan",
                  },
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _readout(String label, String value, bool active) {
    final scheme = Theme.of(context).colorScheme;
    final Color labelColor =
        active ? scheme.onSurfaceVariant : Theme.of(context).disabledColor;
    final Color? valueColor = active ? null : Theme.of(context).disabledColor;
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(fontWeight: FontWeight.bold, color: labelColor),
        ),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 20, color: valueColor)),
      ],
    );
  }

  // Compact battery gauge (ping-pong style). Grays out when disconnected.
  Widget _batteryIndicator(int pct, {bool active = true}) {
    final p = pct.clamp(0, 100);
    final Color disabled = Theme.of(context).disabledColor;
    final Color fill = !active
        ? disabled
        : (p <= 20 ? Colors.red : (p <= 50 ? Colors.orange : Colors.green));
    final Color textColor = !active
        ? disabled
        : (p <= 20
              ? Colors.red.shade700
              : (p <= 50 ? Colors.orange.shade800 : Colors.green.shade700));
    final Color outline =
        active ? Theme.of(context).colorScheme.onSurfaceVariant : disabled;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          "$p%",
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
        ),
        const SizedBox(width: 5),
        Container(
          width: 32,
          height: 15,
          padding: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            border: Border.all(color: outline, width: 1.2),
            borderRadius: BorderRadius.circular(3),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: p / 100.0,
            child: Container(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ),
        ),
        Container(
          width: 2.5,
          height: 6,
          decoration: BoxDecoration(
            color: outline,
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(2),
              bottomRight: Radius.circular(2),
            ),
          ),
        ),
      ],
    );
  }

  // ---- Throws tab (list or detail) ----
  Widget _buildThrowsTab() {
    if (_openLog != null) return _buildDetail(_openLog!);
    if (_logs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "No throws yet.\nConnect and throw, or add a test throw.",
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Text("${_logs.length} throws"),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _repo.shareLogs(_logs),
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text("Export all"),
              ),
              TextButton.icon(
                onPressed: _deleteAll,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text("Delete all"),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _logs.length,
            itemBuilder: (_, i) => _logRow(_logs[i]),
          ),
        ),
      ],
    );
  }

  Widget _logRow(ThrowLog log) {
    return ListTile(
      title: Text(log.displayName),
      subtitle: Text(
        "${log.throwClass} · ${log.count} samples · "
        "${log.durationSec.toStringAsFixed(2)} s · "
        "${log.sampleRateHz.toStringAsFixed(0)} Hz"
        "${log.droppedSamples > 0 ? " · ${log.droppedSamples} dropped" : ""}",
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v.startsWith('class:')) {
            _setLogClass(log, v.substring(6));
            return;
          }
          switch (v) {
            case 'rename':
              _renameLog(log);
              break;
            case 'export':
              _repo.shareLogs([log]);
              break;
            case 'delete':
              _deleteLog(log);
              break;
          }
        },
        itemBuilder: (_) => [
          // Class picker, kept in sync with the connection screen via kThrowLabels.
          for (final c in kThrowLabels)
            CheckedPopupMenuItem(
              value: 'class:$c',
              checked: log.throwClass == c,
              child: Text(c),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'rename', child: Text("Rename")),
          const PopupMenuItem(value: 'export', child: Text("Export")),
          const PopupMenuItem(value: 'delete', child: Text("Delete")),
        ],
      ),
      onTap: () => setState(() => _openLog = log),
    );
  }

  Future<void> _setLogClass(ThrowLog log, String cls) async {
    log.throwClass = cls;
    await _repo.persist(log);
    if (mounted) setState(() {});
  }

  Widget _buildDetail(ThrowLog log) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _openLog = null),
              ),
              Expanded(
                child: Text(
                  log.displayName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () => _renameLog(log),
              ),
              IconButton(
                icon: const Icon(Icons.ios_share),
                onPressed: () => _repo.shareLogs([log]),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteLog(log),
              ),
            ],
          ),
          _detailMeta(log),
          const SizedBox(height: 12),
          ValueListenableBuilder<bool>(
            valueListenable: showAccelNotifier,
            builder: (_, showAccel, _) => showAccel
                ? _chartSection(
                    "Accelerometer (g)",
                    log,
                    [log.axes[0], log.axes[1], log.axes[2]],
                    kAccelColors,
                    kAccelLabels,
                    "g",
                    3,
                    dark,
                  )
                : const SizedBox.shrink(),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: showGyroNotifier,
            builder: (_, showGyro, _) => showGyro
                ? _chartSection(
                    "Gyroscope (dps)",
                    log,
                    [log.axes[3], log.axes[4], log.axes[5]],
                    kGyroColors,
                    kGyroLabels,
                    "dps",
                    1,
                    dark,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _detailMeta(ThrowLog log) {
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: Theme.of(context).textTheme.bodySmall),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            row("Class", log.throwClass),
            row("Name", log.name.isEmpty ? "(none)" : log.name),
            row("Samples", "${log.count}"),
            row("Duration", "${log.durationSec.toStringAsFixed(3)} s"),
            row("Sample rate", "${log.sampleRateHz.toStringAsFixed(0)} Hz"),
            row("Dropped", "${log.droppedSamples}"),
            row("Peak accel", "${log.peakAccelG.toStringAsFixed(2)} g"),
            row("Peak gyro", "${log.peakGyroDps.toStringAsFixed(0)} dps"),
            row("Firmware throw id", "${log.throwId}"),
          ],
        ),
      ),
    );
  }

  Widget _chartSection(
    String title,
    ThrowLog log,
    List<Float32List> series,
    List<Color> colors,
    List<String> labels,
    String unit,
    int decimals,
    bool dark,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        SizedBox(
          height: 200,
          child: InteractiveChart(
            t: log.t,
            series: series,
            count: log.count,
            colors: colors,
            labels: labels,
            unit: unit,
            decimals: decimals,
            forcedMin: null,
            cornerText: null,
            centerZero: true,
            markerTimes: const [],
            persist: false,
            pos: HoverReadoutPos.follow,
            timeLabel: (s) => "${(s * 1000).toStringAsFixed(0)} ms",
            dark: dark,
          ),
        ),
      ],
    );
  }
}

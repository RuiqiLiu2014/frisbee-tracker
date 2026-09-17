import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/frisbee_ble.dart';
import '../settings.dart';

/// Single-pose calibration wizard: place the disc flat on the floor and hold it
/// still, then ask the firmware for a one-shot averaged reading (gravity vector
/// + gyro bias). The result is validated for stillness/flatness and persisted.
class CalibrationDialog extends StatefulWidget {
  final FrisbeeBle ble;
  const CalibrationDialog({super.key, required this.ble});

  @override
  State<CalibrationDialog> createState() => _CalibrationDialogState();
}

enum _Phase { idle, measuring, done, error }

class _CalibrationDialogState extends State<CalibrationDialog> {
  _Phase _phase = _Phase.idle;
  CalibResult? _result;
  String _error = "";

  Future<void> _run() async {
    setState(() {
      _phase = _Phase.measuring;
      _error = "";
    });
    try {
      final r = await widget.ble.calibrate();
      // Sanity-check that the disc was flat and still.
      if (r.accelMag < 0.80 || r.accelMag > 1.20) {
        _fail(
          "Gravity read ${r.accelMag.toStringAsFixed(2)} g (expected ~1.00). "
          "Set the disc flat on the floor and try again.",
        );
        return;
      }
      if (r.gyroBiasMag > 15) {
        _fail(
          "The disc was moving (${r.gyroBiasMag.toStringAsFixed(0)} dps). "
          "Hold it still and try again.",
        );
        return;
      }
      final p = await SharedPreferences.getInstance();
      await p.setString(
        kCalibKey,
        "${r.ax},${r.ay},${r.az},${r.gxBias},${r.gyBias},${r.gzBias}",
      );
      await p.setInt(kCalibTimeKey, DateTime.now().millisecondsSinceEpoch);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.done;
        _result = r;
      });
    } catch (_) {
      _fail(
        "No response from the disc. Make sure it's connected and still, "
        "then try again.",
      );
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _error = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    late final Widget content;
    late final List<Widget> actions;

    switch (_phase) {
      case _Phase.idle:
        content = const Text(
          "Place the disc flat on the floor and hold it still, then tap "
          "Calibrate. This records the resting orientation and the gyro's "
          "zero-rate offset.",
        );
        actions = [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          FilledButton(onPressed: _run, child: const Text("Calibrate")),
        ];
        break;
      case _Phase.measuring:
        content = const Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(child: Text("Measuring… keep the disc still.")),
          ],
        );
        actions = const [];
        break;
      case _Phase.done:
        final r = _result!;
        // Tilt of the disc from flat during calibration = angle of the gravity
        // vector off the sensor's dominant (largest) axis.
        final maxComp = [
          r.ax.abs(),
          r.ay.abs(),
          r.az.abs(),
        ].reduce((a, b) => a > b ? a : b);
        final ratio = r.accelMag == 0
            ? 1.0
            : (maxComp / r.accelMag).clamp(-1.0, 1.0);
        final tiltDeg = (57.2958 * math.acos(ratio)).clamp(0.0, 90.0);
        content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: scheme.primary),
                const SizedBox(width: 8),
                const Text(
                  "Calibrated",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text("Gravity: ${r.accelMag.toStringAsFixed(3)} g"),
            Text("Off-flat: ${tiltDeg.toStringAsFixed(1)}°"),
            Text("Gyro bias: ${r.gyroBiasMag.toStringAsFixed(1)} dps"),
          ],
        );
        actions = [
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Done"),
          ),
        ];
        break;
      case _Phase.error:
        content = Text(_error, style: TextStyle(color: scheme.error));
        actions = [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          FilledButton(onPressed: _run, child: const Text("Retry")),
        ];
        break;
    }

    return AlertDialog(
      title: const Text("Calibrate"),
      content: content,
      actions: actions,
    );
  }
}

import 'dart:typed_data';

/// One captured throw, held in memory as right-sized columnar arrays.
/// Axes order: ax, ay, az, gx, gy, gz  (accel in g, gyro in dps).
class ThrowLog {
  final int id; // app-assigned sequential log number
  final int throwId; // firmware throw counter (0 if unknown)
  final DateTime timestamp;
  final Float64List t; // seconds, rebased to 0 at capture start
  final List<Float32List> axes; // 6 columns: ax, ay, az, gx, gy, gz
  final int count;
  final double durationSec;
  final double sampleRateHz; // capture rate reported by firmware
  final int droppedSamples; // samples lost to BLE drops during upload
  final double peakAccelG;
  final double peakGyroDps;
  String name; // free-form user name; empty => display falls back to "Throw #id"
  String throwClass; // throw type, one of kThrowLabels (e.g. "backhand", "unlabeled")
  // Calibration snapshot baked in at capture time so a throw's orientation never
  // shifts when the disc is re-calibrated later: [ax, ay, az, gxBias, gyBias,
  // gzBias] (g, dps), or null if the disc wasn't calibrated when it was thrown.
  final List<double>? calib;

  ThrowLog({
    required this.id,
    required this.throwId,
    required this.timestamp,
    required this.t,
    required this.axes,
    required this.count,
    required this.durationSec,
    required this.sampleRateHz,
    this.droppedSamples = 0,
    this.peakAccelG = 0,
    this.peakGyroDps = 0,
    this.name = "",
    this.throwClass = "unlabeled",
    this.calib,
  });

  String get displayName => name.isEmpty ? "Throw #$id" : name;
}

import 'dart:math' as math;
import 'dart:typed_data';

// Canonical disc-frame preprocessing.
//
// The board mounts on the disc at a slight (and per-user variable) angle, so its
// raw axes aren't disc-aligned. Calibration (disc flat + still) measures the mean
// accelerometer vector, which points UP along the disc normal in the board frame.
// That single vector defines the board->disc rotation we want: disc-frame z = the
// normal, and x/y span the disc plane. The in-plane x/y direction is undetermined
// by a flat calibration (and physically meaningless on a spinning disc), so we
// pick a consistent one; every metric we care about — spin (gz), tilt, upward
// accel, in-plane accel magnitude — is invariant to that choice.
//
// Board sends raw int16 (rotating there would overflow the int16 range on hard
// throws, where |accel| hits ~27 g and one rotated axis can exceed the ±16 g
// field). The phone rotates in float, where there's no range limit.

/// Build the board->disc rotation matrix (3 rows) from a calibration snapshot
/// `[ax, ay, az, gxBias, gyBias, gzBias]`. Returns null when there's no usable
/// calibration, so callers can leave the samples in the board frame.
List<List<double>>? discRotation(List<double>? calib) {
  if (calib == null || calib.length < 3) return null;
  double nx = calib[0], ny = calib[1], nz = calib[2];
  final m = math.sqrt(nx * nx + ny * ny + nz * nz);
  if (m < 1e-6) return null;
  nx /= m;
  ny /= m;
  nz /= m; // disc up-normal = z'

  // Reference axis least aligned with the normal, so the projection is stable.
  double ex = 1, ey = 0, ez = 0;
  if (nx.abs() > 0.9) {
    ex = 0;
    ey = 1;
    ez = 0;
  }
  // x' = normalize(e - (e·n) n)
  final d = ex * nx + ey * ny + ez * nz;
  double xx = ex - d * nx, xy = ey - d * ny, xz = ez - d * nz;
  final xm = math.sqrt(xx * xx + xy * xy + xz * xz);
  if (xm < 1e-6) return null;
  xx /= xm;
  xy /= xm;
  xz /= xm;
  // y' = n × x'
  final yx = ny * xz - nz * xy, yy = nz * xx - nx * xz, yz = nx * xy - ny * xx;
  return [
    [xx, xy, xz],
    [yx, yy, yz],
    [nx, ny, nz],
  ];
}

/// Rotate the 6 accel+gyro columns into the disc frame using [calib]. Rotation
/// preserves each vector's magnitude, so peak accel/gyro are unchanged. Returns
/// the original axes unchanged when there's no usable calibration.
List<Float32List> toDiscFrame(
  List<Float32List> axes,
  int count,
  List<double>? calib,
) {
  final r = discRotation(calib);
  if (r == null) return axes;
  final r0 = r[0], r1 = r[1], r2 = r[2];
  final out = List.generate(6, (_) => Float32List(count));
  for (int i = 0; i < count; i++) {
    final ax = axes[0][i], ay = axes[1][i], az = axes[2][i];
    out[0][i] = r0[0] * ax + r0[1] * ay + r0[2] * az;
    out[1][i] = r1[0] * ax + r1[1] * ay + r1[2] * az;
    out[2][i] = r2[0] * ax + r2[1] * ay + r2[2] * az;
    final gx = axes[3][i], gy = axes[4][i], gz = axes[5][i];
    out[3][i] = r0[0] * gx + r0[1] * gy + r0[2] * gz;
    out[4][i] = r1[0] * gx + r1[1] * gy + r1[2] * gz;
    out[5][i] = r2[0] * gx + r2[1] * gy + r2[2] * gz;
  }
  return out;
}

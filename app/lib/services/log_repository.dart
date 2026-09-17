import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/throw_log.dart';

/// On-disk persistence + export for [ThrowLog]s. Stateless: each method reads or
/// writes the app documents `logs/` directory. Binary `.bin` files survive
/// restart; CSV/zip is produced on demand for the system share sheet.
class LogRepository {
  static const int _formatVersion = 2; // v2 added the separate throwClass field

  Future<Directory> _logsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/logs');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  File _logFile(Directory dir, ThrowLog log) => File(
    '${dir.path}/throw_${log.id}_${log.timestamp.millisecondsSinceEpoch}.bin',
  );

  /// Write one throw to disk. Best-effort: a failure just means it won't survive
  /// a restart.
  Future<void> persist(ThrowLog log) async {
    try {
      final dir = await _logsDir();
      final n = log.count;
      final nameBytes = utf8.encode(log.name);
      final classBytes = utf8.encode(log.throwClass);
      final bd = ByteData(
        4 + // format version
            4 + // throwId
            4 + // count
            8 + // sampleRateHz
            4 + // droppedSamples
            8 + // peakAccelG
            8 + // peakGyroDps
            4 + // name length
            nameBytes.length +
            4 + // class length
            classBytes.length +
            n * 8 + // t (float64)
            6 * n * 4, // axes (float32)
      );
      int off = 0;
      bd.setInt32(off, _formatVersion, Endian.little);
      off += 4;
      bd.setInt32(off, log.throwId, Endian.little);
      off += 4;
      bd.setInt32(off, n, Endian.little);
      off += 4;
      bd.setFloat64(off, log.sampleRateHz, Endian.little);
      off += 8;
      bd.setInt32(off, log.droppedSamples, Endian.little);
      off += 4;
      bd.setFloat64(off, log.peakAccelG, Endian.little);
      off += 8;
      bd.setFloat64(off, log.peakGyroDps, Endian.little);
      off += 8;
      bd.setInt32(off, nameBytes.length, Endian.little);
      off += 4;
      final u8 = bd.buffer.asUint8List();
      u8.setRange(off, off + nameBytes.length, nameBytes);
      off += nameBytes.length;
      bd.setInt32(off, classBytes.length, Endian.little);
      off += 4;
      u8.setRange(off, off + classBytes.length, classBytes);
      off += classBytes.length;
      for (int i = 0; i < n; i++) {
        bd.setFloat64(off, log.t[i], Endian.little);
        off += 8;
      }
      for (int a = 0; a < 6; a++) {
        final col = log.axes[a];
        for (int i = 0; i < n; i++) {
          bd.setFloat32(off, col[i], Endian.little);
          off += 4;
        }
      }
      await _logFile(dir, log).writeAsBytes(u8, flush: true);
    } catch (_) {
      // best-effort
    }
  }

  /// Load all persisted throws (newest first). Returns the highest id seen so
  /// callers can continue the numbering sequence.
  Future<({List<ThrowLog> logs, int maxId})> loadAll() async {
    final loaded = <ThrowLog>[];
    int maxId = 0;
    try {
      final dir = await _logsDir();
      final re = RegExp(r'throw_(\d+)_(\d+)\.bin$');
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final m = re.firstMatch(entity.path.split('/').last);
        if (m == null) continue;
        final id = int.parse(m.group(1)!);
        final ts = DateTime.fromMillisecondsSinceEpoch(int.parse(m.group(2)!));
        try {
          final log = _decode(id, ts, await entity.readAsBytes());
          if (log == null) continue;
          loaded.add(log);
          if (id > maxId) maxId = id;
        } catch (_) {
          // skip an unreadable/corrupt file
        }
      }
    } catch (_) {
      // no store yet
    }
    loaded.sort((a, b) => b.id.compareTo(a.id));
    return (logs: loaded, maxId: maxId);
  }

  ThrowLog? _decode(int id, DateTime ts, Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    int off = 0;
    if (bytes.length < 8) return null;
    final version = bd.getInt32(off, Endian.little);
    off += 4;
    if (version != 1 && version != 2) return null;
    final throwId = bd.getInt32(off, Endian.little);
    off += 4;
    final n = bd.getInt32(off, Endian.little);
    off += 4;
    if (n <= 0) return null;
    final sampleRateHz = bd.getFloat64(off, Endian.little);
    off += 8;
    final dropped = bd.getInt32(off, Endian.little);
    off += 4;
    final peakAccelG = bd.getFloat64(off, Endian.little);
    off += 8;
    final peakGyroDps = bd.getFloat64(off, Endian.little);
    off += 8;
    if (bytes.length < off + 4) return null;
    final nameLen = bd.getInt32(off, Endian.little);
    off += 4;
    if (nameLen < 0 || bytes.length < off + nameLen) return null;
    String name = nameLen > 0
        ? utf8.decode(bytes.sublist(off, off + nameLen))
        : "";
    off += nameLen;
    // Throw class: read it (v2+), or migrate a v1 file. v1 stored the throw
    // label in `name`; per the reset we treat every existing throw as backhand
    // and clear the name so class and free-form name are cleanly separated.
    String throwClass;
    if (version >= 2) {
      if (bytes.length < off + 4) return null;
      final classLen = bd.getInt32(off, Endian.little);
      off += 4;
      if (classLen < 0 || bytes.length < off + classLen) return null;
      throwClass = classLen > 0
          ? utf8.decode(bytes.sublist(off, off + classLen))
          : "unlabeled";
      off += classLen;
    } else {
      throwClass = "backhand";
      name = "";
    }
    if (bytes.length < off + n * 8 + 6 * n * 4) return null;
    final t = Float64List(n);
    for (int i = 0; i < n; i++) {
      t[i] = bd.getFloat64(off, Endian.little);
      off += 8;
    }
    final axes = List.generate(6, (a) {
      final col = Float32List(n);
      for (int i = 0; i < n; i++) {
        col[i] = bd.getFloat32(off, Endian.little);
        off += 4;
      }
      return col;
    });
    return ThrowLog(
      id: id,
      throwId: throwId,
      timestamp: ts,
      t: t,
      axes: axes,
      count: n,
      durationSec: t[n - 1],
      sampleRateHz: sampleRateHz,
      droppedSamples: dropped,
      peakAccelG: peakAccelG,
      peakGyroDps: peakGyroDps,
      name: name,
      throwClass: throwClass,
    );
  }

  Future<void> delete(ThrowLog log) async {
    try {
      final dir = await _logsDir();
      final f = _logFile(dir, log);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Total on-disk size of every persisted log file.
  Future<int> storageBytes() async {
    int total = 0;
    try {
      final dir = await _logsDir();
      for (final e in dir.listSync()) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  String csvFor(ThrowLog log) {
    final sb = StringBuffer()
      ..write(
        "# throw_id=${log.throwId},class=${log.throwClass},name=${log.name},"
        "samples=${log.count},"
        "sample_rate_hz=${log.sampleRateHz.toStringAsFixed(1)},"
        "dropped=${log.droppedSamples},"
        "peak_accel_g=${log.peakAccelG.toStringAsFixed(4)},"
        "peak_gyro_dps=${log.peakGyroDps.toStringAsFixed(2)}\n",
      )
      ..write("time_s,ax_g,ay_g,az_g,gx_dps,gy_dps,gz_dps\n");
    for (int i = 0; i < log.count; i++) {
      sb.write(log.t[i].toStringAsFixed(4));
      for (int a = 0; a < 6; a++) {
        sb.write(',');
        sb.write(log.axes[a][i].toStringAsFixed(a < 3 ? 4 : 2));
      }
      sb.write('\n');
    }
    return sb.toString();
  }

  String safeName(ThrowLog log) {
    final base = log.displayName
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_')
        .trim();
    return base.isEmpty ? 'throw_${log.id}' : base;
  }

  /// Share one or many logs via the system share sheet: a single CSV when
  /// there's one, else all CSVs bundled into one .zip.
  Future<void> shareLogs(List<ThrowLog> logs) async {
    if (logs.isEmpty) return;
    if (logs.length == 1) {
      final log = logs.first;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${safeName(log)}.csv');
      await file.writeAsString(csvFor(log));
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: 'Frisbee throw: ${log.displayName}',
          text:
              '${log.displayName}: ${log.count} samples, '
              '${log.durationSec.toStringAsFixed(2)} s',
        ),
      );
      return;
    }
    final archive = Archive();
    final used = <String>{};
    for (final log in logs) {
      var name = '${safeName(log)}.csv';
      if (!used.add(name)) {
        name = '${safeName(log)}_${log.id}.csv';
        used.add(name);
      }
      archive.addFile(ArchiveFile.bytes(name, utf8.encode(csvFor(log))));
    }
    final zipped = ZipEncoder().encode(archive);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/frisbee_throws.zip');
    await file.writeAsBytes(zipped, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/zip')],
        subject: 'Frisbee throws (${logs.length})',
        text: '${logs.length} frisbee IMU throws (one CSV each).',
      ),
    );
  }
}

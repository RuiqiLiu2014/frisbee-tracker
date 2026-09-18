import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../constants.dart';

// ===========================================================================
// BLE identifiers (Nordic UART). Same UUIDs as the PingPongTracker firmware.
// ===========================================================================
const String kTargetDeviceName = "FrisbeeTrack";
final Guid kUartServiceUuid = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
final Guid kTxCharacteristicUuid = Guid("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");
final Guid kRxCharacteristicUuid = Guid("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");
final Guid kVersionCharacteristicUuid = Guid(
  "6E400004-B5A3-F393-E0A9-E50E24DCCA9E",
);

// ===========================================================================
// Store-and-forward throw-upload protocol (app <-> firmware contract).
//
// The disc records a throw on-device (it leaves BLE range mid-flight), then
// forwards it once back in range. Each BLE notification on the TX characteristic
// is exactly one packet, tagged by a leading type byte:
//
//   0x01 BEGIN   [u8 type][u32 throwId][u16 sampleRateHz][u16 totalSamples]
//   0x02 SAMPLES [u8 type][u16 firstIndex][u8 n] + n * (int16 ax,ay,az,gx,gy,gz)
//   0x03 END     [u8 type][u32 throwId][u16 sampleCount]
//                [f32 peakAccelG][f32 peakGyroDps][u32 flightMs]
//   0x10 STATUS  [u8 type][u8 battPct][u16 battMv]        (idle heartbeat)
//
// App -> device on the RX characteristic (ASCII, newline-terminated):
//   "ACK:<throwId>\n"   confirm a throw was received (device may then dequeue)
//   "LABEL:<name>\n"    set the label stamped on subsequent throws
//   "CLEAR\n"           drop the device's queued throws
// ===========================================================================
const int _pktBegin = 0x01;
const int _pktSamples = 0x02;
const int _pktEnd = 0x03;
const int _pktStatus = 0x10;
const int _pktCalib = 0x11;
const int _pktLive = 0x12;

const int _kMaxThrowSamples = 60000; // ~36 s at 1660 Hz; sanity clamp

enum ConnState { disconnected, scanning, connecting, connected }

/// A fully-received throw, before the app assigns it a log id. Arrays are ready
/// to hand straight to a [ThrowLog] (no copy needed).
class ReceivedThrow {
  final int throwId;
  final double sampleRateHz;
  final int count;
  final int droppedSamples;
  final double peakAccelG;
  final double peakGyroDps;
  final double flightMs;
  final Float64List t; // seconds
  final List<Float32List> axes; // ax, ay, az, gx, gy, gz (scaled units)
  final String label;

  ReceivedThrow({
    required this.throwId,
    required this.sampleRateHz,
    required this.count,
    required this.droppedSamples,
    required this.peakAccelG,
    required this.peakGyroDps,
    required this.flightMs,
    required this.t,
    required this.axes,
    required this.label,
  });
}

/// A one-shot calibration reading taken with the disc flat + still: the mean
/// accelerometer vector (gravity / "down" in the sensor frame) and the mean
/// gyro reading (the zero-rate bias to subtract later).
class CalibResult {
  final double ax, ay, az; // g
  final double gxBias, gyBias, gzBias; // dps
  const CalibResult({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gxBias,
    required this.gyBias,
    required this.gzBias,
  });

  double get accelMag => math.sqrt(ax * ax + ay * ay + az * az);
  double get gyroBiasMag =>
      math.sqrt(gxBias * gxBias + gyBias * gyBias + gzBias * gzBias);
}

/// Owns the BLE link and the store-and-forward receiver. A [ChangeNotifier] so
/// the UI can rebuild on connection/upload state changes; completed throws are
/// emitted on the [throws] stream.
class FrisbeeBle extends ChangeNotifier {
  // ---- connection state (read by the UI) ----
  ConnState _state = ConnState.disconnected;
  String _status = "Disconnected";
  String _firmwareVersion = "";
  int _batteryPct = 0;
  int? _rssi;
  String _label = "unlabeled";
  // Latest live accel (g), null until the first live packet / after disconnect.
  double? _liveAx, _liveAy, _liveAz;

  // ---- current upload progress ----
  bool _receiving = false;
  int _uploadThrowId = 0;
  int _uploadExpected = 0; // totalSamples from BEGIN
  int _uploadWritten = 0; // samples actually placed
  int _throwsThisSession = 0;

  ConnState get state => _state;
  String get status => _status;
  String get firmwareVersion => _firmwareVersion;
  int get batteryPct => _batteryPct;
  int? get rssi => _rssi;
  String get label => _label;
  double? get liveAx => _liveAx;
  double? get liveAy => _liveAy;
  double? get liveAz => _liveAz;
  bool get hasLive => _liveAx != null;
  bool get receiving => _receiving;
  int get uploadExpected => _uploadExpected;
  int get uploadWritten => _uploadWritten;
  int get throwsThisSession => _throwsThisSession;
  bool get isConnected => _state == ConnState.connected;

  final StreamController<ReceivedThrow> _throwController =
      StreamController<ReceivedThrow>.broadcast();
  Stream<ReceivedThrow> get throws => _throwController.stream;

  // ---- BLE handles + subscriptions ----
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar;
  StreamSubscription<List<int>>? _txSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _rssiTimer;
  Timer? _btRetryTimer; // pending "wait for Bluetooth to come back" retry
  bool _userStopped = false; // true after a manual Stop/Disconnect (no auto-rescan)
  bool _reconnectPending = false; // a backoff-then-rescan is already scheduled
  bool _disposed = false;
  Timer? _calibTimeout;
  Completer<CalibResult>? _calibCompleter;

  // ---- in-flight throw assembly buffers ----
  List<Float32List>? _axBuf;
  int _sampleRateHz = 0;
  int _maxIndex = 0;

  void _set(VoidCallback fn) {
    fn();
    notifyListeners();
  }

  // =========================================================================
  // Connection
  // =========================================================================
  /// User taps "Start scan": begin (continuously) scanning for the disc.
  Future<void> startScan() async {
    if (_state == ConnState.scanning ||
        _state == ConnState.connecting ||
        _state == ConnState.connected) {
      return;
    }
    _userStopped = false;
    _set(() {
      _state = ConnState.scanning;
      _status = "Scanning...";
    });
    await _beginScan();
  }

  // (Re)start the actual BLE scan. Assumes the state is already `scanning`, so it
  // works both for [startScan] and for the auto-reconnect backoff without
  // tripping [startScan]'s guard.
  Future<void> _beginScan() async {
    if (_userStopped || _disposed) return;
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      if (_userStopped || _disposed) {
        _goIdle();
        return;
      }
      // BT momentarily off (or a blip mid-reconnect): keep waiting and retry,
      // staying in the scanning state so it recovers on its own once BT is back.
      _set(() {
        _state = ConnState.scanning;
        _status = "Waiting for Bluetooth…";
      });
      _btRetryTimer?.cancel();
      _btRetryTimer = Timer(const Duration(milliseconds: 1500), () {
        if (!_userStopped && !_disposed) _beginScan();
      });
      return;
    }
    if (_userStopped || _disposed) return;

    // One continuous scan (no timeout) until we find the disc or the user stops —
    // repeatedly restarting short scans would hit Android's scan-rate throttle.
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      if (_state != ConnState.scanning) return; // ignore once we move on
      for (final r in results) {
        if (r.device.platformName == kTargetDeviceName) {
          await _stopScanning();
          if (_userStopped || _disposed) return;
          _connectToDevice(r.device);
          return;
        }
      }
    });
    try {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await FlutterBluePlus.startScan(androidUsesFineLocation: true);
    } catch (_) {
      _reconnectOrIdle();
    }
  }

  Future<void> _stopScanning() async {
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    const int maxAttempts = 3;
    bool connected = false;

    // Clear any stale/half-open GATT client (common after a board power-cycle).
    try {
      await device.disconnect();
    } catch (_) {}

    for (int attempt = 1; attempt <= maxAttempts && !_userStopped; attempt++) {
      _set(() {
        _state = ConnState.connecting;
        _status = attempt == 1
            ? "Connecting..."
            : "Connecting... (retry ${attempt - 1})";
      });
      try {
        await device.connect(
          license: License.nonprofit,
          autoConnect: false,
          mtu: null,
          timeout: const Duration(seconds: 6),
        );
        connected = true;
        break;
      } catch (_) {
        try {
          await device.disconnect();
        } catch (_) {}
        if (attempt < maxAttempts) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
      }
    }

    if (_userStopped || _disposed) {
      try {
        await device.disconnect();
      } catch (_) {}
      _goIdle();
      return;
    }
    if (!connected) {
      _reconnectOrIdle(); // couldn't link this time -> keep trying via the scan
      return;
    }

    try {
      _device = device;
      _connSub?.cancel();
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected &&
            _state != ConnState.disconnected) {
          _handleDisconnected();
        }
      });

      _set(() => _status = "Negotiating packet size...");
      await Future.delayed(const Duration(milliseconds: 400));
      try {
        await device.requestMtu(247);
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));

      _set(() => _status = "Discovering services...");
      final services = await device.discoverServices();
      for (final service in services) {
        if (service.uuid != kUartServiceUuid) continue;
        BluetoothCharacteristic? tx;
        for (final char in service.characteristics) {
          if (char.uuid == kTxCharacteristicUuid) tx = char;
          if (char.uuid == kRxCharacteristicUuid) _rxChar = char;
          if (char.uuid == kVersionCharacteristicUuid) {
            try {
              final v = await char.read();
              if (v.isNotEmpty) _firmwareVersion = utf8.decode(v).trim();
            } catch (_) {
              // older firmware without a version characteristic
            }
          }
        }
        if (tx != null) {
          await _subscribe(tx);
          return;
        }
      }
      // No UART service on this device -> treat like a failed connect, keep trying.
      _reconnectOrIdle();
    } catch (_) {
      _reconnectOrIdle();
    }
  }

  Future<void> _subscribe(BluetoothCharacteristic tx) async {
    await tx.setNotifyValue(true);
    _resetAssembly();
    _throwsThisSession = 0;
    _set(() {
      _state = ConnState.connected;
      _status = "Connected";
    });
    _txSub = tx.onValueReceived.listen(_onPacket);
    // Push the current label so the device stamps throws correctly, and start
    // polling RSSI (useful for range testing).
    await sendLabel(_label);
    _startRssiPolling();
  }

  void _startRssiPolling() {
    _rssiTimer?.cancel();
    _rssiTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final d = _device;
      if (d == null) return;
      try {
        final v = await d.readRssi();
        _set(() => _rssi = v);
      } catch (_) {}
    });
  }

  // =========================================================================
  // Packet handling
  // =========================================================================
  void _onPacket(List<int> value) {
    if (value.isEmpty) return;
    final bytes = Uint8List.fromList(value);
    final bd = ByteData.sublistView(bytes);
    switch (bytes[0]) {
      case _pktBegin:
        _onBegin(bd, bytes.length);
        break;
      case _pktSamples:
        _onSamples(bd, bytes, bytes.length);
        break;
      case _pktEnd:
        _onEnd(bd, bytes.length);
        break;
      case _pktStatus:
        _onStatus(bd, bytes.length);
        break;
      case _pktCalib:
        _onCalib(bd, bytes.length);
        break;
      case _pktLive:
        _onLive(bd, bytes.length);
        break;
    }
  }

  void _onLive(ByteData bd, int len) {
    if (len < 7) return;
    _set(() {
      _liveAx = bd.getInt16(1, Endian.little) * kAccelScaleG;
      _liveAy = bd.getInt16(3, Endian.little) * kAccelScaleG;
      _liveAz = bd.getInt16(5, Endian.little) * kAccelScaleG;
    });
  }

  void _onBegin(ByteData bd, int len) {
    if (len < 9) return;
    final throwId = bd.getUint32(1, Endian.little);
    final rate = bd.getUint16(5, Endian.little);
    int total = bd.getUint16(7, Endian.little);
    if (total <= 0) total = 1;
    if (total > _kMaxThrowSamples) total = _kMaxThrowSamples;
    _uploadThrowId = throwId;
    _sampleRateHz = rate > 0 ? rate : kNominalOdrHz.round();
    _uploadExpected = total;
    _axBuf = List.generate(6, (_) => Float32List(total));
    _uploadWritten = 0;
    _maxIndex = 0;
    _set(() {
      _receiving = true;
      _status = "Receiving throw #$throwId...";
    });
  }

  void _onSamples(ByteData bd, Uint8List bytes, int len) {
    final buf = _axBuf;
    if (!_receiving || buf == null || len < 4) return;
    final firstIndex = bd.getUint16(1, Endian.little);
    final n = bytes[3];
    if (len < 4 + n * 12) return;

    for (int s = 0; s < n; s++) {
      final idx = firstIndex + s;
      if (idx < 0 || idx >= _uploadExpected) continue;
      final b = 4 + s * 12;
      buf[0][idx] = bd.getInt16(b + 0, Endian.little) * kAccelScaleG;
      buf[1][idx] = bd.getInt16(b + 2, Endian.little) * kAccelScaleG;
      buf[2][idx] = bd.getInt16(b + 4, Endian.little) * kAccelScaleG;
      buf[3][idx] = bd.getInt16(b + 6, Endian.little) * kGyroScaleDps;
      buf[4][idx] = bd.getInt16(b + 8, Endian.little) * kGyroScaleDps;
      buf[5][idx] = bd.getInt16(b + 10, Endian.little) * kGyroScaleDps;
      _uploadWritten++;
      if (idx > _maxIndex) _maxIndex = idx;
    }
    _set(() {}); // refresh progress readout
  }

  void _onEnd(ByteData bd, int len) {
    final buf = _axBuf;
    if (!_receiving || buf == null) {
      _resetAssembly();
      return;
    }
    double peakA = 0, peakG = 0, flightMs = 0;
    int metaThrowId = _uploadThrowId;
    if (len >= 7) metaThrowId = bd.getUint32(1, Endian.little);
    if (len >= 19) {
      peakA = bd.getFloat32(7, Endian.little);
      peakG = bd.getFloat32(11, Endian.little);
      flightMs = bd.getUint32(15, Endian.little).toDouble();
    }

    final int count = _uploadExpected > 0 ? _uploadExpected : (_maxIndex + 1);
    final int dropped = math.max(0, count - _uploadWritten);
    final double rate = _sampleRateHz > 0
        ? _sampleRateHz.toDouble()
        : kNominalOdrHz;

    final t = Float64List(count);
    for (int i = 0; i < count; i++) {
      t[i] = i / rate;
    }
    // Trim the axis buffers to the actual count (they were sized to expected).
    final axes = List.generate(6, (a) {
      if (buf[a].length == count) return buf[a];
      return Float32List.sublistView(buf[a], 0, count);
    });
    if (peakA == 0 || peakG == 0) {
      final computed = _computePeaks(axes, count);
      if (peakA == 0) peakA = computed.$1;
      if (peakG == 0) peakG = computed.$2;
    }

    final received = ReceivedThrow(
      throwId: metaThrowId,
      sampleRateHz: rate,
      count: count,
      droppedSamples: dropped,
      peakAccelG: peakA,
      peakGyroDps: peakG,
      flightMs: flightMs,
      t: t,
      axes: axes,
      label: _label,
    );
    _throwsThisSession++;
    _throwController.add(received);
    _sendAck(metaThrowId);
    _resetAssembly();
    _set(() {
      _receiving = false;
      _status = "Connected";
    });
  }

  void _onStatus(ByteData bd, int len) {
    if (len < 2) return;
    final pct = bd.getUint8(1);
    _set(() => _batteryPct = pct);
  }

  void _onCalib(ByteData bd, int len) {
    if (len < 25) return;
    final r = CalibResult(
      ax: bd.getFloat32(1, Endian.little),
      ay: bd.getFloat32(5, Endian.little),
      az: bd.getFloat32(9, Endian.little),
      gxBias: bd.getFloat32(13, Endian.little),
      gyBias: bd.getFloat32(17, Endian.little),
      gzBias: bd.getFloat32(21, Endian.little),
    );
    _calibTimeout?.cancel();
    if (_calibCompleter != null && !_calibCompleter!.isCompleted) {
      _calibCompleter!.complete(r);
    }
  }

  (double, double) _computePeaks(List<Float32List> axes, int count) {
    double pa = 0, pg = 0;
    for (int i = 0; i < count; i++) {
      final ax = axes[0][i], ay = axes[1][i], az = axes[2][i];
      final gx = axes[3][i], gy = axes[4][i], gz = axes[5][i];
      final am = math.sqrt(ax * ax + ay * ay + az * az);
      final gm = math.sqrt(gx * gx + gy * gy + gz * gz);
      if (am > pa) pa = am;
      if (gm > pg) pg = gm;
    }
    return (pa, pg);
  }

  void _resetAssembly() {
    _axBuf = null;
    _uploadExpected = 0;
    _uploadWritten = 0;
    _maxIndex = 0;
  }

  // =========================================================================
  // Commands to the device
  // =========================================================================
  Future<void> _write(String cmd) async {
    final c = _rxChar;
    if (c == null) return;
    try {
      await c.write(
        utf8.encode(cmd),
        withoutResponse: c.properties.writeWithoutResponse,
      );
    } catch (_) {}
  }

  Future<void> sendLabel(String label) async {
    _set(() => _label = label);
    await _write("LABEL:$label\n");
  }

  Future<void> _sendAck(int throwId) => _write("ACK:$throwId\n");

  Future<void> clearDeviceQueue() => _write("CLEAR\n");

  /// Ask the disc for a one-shot calibration reading (it averages a short still
  /// window and replies). Completes with the reading, or errors on timeout /
  /// disconnect. Caller should have the disc flat + still first.
  Future<CalibResult> calibrate({
    Duration timeout = const Duration(seconds: 6),
  }) {
    if (_state != ConnState.connected || _rxChar == null) {
      return Future.error(StateError("Not connected"));
    }
    _calibTimeout?.cancel();
    if (_calibCompleter != null && !_calibCompleter!.isCompleted) {
      _calibCompleter!.completeError(StateError("superseded"));
    }
    final c = Completer<CalibResult>();
    _calibCompleter = c;
    _calibTimeout = Timer(timeout, () {
      if (!c.isCompleted) {
        c.completeError(TimeoutException("No calibration response"));
      }
    });
    _write("CALIB\n");
    return c.future;
  }

  // =========================================================================
  // Teardown
  // =========================================================================
  /// User-initiated stop from ANY state (scanning, connecting, or connected):
  /// tear everything down and stay idle — no auto-reconnect.
  Future<void> disconnect() async {
    _userStopped = true;
    _reconnectPending = false;
    _rssiTimer?.cancel();
    _calibTimeout?.cancel();
    await _txSub?.cancel();
    await _connSub?.cancel();
    _connSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _goIdle(); // also stops any active scan
  }

  // The GATT link dropped while we thought we were connected. If the user didn't
  // ask to stop, treat it as the disc going out of range and auto-reconnect.
  void _handleDisconnected() {
    _txSub?.cancel();
    _connSub?.cancel();
    _connSub = null;
    _rssiTimer?.cancel();
    _reconnectOrIdle();
  }

  // Resume scanning after an unexpected drop / failed connect, unless the user
  // stopped. A short backoff avoids hammering the scanner; [_reconnectPending]
  // collapses overlapping failures into a single rescan.
  void _reconnectOrIdle() {
    if (_userStopped || _disposed) {
      _goIdle();
      return;
    }
    if (_reconnectPending) return;
    _reconnectPending = true;
    _resetAssembly();
    _set(() {
      _state = ConnState.scanning;
      _status = "Reconnecting...";
      _receiving = false;
      _rssi = null;
      _rxChar = null;
      _liveAx = _liveAy = _liveAz = null;
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      _reconnectPending = false;
      if (_userStopped || _disposed) {
        _goIdle();
        return;
      }
      _beginScan();
    });
  }

  void _goIdle() {
    _stopScanBestEffort();
    _btRetryTimer?.cancel();
    _resetAssembly();
    _reconnectPending = false;
    _calibTimeout?.cancel();
    if (_calibCompleter != null && !_calibCompleter!.isCompleted) {
      _calibCompleter!.completeError(StateError("Disconnected"));
    }
    _set(() {
      _state = ConnState.disconnected;
      _status = "Disconnected";
      _receiving = false;
      _rssi = null;
      _rxChar = null;
      _liveAx = _liveAy = _liveAz = null;
    });
  }

  void _stopScanBestEffort() {
    _scanSub?.cancel();
    _scanSub = null;
    FlutterBluePlus.stopScan().then((_) {}, onError: (_) {});
  }

  // =========================================================================
  // Debug: synthesize a throw so the UI/logs can be exercised without hardware.
  // =========================================================================
  void injectSyntheticThrow() {
    const int n = 400;
    const double rate = 400;
    final t = Float64List(n);
    final axes = List.generate(6, (_) => Float32List(n));
    double pa = 0, pg = 0;
    for (int i = 0; i < n; i++) {
      final tt = i / rate;
      t[i] = tt;
      // A windup ramp, a release spike near the middle, then decaying spin.
      final env = math.exp(-math.pow((tt - 0.5) / 0.15, 2).toDouble());
      axes[0][i] = (2.5 * env * math.sin(2 * math.pi * 6 * tt)).toDouble();
      axes[1][i] = (2.0 * env * math.cos(2 * math.pi * 6 * tt)).toDouble();
      axes[2][i] = (1.0 + 1.5 * env).toDouble();
      axes[3][i] = (900 * env * math.sin(2 * math.pi * 8 * tt)).toDouble();
      axes[4][i] = (700 * env).toDouble();
      axes[5][i] = (1800 * env).toDouble(); // spin axis, clips-adjacent
      final am = math.sqrt(
        axes[0][i] * axes[0][i] +
            axes[1][i] * axes[1][i] +
            axes[2][i] * axes[2][i],
      );
      final gm = math.sqrt(
        axes[3][i] * axes[3][i] +
            axes[4][i] * axes[4][i] +
            axes[5][i] * axes[5][i],
      );
      if (am > pa) pa = am;
      if (gm > pg) pg = gm;
    }
    _throwsThisSession++;
    _throwController.add(
      ReceivedThrow(
        throwId: _throwsThisSession,
        sampleRateHz: rate,
        count: n,
        droppedSamples: 0,
        peakAccelG: pa,
        peakGyroDps: pg,
        flightMs: n / rate * 1000,
        t: t,
        axes: axes,
        label: _label,
      ),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _rssiTimer?.cancel();
    _btRetryTimer?.cancel();
    _calibTimeout?.cancel();
    _txSub?.cancel();
    _scanSub?.cancel();
    _connSub?.cancel();
    _throwController.close();
    try {
      _device?.disconnect();
    } catch (_) {}
    super.dispose();
  }
}

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
  Timer? _scanTimeout;
  Timer? _rssiTimer;

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
  Future<void> startScanAndConnect() async {
    if (_state == ConnState.scanning || _state == ConnState.connecting) return;
    _set(() {
      _state = ConnState.scanning;
      _status = "Scanning...";
    });

    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _set(() {
        _state = ConnState.disconnected;
        _status = "Turn on Bluetooth!";
      });
      return;
    }

    // Subscribe BEFORE scanning so a result arriving during the scan isn't
    // missed. One latch so the "found" and "timeout" paths can't both run.
    bool resolved = false;
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      if (resolved) return;
      for (final r in results) {
        if (r.device.platformName == kTargetDeviceName) {
          resolved = true;
          _scanTimeout?.cancel();
          await _scanSub?.cancel();
          _scanSub = null;
          await FlutterBluePlus.stopScan();
          await Future.delayed(const Duration(milliseconds: 400));
          _connectToDevice(r.device);
          return;
        }
      }
    });

    const scanWindow = Duration(seconds: 10);
    _scanTimeout?.cancel();
    _scanTimeout = Timer(scanWindow, () async {
      if (resolved) return;
      resolved = true;
      await _scanSub?.cancel();
      _scanSub = null;
      await FlutterBluePlus.stopScan();
      _set(() {
        _state = ConnState.disconnected;
        _status = "Could not find $kTargetDeviceName.";
      });
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: scanWindow,
        androidUsesFineLocation: true,
      );
    } catch (_) {
      // startScan can throw if BLE is momentarily unavailable; the timeout
      // timer surfaces the failure.
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    const int maxAttempts = 3;
    bool connected = false;

    // Clear any stale/half-open GATT client (common after a board power-cycle).
    try {
      await device.disconnect();
    } catch (_) {}

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
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

    if (!connected) {
      _set(() {
        _state = ConnState.disconnected;
        _status = "Could not connect. Try again.";
      });
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
      _set(() {
        _state = ConnState.disconnected;
        _status = "UART service not found.";
      });
    } catch (_) {
      _set(() {
        _state = ConnState.disconnected;
        _status = "Could not connect. Try again.";
      });
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
    }
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

  // =========================================================================
  // Teardown
  // =========================================================================
  Future<void> disconnect() async {
    _scanTimeout?.cancel();
    _rssiTimer?.cancel();
    await _txSub?.cancel();
    await _scanSub?.cancel();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _connSub?.cancel();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _resetConnectionUi();
  }

  void _handleDisconnected() {
    _txSub?.cancel();
    _connSub?.cancel();
    _rssiTimer?.cancel();
    _resetConnectionUi();
  }

  void _resetConnectionUi() {
    _resetAssembly();
    _set(() {
      _state = ConnState.disconnected;
      _status = "Disconnected";
      _receiving = false;
      _rssi = null;
      _rxChar = null;
    });
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
    _scanTimeout?.cancel();
    _rssiTimer?.cancel();
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

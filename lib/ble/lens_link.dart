/// BLE transport for one lens, behind a small interface so the session logic (lib/hub) can be
/// tested offline with a fake.
///
/// Implementation: universal_ble (Navideck, BSD-3). Chosen over flutter_blue_plus because FBP
/// moved to a custom licence that requires a paid licence for for-profit use and sends a
/// build-time licence ping (this app must work with no network dependency); universal_ble is
/// actively maintained, BSD-3, supports Android + iOS (and desktop), has OS-level pairing
/// (createBond on Android), MTU requests, per-device command queues and notification streams.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'lens_ad.dart';

/// What the session needs from one lens.
abstract class LensLink {
  String get deviceId;
  LensSide get side;

  /// Control replies (0x5402), raw packets as received.
  Stream<Uint8List> get notifications;

  /// true/false whenever the link goes up/down.
  Stream<bool> get connectionChanges;

  bool get isConnected;

  /// Connect, discover services, bond if needed, raise MTU, subscribe to 0x5402.
  Future<void> connect({Duration timeout = const Duration(seconds: 15)});

  /// Write one already-framed packet to 0x5401 (write without response).
  Future<void> write(Uint8List packet);

  Future<void> disconnect();

  /// EvenFile service (notification files): replies from 0x7402. Default: not supported.
  Stream<Uint8List> get fileNotifications => const Stream.empty();

  /// Subscribe to 0x7402 (idempotent).
  Future<void> enableFileChannel() async => throw UnsupportedError('file channel not supported');

  /// Write one EFS frame to 0x7401 (write without response).
  Future<void> writeFile(Uint8List packet) async => throw UnsupportedError('file channel not supported');
}

/// One advertisement / known device that looks like a G2 lens.
class ScannedLens {
  ScannedLens({required this.deviceId, required this.name, required this.lens, this.rssi, this.serial});
  final String deviceId;
  final String name;
  final LensName lens;
  final int? rssi;
  final String? serial;
}

/// A complete or partial pair found by scanning.
class LensPair {
  LensPair(this.pairId);
  final String pairId;
  ScannedLens? left;
  ScannedLens? right;
  String? get serial => right?.serial ?? left?.serial;
  bool get complete => left != null && right != null;
}

class UniversalBleLens extends LensLink {
  UniversalBleLens(this.deviceId, this.side);

  @override
  final String deviceId;
  @override
  final LensSide side;

  final _notify = StreamController<Uint8List>.broadcast();
  final _conn = StreamController<bool>.broadcast();
  StreamSubscription<Uint8List>? _valueSub;
  StreamSubscription<bool>? _connSub;
  bool _connected = false;

  @override
  Stream<Uint8List> get notifications => _notify.stream;
  @override
  Stream<bool> get connectionChanges => _conn.stream;
  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    _connSub ??= UniversalBle.connectionStream(deviceId).listen((up) {
      _connected = up;
      _conn.add(up);
    });
    await UniversalBle.connect(
      deviceId,
      timeout: timeout,
      platformConfig: ConnectionPlatformConfig(android: AndroidConnectionOptions(closeGattOnDetach: true)),
    );
    _connected = true;
    await UniversalBle.discoverServices(deviceId);
    if (Platform.isAndroid) {
      // The glasses need an LE Secure Connections bond; connected-but-unbonded lenses accept
      // writes and then never advance protocol state (docs/protocol.md 1.1).
      try {
        final paired = await UniversalBle.isPaired(deviceId);
        if (paired != true) await UniversalBle.pair(deviceId);
      } catch (_) {/* bonding may already be in progress; writes will trigger it */}
      try {
        await UniversalBle.requestMtu(deviceId, 512); // firmware floor is 247
      } catch (_) {}
      try {
        await UniversalBle.requestConnectionPriority(deviceId, BleConnectionPriority.highPerformance);
      } catch (_) {}
    }
    _valueSub ??= UniversalBle.characteristicValueStream(deviceId, charNotify).listen(_notify.add);
    await UniversalBle.subscribeNotifications(deviceId, serviceControl, charNotify);
  }

  @override
  Future<void> write(Uint8List packet) =>
      UniversalBle.write(deviceId, serviceControl, charWrite, packet, withoutResponse: true);

  final _fileNotify = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _fileSub;
  bool _fileOn = false;

  @override
  Stream<Uint8List> get fileNotifications => _fileNotify.stream;

  @override
  Future<void> enableFileChannel() async {
    if (_fileOn) return;
    _fileSub ??= UniversalBle.characteristicValueStream(deviceId, charFileNotify).listen(_fileNotify.add);
    await UniversalBle.subscribeNotifications(deviceId, serviceFile, charFileNotify);
    _fileOn = true;
  }

  @override
  Future<void> writeFile(Uint8List packet) =>
      UniversalBle.write(deviceId, serviceFile, charFileWrite, packet, withoutResponse: true);

  @override
  Future<void> disconnect() async {
    _fileOn = false;
    try {
      await UniversalBle.disconnect(deviceId, timeout: const Duration(seconds: 5));
    } catch (_) {}
    _connected = false;
    // A session creates new lens objects on every (re)connect: release this one's listeners on
    // the plugin's global streams, or every reconnect would add another set that never goes away.
    final subs = [_valueSub, _connSub, _fileSub];
    _valueSub = null;
    _connSub = null;
    _fileSub = null;
    for (final s in subs) {
      unawaited(s?.cancel());
    }
  }
}

/// Scanning for lenses (names `Even G2_<pair>_<L|R>_<mac tail>`).
class LensScanner {
  final _pairs = <String, LensPair>{};
  StreamSubscription<BleDevice>? _sub;

  Future<bool> bluetoothOn() async =>
      await UniversalBle.getBluetoothAvailabilityState() == AvailabilityState.poweredOn;

  /// Emits the current pair table every time a lens is seen. Also merges lenses the OS is
  /// already connected to (they do not advertise).
  Stream<List<LensPair>> scan() {
    final out = StreamController<List<LensPair>>();
    var cancelled = false;
    _pairs.clear();
    void add(BleDevice d) {
      final parsed = parseName(d.name);
      if (parsed == null) return;
      String? serial;
      for (final m in d.manufacturerDataList) {
        if (m.companyId == manufacturerId) serial = parseManufacturer(m.payload)?.serial;
      }
      final pair = _pairs.putIfAbsent(parsed.pairId, () => LensPair(parsed.pairId));
      final lens = ScannedLens(deviceId: d.deviceId, name: d.name ?? '', lens: parsed, rssi: d.rssi, serial: serial);
      if (parsed.side == LensSide.right) {
        pair.right = lens;
      } else {
        pair.left = lens;
      }
      if (!out.isClosed) out.add(_pairs.values.toList());
    }

    out.onListen = () async {
      try {
        final known = await UniversalBle.getSystemDevices(withServices: [serviceControl]);
        known.forEach(add);
      } catch (_) {}
      // Cancelled while the system devices were being read: do not start a scan that nobody
      // would stop (it would run until the app dies).
      if (cancelled) return;
      _sub = UniversalBle.scanStream.listen(add);
      try {
        await UniversalBle.startScan(
          platformConfig: PlatformConfig(android: AndroidOptions(scanMode: AndroidScanMode.lowLatency)),
        );
        if (cancelled) await stop(); // cancelled while the scan was starting
      } catch (e) {
        if (!out.isClosed) out.addError(e);
      }
    };
    out.onCancel = () {
      cancelled = true;
      return stop();
    };
    return out.stream;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }
}

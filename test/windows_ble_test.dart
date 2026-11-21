import 'dart:async';

import 'package:esp_ink/core/ble_models.dart';
import 'package:esp_ink/core/native_ble.dart' show NativeBle;
import 'package:esp_ink/core/protocol.dart'
    show serviceUuid, ctrlUuid, dataUuid, evtUuid;
import 'package:esp_ink/core/windows_ble.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

Matcher _code(String code) =>
    isA<NativeBleException>().having((error) => error.code, 'code', code);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakePort port;
  late WindowsBle ble;

  setUp(() {
    port = _FakePort();
    ble = WindowsBle(port: port);
  });

  tearDown(() async {
    await ble.dispose();
    await port.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'construction and unused disposal never initialize the plugin',
    () async {
      expect(port.initializations, 0);
      expect(ble.isConnected, isFalse);
      expect(ble.isScanning, isFalse);
      expect(ble.mtu, 23);
      final first = ble.dispose();
      expect(identical(first, ble.dispose()), isTrue);
      await first;
      expect(port.initializations, 0);
      expect(port.calls, isEmpty);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final unopenedDefault = WindowsBle();
      await unopenedDefault.dispose();
    },
  );

  test('unsupported platform does not activate UniversalBle', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final unsupported = WindowsBle();
    await expectLater(
      unsupported.startScan(),
      throwsA(_code('unsupported_platform')),
    );
    await unsupported.disconnect();
    await unsupported.dispose();
  });

  test(
    'scan filters the service, preserves names and sorts latest RSSI',
    () async {
      final results = <List<DiscoveredDevice>>[];
      final states = <bool>[];
      final scans = ble.scanResults.listen(results.add);
      final scanning = ble.scanStateChanges.listen(states.add);
      await ble.startScan();
      port.ads.add(BleDevice(deviceId: 'other', name: 'ESP-INK', services: []));
      port.ads.add(
        BleDevice(
          deviceId: 'AA',
          name: '我的屏幕',
          rssi: -80,
          services: [serviceUuid.toUpperCase()],
        ),
      );
      port.ads.add(
        BleDevice(
          deviceId: 'BB',
          name: null,
          rssi: -40,
          services: [serviceUuid],
        ),
      );
      port.ads.add(
        BleDevice(
          deviceId: 'AA',
          name: null,
          rssi: -30,
          services: [serviceUuid],
        ),
      );
      await _flush();
      expect(results.last.map((d) => d.id), ['aa', 'bb']);
      expect(results.last.first.name, '我的屏幕');
      expect(results.last.first.rssi, -30);
      expect(results.last.last.name, '未命名 ESP-INK');
      expect(() => results.last.clear(), throwsUnsupportedError);
      await ble.stopScan();
      port.ads.add(
        BleDevice(deviceId: 'CC', name: 'late', services: [serviceUuid]),
      );
      await _flush();
      expect(results.last.length, 2);
      expect(states, [true, false]);
      expect(port.initializations, 1);
      await scans.cancel();
      await scanning.cancel();
    },
  );

  test('stop before availability returns never starts a native scan', () async {
    final gate = Completer<AvailabilityState>();
    port.onAvailability = () => gate.future;
    final scan = ble.startScan();
    final cancelled = expectLater(scan, throwsA(_code('cancelled')));
    await _flush();
    final stop = ble.stopScan();
    gate.complete(AvailabilityState.poweredOn);
    await stop;
    await cancelled;
    expect(port.calls, isNot(contains('startScan')));
    expect(ble.isScanning, isFalse);
  });

  test('scan stop is serialized after an in-flight scan start', () async {
    final gate = Completer<void>();
    port.onStartScan = () => gate.future;
    final scan = ble.startScan();
    final cancelled = expectLater(scan, throwsA(_code('cancelled')));
    await _flush();
    final stop = ble.stopScan();
    expect(ble.isScanning, isFalse);
    gate.complete();
    await stop;
    await cancelled;
    expect(port.calls.where((c) => c.endsWith('Scan')), [
      'startScan',
      'stopScan',
    ]);
  });

  for (final (availability, code) in [
    (AvailabilityState.poweredOff, 'bluetooth_off'),
    (AvailabilityState.unsupported, 'bluetooth_unavailable'),
    (AvailabilityState.unauthorized, 'permission_denied'),
  ]) {
    test('$availability produces a useful error before scanning', () async {
      port.radio = availability;
      await expectLater(ble.startScan(), throwsA(_code(code)));
      expect(port.calls, isNot(contains('startScan')));
      expect(ble.isScanning, isFalse);
    });
  }

  test(
    'CCCD and actual MTU must finish before connected is published',
    () async {
      final subscription = Completer<void>();
      final mtu = Completer<int>();
      port.onSubscribe = () => subscription.future;
      port.onMtu = () => mtu.future;
      final states = <bool>[];
      final events = ble.connectionChanges.listen(states.add);
      final connect = ble.connect('AA');
      await _flush();
      expect(port.notificationListenerAtSubscribe, isTrue);
      expect(ble.isConnected, isFalse);
      expect(port.calls, isNot(contains('mtu:aa')));
      subscription.complete();
      await _flush();
      expect(ble.isConnected, isFalse);
      mtu.complete(185);
      await connect;
      await _flush();
      expect(ble.mtu, 185);
      expect(states, [true]);
      expect(
        port.calls,
        containsAllInOrder([
          'stopScan',
          'connect:aa',
          'discover:aa',
          'subscribe:aa',
          'mtu:aa',
        ]),
      );
      await events.cancel();
    },
  );

  test(
    'notifications are copied and ignored before ready or after disconnect',
    () async {
      final gate = Completer<void>();
      port.onSubscribe = () => gate.future;
      final received = <Uint8List>[];
      final events = ble.notifications.listen(received.add);
      final connect = ble.connect('AA');
      await _flush();
      port.values('aa').add(Uint8List.fromList([1]));
      gate.complete();
      await connect;
      final bytes = Uint8List.fromList([0x81, 0, 0]);
      port.values('aa').add(bytes);
      bytes[0] = 0;
      await _flush();
      expect(received.single, [0x81, 0, 0]);
      await ble.disconnect();
      port.values('aa').add(Uint8List.fromList([2]));
      await _flush();
      expect(received.length, 1);
      expect(ble.mtu, 23);
      await events.cancel();
    },
  );

  test(
    'missing B2 service or mandatory characteristic properties is rejected',
    () async {
      for (final services in [
        <BleService>[],
        [BleService(serviceUuid, [])],
        [_service(dataProperty: CharacteristicProperty.write)],
        [_service(eventProperty: CharacteristicProperty.indicate)],
        [_service(), _service()],
      ]) {
        port.services = services;
        await expectLater(
          ble.connect('AA'),
          throwsA(isA<NativeBleException>()),
        );
        expect(ble.isConnected, isFalse);
        expect(port.calls, isNot(contains('subscribe:aa')));
        port.calls.clear();
      }
    },
  );

  test('failed CCCD never exposes a writable connection', () async {
    port.onSubscribe = () async {
      throw PlatformException(code: 'cccd_failed', message: '订阅失败');
    };
    await expectLater(ble.connect('AA'), throwsA(_code('cccd_failed')));
    expect(ble.isConnected, isFalse);
    await expectLater(
      ble.writeCtrl(Uint8List.fromList([1])),
      throwsA(isA<NativeBleException>()),
    );
    expect(port.writes, isEmpty);
    expect(port.calls, contains('disconnect:aa'));
  });

  test(
    'MTU below 39 fails while 39..47 warns without inventing a larger value',
    () async {
      port.actualMtu = 38;
      await expectLater(ble.connect('AA'), throwsA(_code('mtu_too_small')));
      expect(ble.isConnected, isFalse);
      final warnings = <String>[];
      final events = ble.errors.listen(warnings.add);
      port.actualMtu = 39;
      await ble.connect('AA');
      await _flush();
      expect(ble.mtu, 39);
      expect(ble.isConnected, isTrue);
      expect(warnings.single, contains('较长设备名称'));
      await ble.writeData(Uint8List(36));
      await expectLater(
        ble.writeData(Uint8List(37)),
        throwsA(isA<NativeBleException>()),
      );
      expect(port.writes.single.value.length, 36);
      await events.cancel();
    },
  );

  test(
    'CTRL and DATA share FIFO, use distinct write modes and copy input',
    () async {
      await ble.connect('AA');
      final first = Completer<void>();
      port.onWrite = (_) =>
          port.writes.length == 1 ? first.future : Future<void>.value();
      final original = Uint8List.fromList([1, 2]);
      final ctrl = ble.writeCtrl(original);
      final data = ble.writeData(Uint8List.fromList([3]));
      original[0] = 9;
      await _flush();
      expect(port.writes.length, 1);
      first.complete();
      await Future.wait([ctrl, data]);
      expect(port.writes.map((w) => w.characteristic), [ctrlUuid, dataUuid]);
      expect(port.writes.map((w) => w.withoutResponse), [false, true]);
      expect(port.writes.first.value, [1, 2]);
    },
  );

  test(
    'MTU 517 never permits an attribute above 512 or an empty write',
    () async {
      await ble.connect('AA');
      await ble.writeCtrl(Uint8List(512));
      await ble.writeData(Uint8List(512));
      for (final value in [Uint8List(513), Uint8List(0)]) {
        await expectLater(
          ble.writeCtrl(value),
          throwsA(isA<NativeBleException>()),
        );
        await expectLater(
          ble.writeData(value),
          throwsA(isA<NativeBleException>()),
        );
      }
      expect(port.writes.map((w) => w.value.length), [512, 512]);
    },
  );

  test(
    'ambiguous write error is not retried and queued writes cannot escape',
    () async {
      await ble.connect('AA');
      port.onWrite = (_) async {
        throw PlatformException(code: 'write_failed', message: '本地写入失败');
      };
      final first = ble.writeCtrl(Uint8List.fromList([1]));
      final second = ble.writeData(Uint8List.fromList([2]));
      final failedFirst = expectLater(first, throwsA(_code('write_failed')));
      final failedSecond = expectLater(second, throwsA(_code('cancelled')));
      await Future.wait([failedFirst, failedSecond]);
      expect(port.writes.length, 1);
      expect(ble.isConnected, isFalse);
    },
  );

  test(
    'disconnect cancels queued writes and an in-flight write completion',
    () async {
      await ble.connect('AA');
      final gate = Completer<void>();
      port.onWrite = (_) => gate.future;
      final first = ble.writeData(Uint8List.fromList([1]));
      final second = ble.writeCtrl(Uint8List.fromList([2]));
      final failures = [
        expectLater(first, throwsA(_code('cancelled'))),
        expectLater(second, throwsA(_code('cancelled'))),
      ];
      await _flush();
      await ble.disconnect();
      gate.complete();
      await Future.wait(failures);
      expect(port.writes.length, 1);
      expect(ble.isConnected, isFalse);
    },
  );

  test(
    'a cancelled late connect is closed before a replacement session starts',
    () async {
      final gate = Completer<void>();
      port.onConnect = () => gate.future;
      final connecting = ble.connect('AA');
      final cancelled = expectLater(connecting, throwsA(_code('cancelled')));
      await _flush();
      final closing = ble.disconnect();
      await _flush();
      expect(port.calls, contains('disconnect:aa'));
      final replacing = ble.connect('BB');
      await _flush();
      expect(port.calls, isNot(contains('connect:bb')));
      gate.complete();
      await Future.wait([closing, cancelled, replacing]);
      expect(port.calls.where((c) => c == 'disconnect:aa').length, 2);
      expect(ble.isConnected, isTrue);
      expect(port.calls, contains('connect:bb'));
    },
  );

  test(
    'remote disconnect and adapter removal invalidate a ready connection',
    () async {
      await ble.connect('AA');
      port.connections('aa').add(false);
      await _flush();
      expect(ble.isConnected, isFalse);
      expect(ble.mtu, 23);
      await ble.connect('BB');
      final errors = <String>[];
      final events = ble.errors.listen(errors.add);
      port.availabilityEvents.add(AvailabilityState.poweredOff);
      await _flush();
      expect(ble.isConnected, isFalse);
      expect(errors.single, contains('蓝牙未开启'));
      await events.cancel();
    },
  );

  test(
    'native timeout closes the session and does not report connected',
    () async {
      await ble.dispose();
      ble = WindowsBle(
        port: port,
        operationTimeout: const Duration(milliseconds: 15),
      );
      final gate = Completer<void>();
      port.onSubscribe = () => gate.future;
      await expectLater(ble.connect('AA'), throwsA(_code('timeout')));
      expect(ble.isConnected, isFalse);
      expect(port.calls, contains('disconnect:aa'));
      gate.complete();
    },
  );

  test(
    'Windows settings uses the desktop runner channel without activating BLE',
    () async {
      const channel = MethodChannel('io.github.robbieht.espink/desktop');
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      try {
        await ble.openBluetoothSettings();
        expect(calls, ['openBluetoothSettings']);
        expect(port.initializations, 0);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  test(
    'NativeBle facade delegates Windows streams, commands and disposal',
    () async {
      final facade = NativeBle(windowsBle: ble);
      final scans = <List<DiscoveredDevice>>[];
      final connections = <bool>[];
      final notifications = <Uint8List>[];
      final scanStates = <bool>[];
      final errors = <String>[];
      final subscriptions = <StreamSubscription<dynamic>>[
        facade.scanResults.listen(scans.add),
        facade.connectionChanges.listen(connections.add),
        facade.notifications.listen(notifications.add),
        facade.scanStateChanges.listen(scanStates.add),
        facade.errors.listen(errors.add),
      ];
      expect(facade.supported, isTrue);
      expect(port.initializations, 0);
      await facade.startScan();
      expect(facade.isScanning, isTrue);
      port.ads.add(
        BleDevice(deviceId: 'AA', name: 'screen', services: [serviceUuid]),
      );
      await facade.stopScan();
      port.actualMtu = 47;
      await facade.connect('AA');
      expect(facade.isConnected, isTrue);
      expect(facade.mtu, 47);
      port.values('aa').add(Uint8List.fromList([0x81]));
      await facade.writeCtrl(Uint8List.fromList([1]));
      await facade.writeData(Uint8List.fromList([2]));
      await facade.disconnect();
      await _flush();
      expect(scans.last.single.id, 'aa');
      expect(connections, [true, false]);
      expect(notifications.single, [0x81]);
      expect(scanStates, [true, false]);
      expect(errors.single, contains('较长设备名称'));
      expect(port.writes.map((w) => w.withoutResponse), [false, true]);
      expect(facade.isConnected, isFalse);
      expect(facade.mtu, 23);
      await Future.wait(subscriptions.map((s) => s.cancel()));
      await facade.dispose();
      await expectLater(facade.startScan(), throwsA(isA<NativeBleException>()));
    },
  );
}

BleService _service({
  CharacteristicProperty dataProperty =
      CharacteristicProperty.writeWithoutResponse,
  CharacteristicProperty eventProperty = CharacteristicProperty.notify,
}) => BleService(serviceUuid, [
  BleCharacteristic(ctrlUuid, [CharacteristicProperty.write], []),
  BleCharacteristic(dataUuid, [dataProperty], []),
  BleCharacteristic(evtUuid, [eventProperty], []),
]);

class _Write {
  _Write(this.id, this.characteristic, this.value, this.withoutResponse);
  final String id;
  final String characteristic;
  final Uint8List value;
  final bool withoutResponse;
}

class _FakePort implements WindowsBlePort {
  final ads = StreamController<BleDevice>.broadcast(sync: true);
  final availabilityEvents = StreamController<AvailabilityState>.broadcast(
    sync: true,
  );
  final _connections = <String, StreamController<bool>>{};
  final _values = <String, StreamController<Uint8List>>{};
  final calls = <String>[];
  final writes = <_Write>[];
  int initializations = 0;
  int actualMtu = 517;
  bool notificationListenerAtSubscribe = false;
  AvailabilityState radio = AvailabilityState.poweredOn;
  List<BleService> services = [_service()];
  Future<AvailabilityState> Function()? onAvailability;
  Future<void> Function()? onStartScan;
  Future<void> Function()? onConnect;
  Future<void> Function()? onSubscribe;
  Future<int> Function()? onMtu;
  Future<void> Function(_Write)? onWrite;

  StreamController<bool> connections(String id) => _connections.putIfAbsent(
    id,
    () => StreamController<bool>.broadcast(sync: true),
  );
  StreamController<Uint8List> values(String id) => _values.putIfAbsent(
    id,
    () => StreamController<Uint8List>.broadcast(sync: true),
  );
  @override
  void initialize() => initializations++;
  @override
  Stream<BleDevice> get advertisements => ads.stream;
  @override
  Stream<AvailabilityState> get availabilityChanges =>
      availabilityEvents.stream;
  @override
  Stream<bool> connectionChanges(String deviceId) =>
      connections(deviceId).stream;
  @override
  Stream<Uint8List> notifications(String deviceId) => values(deviceId).stream;
  @override
  Future<AvailabilityState> availability() async {
    calls.add('availability');
    return onAvailability == null ? radio : await onAvailability!();
  }

  @override
  Future<void> startScan() async {
    calls.add('startScan');
    await onStartScan?.call();
  }

  @override
  Future<void> stopScan() async => calls.add('stopScan');
  @override
  Future<void> connect(String deviceId) async {
    calls.add('connect:$deviceId');
    await onConnect?.call();
  }

  @override
  Future<void> disconnect(String deviceId) async =>
      calls.add('disconnect:$deviceId');
  @override
  Future<List<BleService>> discoverServices(String deviceId) async {
    calls.add('discover:$deviceId');
    return services;
  }

  @override
  Future<void> subscribe(String deviceId) async {
    calls.add('subscribe:$deviceId');
    notificationListenerAtSubscribe = values(deviceId).hasListener;
    await onSubscribe?.call();
  }

  @override
  Future<int> mtu(String deviceId) async {
    calls.add('mtu:$deviceId');
    return onMtu == null ? actualMtu : await onMtu!();
  }

  @override
  Future<void> write(
    String deviceId,
    String characteristic,
    Uint8List value, {
    required bool withoutResponse,
  }) async {
    final write = _Write(deviceId, characteristic, value, withoutResponse);
    writes.add(write);
    await onWrite?.call(write);
  }

  Future<void> dispose() async {
    await Future.wait([
      ads.close(),
      availabilityEvents.close(),
      ..._connections.values.map((c) => c.close()),
      ..._values.values.map((c) => c.close()),
    ]);
  }
}

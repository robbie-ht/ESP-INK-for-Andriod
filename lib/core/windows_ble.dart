import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

import 'ble_models.dart';
import 'protocol.dart' show serviceUuid, ctrlUuid, dataUuid, evtUuid;
import 'transport.dart';

/// Injectable boundary for WinRT. Constructing a transport never starts a plugin.
abstract interface class WindowsBlePort {
  void initialize();
  Stream<BleDevice> get advertisements;
  Stream<AvailabilityState> get availabilityChanges;
  Stream<bool> connectionChanges(String deviceId);
  Stream<Uint8List> notifications(String deviceId);
  Future<AvailabilityState> availability();
  Future<void> startScan();
  Future<void> stopScan();
  Future<void> connect(String deviceId);
  Future<void> disconnect(String deviceId);
  Future<List<BleService>> discoverServices(String deviceId);
  Future<void> subscribe(String deviceId);
  Future<int> mtu(String deviceId);
  Future<void> write(
    String deviceId,
    String characteristic,
    Uint8List value, {
    required bool withoutResponse,
  });
}

class _UniversalBlePort implements WindowsBlePort {
  const _UniversalBlePort(this.timeout);
  final Duration timeout;

  @override
  void initialize() {
    // UniversalBle's Windows auto queue is parallel. B2 uses one GATT link.
    UniversalBle.queueType = QueueType.perDevice;
  }

  @override
  Stream<BleDevice> get advertisements => UniversalBle.scanStream;
  @override
  Stream<AvailabilityState> get availabilityChanges =>
      UniversalBle.availabilityStream;
  @override
  Stream<bool> connectionChanges(String deviceId) =>
      UniversalBle.connectionStream(deviceId);
  @override
  Stream<Uint8List> notifications(String deviceId) =>
      UniversalBle.characteristicValueStream(
        deviceId,
        evtUuid,
        serviceId: serviceUuid,
      );
  @override
  Future<AvailabilityState> availability() =>
      UniversalBle.getBluetoothAvailabilityState();
  @override
  Future<void> startScan() => UniversalBle.startScan(
    scanFilter: ScanFilter(withServices: [serviceUuid]),
  );
  @override
  Future<void> stopScan() => UniversalBle.stopScan();
  @override
  Future<void> connect(String deviceId) =>
      UniversalBle.connect(deviceId, timeout: timeout);
  @override
  Future<void> disconnect(String deviceId) =>
      UniversalBle.disconnect(deviceId, timeout: timeout);
  @override
  Future<List<BleService>> discoverServices(String deviceId) =>
      UniversalBle.discoverServices(deviceId, timeout: timeout);
  @override
  Future<void> subscribe(String deviceId) =>
      UniversalBle.subscribeNotifications(
        deviceId,
        serviceUuid,
        evtUuid,
        timeout: timeout,
      );
  @override
  Future<int> mtu(String deviceId) =>
      // On Windows this reads GattSession.MaxPduSize; it does not force 517.
      UniversalBle.requestMtu(deviceId, 517, timeout: timeout);
  @override
  Future<void> write(
    String deviceId,
    String characteristic,
    Uint8List value, {
    required bool withoutResponse,
  }) => UniversalBle.write(
    deviceId,
    serviceUuid,
    characteristic,
    value,
    withoutResponse: withoutResponse,
    timeout: timeout,
  );
}

/// One Windows GATT link, with the same public API as the NativeBle facade.
/// A completed write only confirms local GATT delivery, not a firmware job.
class WindowsBle implements EspInkTransport {
  WindowsBle({
    WindowsBlePort? port,
    this.operationTimeout = const Duration(seconds: 20),
  }) : _providedPort = port;

  final WindowsBlePort? _providedPort;
  final Duration operationTimeout;
  static const _desktop = MethodChannel('io.github.robbieht.espink/desktop');
  final _notifications = StreamController<Uint8List>.broadcast();
  final _connections = StreamController<bool>.broadcast();
  final _scans = StreamController<List<DiscoveredDevice>>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _scanStates = StreamController<bool>.broadcast();
  final _devices = <String, DiscoveredDevice>{};
  WindowsBlePort? _port;
  StreamSubscription<BleDevice>? _advertisements;
  StreamSubscription<AvailabilityState>? _availability;
  _WindowsLink? _link;
  Future<void> _scanTail = Future<void>.value();
  Future<void> _writeTail = Future<void>.value();
  Future<void> _closeTail = Future<void>.value();
  Future<void>? _scanStart;
  Future<void>? _disposeFuture;
  bool _disposed = false;
  bool _disposing = false;
  bool _scanning = false;
  bool _scanWanted = false;
  bool _connected = false;
  int _scanGeneration = 0;
  int _generation = 0;
  int _mtu = 23;

  bool get supported =>
      _providedPort != null ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows);
  @override
  int get mtu => _mtu;
  @override
  bool get isConnected => _connected;
  bool get isScanning => _scanning;
  @override
  Stream<Uint8List> get notifications => _notifications.stream;
  @override
  Stream<bool> get connectionChanges => _connections.stream;
  Stream<List<DiscoveredDevice>> get scanResults => _scans.stream;
  Stream<String> get errors => _errors.stream;
  Stream<bool> get scanStateChanges => _scanStates.stream;

  static String _uuid(String value) =>
      value.replaceAll('{', '').replaceAll('}', '').toLowerCase();

  void _checkUsable() {
    if (_disposed || _disposing) {
      throw const NativeBleException('蓝牙服务已关闭，请重新进入设备页面。');
    }
    if (!supported) {
      throw const NativeBleException(
        'Windows 蓝牙服务仅支持 Windows；当前平台可使用演示模式。',
        code: 'unsupported_platform',
      );
    }
  }

  static NativeBleException _error(Object error) {
    if (error is NativeBleException) return error;
    if (error is TimeoutException) {
      return const NativeBleException(
        'Windows 蓝牙操作超时，请检查设备距离和系统蓝牙后重新连接。',
        code: 'timeout',
      );
    }
    if (error is PlatformException) {
      return NativeBleException(
        error.message ?? 'Windows 蓝牙操作失败，请重新连接。',
        code: error.code,
      );
    }
    if (error is MissingPluginException) {
      return const NativeBleException(
        '此安装包未包含 Windows 蓝牙服务，请解压完整安装包后运行。',
        code: 'missing_plugin',
      );
    }
    return NativeBleException('Windows 蓝牙操作失败：$error');
  }

  WindowsBlePort _activate() {
    _checkUsable();
    if (_port case final port?) return port;
    final port = _providedPort ?? _UniversalBlePort(operationTimeout);
    port.initialize();
    _port = port;
    _advertisements = port.advertisements.listen(
      _onAdvertisement,
      onError: (Object error) => _report(error),
    );
    _availability = port.availabilityChanges.listen((state) {
      if (_disposed || _disposing || state == AvailabilityState.poweredOn) {
        return;
      }
      if (!_scanning && !_scanWanted && _link == null) return;
      _scanWanted = false;
      _scanGeneration++;
      _setScanning(false);
      _report(_availabilityError(state));
      final link = _link;
      if (link != null) unawaited(_closeLink(link));
    }, onError: (Object error) => _report(error));
    return port;
  }

  void _report(Object error) {
    if (!_disposed && !_disposing) _errors.add(_error(error).message);
  }

  static NativeBleException _availabilityError(AvailabilityState state) =>
      switch (state) {
        AvailabilityState.poweredOff => const NativeBleException(
          'Windows 蓝牙未开启，请在系统设置中开启。',
          code: 'bluetooth_off',
        ),
        AvailabilityState.unsupported => const NativeBleException(
          '未检测到支持 BLE 的蓝牙适配器。',
          code: 'bluetooth_unavailable',
        ),
        AvailabilityState.unauthorized => const NativeBleException(
          'Windows 未允许此应用访问蓝牙，请检查系统隐私设置。',
          code: 'permission_denied',
        ),
        _ => const NativeBleException(
          'Windows 蓝牙尚未就绪，请稍后重试。',
          code: 'bluetooth_unavailable',
        ),
      };

  Future<void> _requireRadio(WindowsBlePort port) async {
    final state = await port.availability().timeout(operationTimeout);
    if (state != AvailabilityState.poweredOn) throw _availabilityError(state);
  }

  void _setScanning(bool value) {
    if (_disposed || _scanning == value) return;
    _scanning = value;
    _scanStates.add(value);
  }

  void _setConnected(bool value) {
    if (!value) _mtu = 23;
    if (_disposed || _connected == value) return;
    _connected = value;
    _connections.add(value);
  }

  void _onAdvertisement(BleDevice device) {
    if (!_scanning || !_scanWanted || _disposing || _disposed) return;
    if (device.deviceId.isEmpty ||
        !device.services.any((uuid) => _uuid(uuid) == _uuid(serviceUuid))) {
      return;
    }
    final id = device.deviceId.toLowerCase();
    final old = _devices[id];
    final name = (device.rawName ?? device.name ?? '').trim();
    _devices[id] = DiscoveredDevice(
      id: id,
      name: name.isNotEmpty ? name : (old?.name ?? '未命名 ESP-INK'),
      rssi: device.rssi ?? old?.rssi ?? -127,
    );
    final devices = _devices.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    _scans.add(List.unmodifiable(devices));
  }

  Future<void> _queueScan(Future<void> Function() operation) {
    final result = _scanTail.then((_) => operation());
    _scanTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _checkScan(int generation) {
    _checkUsable();
    if (!_scanWanted || generation != _scanGeneration) {
      throw const NativeBleException('扫描已取消。', code: 'cancelled');
    }
  }

  Future<void> startScan() async {
    _checkUsable();
    if (_scanWanted && _scanStart != null) return _scanStart!;
    final generation = ++_scanGeneration;
    _scanWanted = true;
    final result = _queueScan(() async {
      try {
        _checkScan(generation);
        final port = _activate();
        await _requireRadio(port);
        _checkScan(generation);
        _devices.clear();
        _scans.add(const []);
        _setScanning(true);
        await port.startScan().timeout(operationTimeout);
        _checkScan(generation);
      } catch (error) {
        if (generation == _scanGeneration) {
          _scanWanted = false;
          _setScanning(false);
        }
        throw _error(error);
      }
    });
    _scanStart = result;
    return result;
  }

  Future<void> stopScan() async {
    _checkUsable();
    _scanGeneration++;
    _scanWanted = false;
    _scanStart = null;
    _setScanning(false);
    return _stopScan();
  }

  Future<void> _stopScan() => _queueScan(() async {
    if (_port == null) return;
    try {
      await _port!.stopScan().timeout(operationTimeout);
    } catch (error) {
      throw _error(error);
    }
  });

  bool _current(_WindowsLink link) =>
      !_disposed &&
      !_disposing &&
      identical(_link, link) &&
      link.generation == _generation &&
      !link.cancelled.isCompleted;

  void _checkLink(_WindowsLink link) {
    if (!_current(link)) {
      throw const NativeBleException('蓝牙操作已取消。', code: 'cancelled');
    }
  }

  Future<T> _duringLink<T>(_WindowsLink link, Future<T> operation) async {
    final value = await Future.any<T>([
      operation.timeout(operationTimeout),
      link.cancelled.future.then<T>((_) {
        throw const NativeBleException('蓝牙操作已取消。', code: 'cancelled');
      }),
    ]);
    _checkLink(link);
    return value;
  }

  void _validateServices(List<BleService> services) {
    final matches = services.where((s) => _uuid(s.uuid) == _uuid(serviceUuid));
    if (matches.length != 1) {
      throw const NativeBleException(
        '此设备未提供唯一的 ESP-INK B2 蓝牙服务，请检查固件。',
        code: 'invalid_services',
      );
    }
    for (final (uuid, property) in [
      (ctrlUuid, CharacteristicProperty.write),
      (dataUuid, CharacteristicProperty.writeWithoutResponse),
      (evtUuid, CharacteristicProperty.notify),
    ]) {
      final chars = matches.single.characteristics.where(
        (c) => _uuid(c.uuid) == _uuid(uuid),
      );
      if (chars.length != 1 || !chars.single.properties.contains(property)) {
        throw const NativeBleException(
          '设备的 ESP-INK B2 蓝牙特征不完整或读写属性不匹配，请检查固件。',
          code: 'invalid_characteristics',
        );
      }
    }
  }

  Future<void> connect(String id) async {
    _checkUsable();
    if (_link != null) {
      throw const NativeBleException('已有连接或正在连接，请先断开。');
    }
    if (id.trim().isEmpty) throw const NativeBleException('蓝牙设备地址不能为空。');
    final link = _WindowsLink(id.toLowerCase(), ++_generation);
    _link = link;
    try {
      await _closeTail;
      _checkLink(link);
      final port = _activate();
      await _duringLink(link, stopScan());
      await _duringLink(link, _requireRadio(port));
      link.connection = port
          .connectionChanges(link.id)
          .listen(
            (connected) {
              if (!_current(link) || connected) return;
              unawaited(_closeLink(link));
            },
            onError: (Object error) {
              if (!_current(link)) return;
              _report(error);
              unawaited(_closeLink(link));
            },
          );
      link.connectPending = true;
      link.nativeConnect = port.connect(link.id).whenComplete(() {
        link.connectPending = false;
      });
      await _duringLink(link, link.nativeConnect!);
      final services = await _duringLink(link, port.discoverServices(link.id));
      _validateServices(services);
      link.values = port
          .notifications(link.id)
          .listen(
            (value) {
              if (_current(link) && _connected) {
                _notifications.add(Uint8List.fromList(value));
              }
            },
            onError: (Object error) {
              if (!_current(link)) return;
              _report(error);
              unawaited(_closeLink(link));
            },
          );
      await _duringLink(link, port.subscribe(link.id));
      final negotiated = await _duringLink(link, port.mtu(link.id));
      if (negotiated < 39 || negotiated > 517) {
        throw NativeBleException(
          'Windows 当前协商的 MTU 为 $negotiated，ESP-INK 连接需要至少 39。请更新蓝牙驱动后重新连接。',
          code: 'mtu_too_small',
        );
      }
      _mtu = negotiated;
      if (negotiated < 48) {
        _errors.add('当前 MTU 为 $negotiated，完整状态或较长设备名称的设置可能不支持，建议更新蓝牙驱动后重新连接。');
      }
      _setConnected(true);
    } catch (error) {
      await _closeLink(link);
      throw _error(error);
    }
  }

  Future<void> _write(String characteristic, Uint8List value) async {
    _checkUsable();
    final link = _link;
    if (link == null || !_connected) {
      throw const NativeBleException('蓝牙已断开，请重新连接。');
    }
    final maxLength = math.min(_mtu - 3, 512);
    if (value.isEmpty || value.length > maxLength) {
      throw NativeBleException('数据包不能为空或超过当前蓝牙写入上限 $maxLength 字节，请重新协商分片。');
    }
    final copy = Uint8List.fromList(value);
    final result = _writeTail.then((_) async {
      _checkLink(link);
      try {
        await _duringLink(
          link,
          _port!.write(
            link.id,
            characteristic,
            copy,
            withoutResponse: characteristic == dataUuid,
          ),
        );
      } catch (error) {
        // Neither CTRL nor an ambiguous DATA failure can safely be replayed.
        unawaited(_closeLink(link));
        throw _error(error);
      }
    });
    _writeTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<void> writeCtrl(Uint8List value) => _write(ctrlUuid, value);
  @override
  Future<void> writeData(Uint8List value) => _write(dataUuid, value);

  Future<void> _closeLink(_WindowsLink link) {
    if (link.closeFuture != null) return link.closeFuture!;
    if (!link.cancelled.isCompleted) link.cancelled.complete();
    if (identical(_link, link)) {
      _link = null;
      _generation++;
      _setConnected(false);
    }
    final wasConnecting = link.connectPending;
    final result = () async {
      await link.connection?.cancel();
      await link.values?.cancel();
      final port = _port;
      if (port == null || link.nativeConnect == null) return;
      try {
        await port.disconnect(link.id).timeout(operationTimeout);
      } catch (_) {
        // Link state is already invalidated; a late connect is drained below.
      }
      if (wasConnecting) {
        try {
          await link.nativeConnect!.timeout(operationTimeout);
        } catch (_) {}
        // WinRT setup is asynchronous. Close again after an in-flight connect
        // settles before allowing another session to use this device address.
        try {
          await port.disconnect(link.id).timeout(operationTimeout);
        } catch (_) {}
      }
    }();
    link.closeFuture = result;
    _closeTail = result;
    return result;
  }

  @override
  Future<void> disconnect() async {
    _scanGeneration++;
    _scanWanted = false;
    _scanStart = null;
    _setScanning(false);
    final link = _link;
    if (link != null) await _closeLink(link);
    await _closeTail;
    if (_port != null) await _stopScan();
  }

  Future<void> openBluetoothSettings() async {
    _checkUsable();
    try {
      await _desktop.invokeMethod<void>('openBluetoothSettings');
    } catch (error) {
      throw _error(error);
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposing = true;
    try {
      await disconnect();
    } catch (_) {
      // All Dart resources must still close if the OS adapter disappeared.
    } finally {
      await _advertisements?.cancel();
      await _availability?.cancel();
      _disposed = true;
      await Future.wait([
        _notifications.close(),
        _connections.close(),
        _scans.close(),
        _errors.close(),
        _scanStates.close(),
      ]);
    }
  }
}

class _WindowsLink {
  _WindowsLink(this.id, this.generation);
  final String id;
  final int generation;
  final cancelled = Completer<void>();
  StreamSubscription<bool>? connection;
  StreamSubscription<Uint8List>? values;
  Future<void>? nativeConnect;
  bool connectPending = false;
  Future<void>? closeFuture;
}

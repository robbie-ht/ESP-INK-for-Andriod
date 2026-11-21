import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'transport.dart';

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });

  final String id;
  final String name;
  final int rssi;
}

class NativeBleException implements Exception {
  const NativeBleException(this.message, {this.code = 'ble_error'});
  final String message;
  final String code;

  @override
  String toString() => message;
}

/// Android's one-link BLE bridge. GATT write success is not a device job result.
/// Dispose this instance before replacing it with another transport.
class NativeBle implements EspInkTransport {
  static const _methods = MethodChannel('io.github.robbieht.espink/ble');
  static const _events = EventChannel('io.github.robbieht.espink/ble_events');

  final _notifications = StreamController<Uint8List>.broadcast();
  final _connections = StreamController<bool>.broadcast();
  final _scans = StreamController<List<DiscoveredDevice>>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _scanStates = StreamController<bool>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _eventsReady;
  Future<void>? _disposeFuture;
  bool _disposed = false;
  bool _disposing = false;
  bool _connected = false;
  bool _connecting = false;
  bool _scanning = false;
  int _generation = 0;
  int _scanGeneration = 0;
  int _mtu = 23;

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  @override
  int get mtu => _mtu;
  @override
  bool get isConnected => _connected;
  @override
  Stream<Uint8List> get notifications => _notifications.stream;
  @override
  Stream<bool> get connectionChanges => _connections.stream;
  Stream<List<DiscoveredDevice>> get scanResults => _scans.stream;
  Stream<String> get errors => _errors.stream;
  bool get isScanning => _scanning;
  Stream<bool> get scanStateChanges => _scanStates.stream;

  void _checkUsable() {
    if (_disposed || _disposing) {
      throw const NativeBleException('蓝牙服务已关闭，请重新进入设备页面。');
    }
    if (!supported) {
      throw const NativeBleException(
        '真实蓝牙连接仅支持 Android 手机；当前平台可使用演示模式。',
        code: 'unsupported_platform',
      );
    }
  }

  void _checkGeneration(int generation) {
    _checkUsable();
    if (generation != _generation) {
      throw const NativeBleException('蓝牙操作已取消。', code: 'cancelled');
    }
  }

  Future<void> _ensureEvents() async {
    _checkUsable();
    if (_eventsReady == null) {
      final ready = Completer<void>();
      _eventsReady = ready;
      _subscription = _events.receiveBroadcastStream().listen(
        _onEvent,
        onError: (Object error) {
          const message = '无法连接 Android 蓝牙服务，请使用完整安装的 Android 应用。';
          if (!ready.isCompleted) {
            ready.completeError(const NativeBleException(message));
          }
          if (!_disposed) {
            _errors.add(message);
            _setConnected(false);
          }
        },
        onDone: () {
          if (!ready.isCompleted) {
            ready.completeError(const NativeBleException('Android 蓝牙事件通道已关闭。'));
          }
          if (!_disposed) _setConnected(false);
        },
      );
    }
    try {
      // Native onListen acknowledges before any scan or connection is started.
      await _eventsReady!.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      throw const NativeBleException('Android 蓝牙服务未就绪，请重新打开应用。');
    }
  }

  void _setConnected(bool value) {
    if (_connected == value || _disposed) return;
    _connected = value;
    if (!value) _mtu = 23;
    _connections.add(value);
  }

  void _onEvent(dynamic raw) {
    if (_disposed || raw is! Map) return;
    switch (raw['type']) {
      case 'ready':
        final ready = _eventsReady;
        if (ready != null && !ready.isCompleted) ready.complete();
      case 'connection':
        if (_disposing && raw['connected'] == true) return;
        _mtu = (raw['mtu'] as num?)?.toInt() ?? 23;
        _setConnected(raw['connected'] == true);
      case 'mtu':
        _mtu = (raw['mtu'] as num?)?.toInt() ?? _mtu;
      case 'notification':
        final value = raw['value'];
        if (value is Uint8List) {
          _notifications.add(Uint8List.fromList(value));
        } else if (value is List) {
          _notifications.add(Uint8List.fromList(value.cast<int>()));
        }
      case 'scan':
        final devices =
            (raw['devices'] as List? ?? const [])
                .whereType<Map>()
                .map(
                  (item) => DiscoveredDevice(
                    id: item['id'] as String? ?? '',
                    name: item['name'] as String? ?? '未命名 ESP-INK',
                    rssi: (item['rssi'] as num?)?.toInt() ?? -127,
                  ),
                )
                .where((device) => device.id.isNotEmpty)
                .toList()
              ..sort((a, b) => b.rssi.compareTo(a.rssi));
        _scans.add(List.unmodifiable(devices));
      case 'error':
        _errors.add(raw['message'] as String? ?? '蓝牙操作失败。');
      case 'scanState':
        _scanning = raw['scanning'] == true;
        _scanStates.add(_scanning);
    }
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw NativeBleException(
        error.message ?? '蓝牙操作失败，请检查设备和手机蓝牙。',
        code: error.code,
      );
    } on MissingPluginException {
      throw const NativeBleException('此安装包未包含 Android 蓝牙服务，请重新安装。');
    }
  }

  Future<void> startScan() async {
    final generation = _generation;
    final scanGeneration = ++_scanGeneration;
    await _ensureEvents();
    _checkGeneration(generation);
    if (scanGeneration != _scanGeneration) {
      throw const NativeBleException('扫描已取消。', code: 'cancelled');
    }
    await _invoke<void>('startScan');
    _checkGeneration(generation);
    if (scanGeneration != _scanGeneration) {
      throw const NativeBleException('扫描已取消。', code: 'cancelled');
    }
  }

  Future<void> stopScan() async {
    _checkUsable();
    _scanGeneration++;
    await _invoke<void>('stopScan');
  }

  Future<void> connect(String id) async {
    _checkUsable();
    if (_connecting || _connected) {
      throw const NativeBleException('已有连接或正在连接，请先断开。');
    }
    final generation = _generation;
    _connecting = true;
    try {
      await _ensureEvents();
      _checkGeneration(generation);
      final result = await _invoke<Map<Object?, Object?>>('connect', {
        'id': id,
      });
      _checkGeneration(generation);
      _mtu = (result?['mtu'] as num?)?.toInt() ?? 23;
      _setConnected(true);
    } finally {
      _connecting = false;
    }
  }

  Future<void> _write(String method, Uint8List value) async {
    _checkUsable();
    if (!_connected) throw const NativeBleException('蓝牙已断开，请重新连接。');
    final maxLength = math.min(_mtu - 3, 512);
    if (value.isEmpty || value.length > maxLength) {
      throw NativeBleException('数据包不能为空或超过当前蓝牙写入上限 $maxLength 字节，请重新协商分片。');
    }
    await _invoke<void>(method, value);
  }

  @override
  Future<void> writeCtrl(Uint8List value) => _write('writeCtrl', value);
  @override
  Future<void> writeData(Uint8List value) => _write('writeData', value);

  @override
  Future<void> disconnect() async {
    _generation++;
    _scanGeneration++;
    if (_disposed || !supported) return;
    if (_subscription != null) await _invoke<void>('disconnect');
    _setConnected(false);
  }

  Future<void> openBluetoothSettings() async {
    _checkUsable();
    await _invoke<void>('openBluetoothSettings');
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposing = true;
    final ready = _eventsReady;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        const NativeBleException('蓝牙操作已取消。', code: 'cancelled'),
      );
    }
    try {
      await disconnect();
    } finally {
      await _subscription?.cancel();
      _subscription = null;
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

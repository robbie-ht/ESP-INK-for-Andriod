import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/core/frame_codec.dart';
import 'package:esp_ink/core/native_ble.dart';
import 'package:esp_ink/core/protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<int> _le16(int n) => [n & 255, (n >> 8) & 255];
List<int> _le32(int n) => [for (var i = 0; i < 4; i++) (n >> (i * 8)) & 255];
int _u16(Uint8List b, int p) =>
    ByteData.sublistView(b).getUint16(p, Endian.little);
int _u32(Uint8List b, int p) =>
    ByteData.sublistView(b).getUint32(p, Endian.little);

// A small structurally complete C3 app, including app_desc and checksum storage.
// The controller uses the real protocol validator and CRC32, not an OTA stub.
Uint8List _appImage() {
  final bytes = Uint8List(1024);
  bytes[0] = 0xe9;
  bytes[1] = 1;
  final v = ByteData.sublistView(bytes);
  v.setUint16(12, 5, Endian.little);
  v.setUint32(24, 0x3c000020, Endian.little);
  v.setUint32(28, 976, Endian.little);
  v.setUint32(32, 0xabcd5432, Endian.little);
  return bytes;
}

class _OtaBle extends NativeBle {
  final notices = StreamController<Uint8List>.broadcast(sync: true);
  final connections = StreamController<bool>.broadcast(sync: true);
  final scans = StreamController<List<DiscoveredDevice>>.broadcast();
  final scanStates = StreamController<bool>.broadcast();
  final failures = StreamController<String>.broadcast();
  final commands = <Uint8List>[];
  final packets = <Uint8List>[];
  bool linked = false, closed = false;
  String device = 'A';
  int beginStatus = 0, endStatus = 0;
  bool omitBeginReply = false,
      disconnectOnEnd = false,
      disconnectOnAbort = false;
  Completer<void>? holdData, holdRead;
  final dataStarted = Completer<void>();
  final readStarted = Completer<void>();
  final packed = Uint8List(frameLength)..fillRange(0, frameLength, 0x55);

  @override
  bool get supported => true;
  @override
  bool get isConnected => linked;
  @override
  bool get isScanning => false;
  @override
  int get mtu => 517;
  @override
  Stream<Uint8List> get notifications => notices.stream;
  @override
  Stream<bool> get connectionChanges => connections.stream;
  @override
  Stream<List<DiscoveredDevice>> get scanResults => scans.stream;
  @override
  Stream<bool> get scanStateChanges => scanStates.stream;
  @override
  Stream<String> get errors => failures.stream;
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> connect(String id) async {
    device = id;
    linked = true;
    connections.add(true);
  }

  @override
  Future<void> disconnect() async {
    linked = false;
    if (!closed) connections.add(false);
  }

  void reply(Uint8List q, [List<int> payload = const [], int status = 0]) {
    if (!closed) notices.add(Uint8List.fromList([1, q[1], status, ...payload]));
  }

  @override
  Future<void> writeCtrl(Uint8List q) async {
    if (!linked) throw StateError('disconnected fixture');
    commands.add(Uint8List.fromList(q));
    const version = 'B2.0.1';
    switch (q[0]) {
      case Op.ping:
        reply(q, [1, version.length, ...ascii.encode(version)]);
      case Op.getStatus:
        reply(q, [
          1,
          0,
          0,
          ..._le16(3900),
          ..._le32(2),
          ..._le32(60000),
          ..._le16(mtu),
          0,
          ..._le32(180),
          0,
          ..._le32(0),
          1,
          version.length,
          ...ascii.encode(version),
          1,
        ]);
      case Op.getSettings:
        reply(q, [
          0,
          ..._le32(180),
          0,
          ..._le32(0),
          2,
          0,
          1,
          4,
          3,
          5,
          6,
          7,
          10,
          1,
          1,
          ...ascii.encode(device),
          1,
        ]);
      case Op.galleryInfo:
        reply(q, [1, 0, 8, ..._le32(1)]);
      case Op.galleryList:
        reply(q, [
          ..._le32(1),
          0,
          1,
          0,
          ..._le16(768),
          ..._le16(552),
          ..._le32(frameLength),
          ..._le16(crc16(packed)),
          1,
          ..._le16(4),
          ..._le16(4),
          ..._le32(4),
          ..._le16(crc16(Uint8List.fromList([0x55, 0x55, 0x55, 0x55]))),
        ]);
      case Op.galleryRead:
        if (!readStarted.isCompleted) readStarted.complete();
        await holdRead?.future;
        if (!linked) return;
        final offset = _u32(q, 4), count = _u16(q, 8);
        reply(q, [
          0,
          0,
          ..._le32(offset),
          ..._le32(packed.length),
          ..._le16(crc16(packed)),
          1,
          ...packed.sublist(offset, offset + count),
        ]);
      case Op.otaBegin:
        if (!omitBeginReply) {
          reply(q, [..._le16(_u16(q, 10)), ..._le16(512)], beginStatus);
        }
      case Op.otaEnd:
        if (disconnectOnEnd) {
          await disconnect();
        } else {
          reply(q, const [], endStatus);
        }
      case Op.otaAbort:
        if (disconnectOnAbort) {
          await disconnect();
        } else {
          reply(q);
        }
      default:
        reply(q);
    }
  }

  @override
  Future<void> writeData(Uint8List value) async {
    packets.add(Uint8List.fromList(value));
    if (!dataStarted.isCompleted) dataStarted.complete();
    await holdData?.future;
  }

  @override
  Future<void> dispose() async {
    if (closed) return;
    closed = true;
    linked = false;
    await Future.wait([
      notices.close(),
      connections.close(),
      scans.close(),
      scanStates.close(),
      failures.close(),
    ]);
  }
}

// Keep real XFile/File reads, but control the async boundary through IOOverrides.
class _GatedFile implements File {
  _GatedFile(this.delegate, {this.lengthGate, this.readGate});
  final File delegate;
  final Completer<void>? lengthGate, readGate;
  final lengthStarted = Completer<void>(), readStarted = Completer<void>();
  @override
  String get path => delegate.path;
  @override
  Future<int> length() async {
    if (!lengthStarted.isCompleted) lengthStarted.complete();
    await lengthGate?.future;
    return delegate.length();
  }

  @override
  Future<Uint8List> readAsBytes() async {
    if (!readStarted.isCompleted) readStarted.complete();
    await readGate?.future;
    return delegate.readAsBytes();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush([int turns = 12]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const selector = MethodChannel('plugins.flutter.io/file_selector');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late File app;
  late _OtaBle ble;
  late EspInkController controller;
  late List<MethodCall> pickerCalls;
  Future<Object?> Function(MethodCall)? picker;
  bool controllerDisposed = false;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    await Directory('build').create(recursive: true);
    temporary = await Directory('build').createTemp('ota-controller-');
    app = await File('${temporary.path}/应用 固件.bin').writeAsBytes(_appImage());
    pickerCalls = [];
    picker = null;
    messenger.setMockMethodCallHandler(selector, (call) async {
      pickerCalls.add(call);
      final handler = picker;
      if (handler != null) return await handler(call);
      return [app.path];
    });
    ble = _OtaBle();
    controller = EspInkController(nativeBle: ble);
    controllerDisposed = false;
    await controller.init();
    await controller.connect('A');
    ble.commands.clear();
  });

  tearDown(() async {
    if (!controllerDisposed) controller.dispose();
    await _flush();
    messenger.setMockMethodCallHandler(selector, null);
    debugDefaultTargetPlatformOverride = null;
    await temporary.delete(recursive: true);
  });

  test('actual selector and protocol send the selected app with truthful OTA phases', () async {
    final phases = <String>[];
    controller.addListener(() => phases.add(controller.phase));
    await controller.pickAndUpgrade();
    expect(pickerCalls.single.method, 'openFile');
    final groups =
        (pickerCalls.single.arguments as Map)['acceptedTypeGroups'] as List;
    expect(groups, hasLength(1));
    expect(groups.single, containsPair('label', 'ESP32 应用固件'));
    expect(groups.single, containsPair('extensions', ['bin']));
    expect(ble.commands.map((q) => q[0]), [Op.otaBegin, Op.otaEnd]);
    expect(_u32(ble.commands.first, 2), _appImage().length);
    expect(_u32(ble.commands.first, 6), crc32(_appImage()));
    expect(ble.packets.map((p) => p.length), [512, 512, 6]);
    expect(ble.packets.expand((p) => p.sublist(2)), orderedEquals(_appImage()));
    expect(
      phases,
      containsAllInOrder(['正在传输固件', '正在校验固件，等待设备受理', '固件已受理，等待设备重启']),
    );
    expect(controller.message, contains('45秒'));
    expect(controller.pickingOta, isFalse);
    expect(controller.busy, isFalse);
    await ble.disconnect();
    expect(controller.message, contains('核对新版本'));
  });

  test('cancelled selector releases the guard without starting OTA', () async {
    picker = (_) async => null;
    await controller.pickAndUpgrade();
    expect(ble.commands, isEmpty);
    expect(controller.pickingOta, isFalse);
    picker = null;
    await controller.pickAndUpgrade();
    expect(ble.commands.first[0], Op.otaBegin);
  });

  test('picker guard suppresses duplicate dialogs and other manual device jobs', () async {
    final selection = Completer<Object?>();
    picker = (_) => selection.future;
    final upgrading = controller.pickAndUpgrade();
    addTearDown(() async {
      if (!selection.isCompleted) selection.complete(null);
      await upgrading;
    });
    await _flush();
    expect(
      controller.pickingOta,
      isTrue,
      reason:
          '${controller.message}; busy=${controller.busy}, connected=${controller.connected}, pickerCalls=${pickerCalls.length}',
    );
    await controller.pickAndUpgrade();
    await controller.refresh();
    await controller.deleteGallery(0);
    expect(pickerCalls, hasLength(1));
    expect(ble.commands, isEmpty);
    expect(controller.message, contains('当前升级流程'));
    selection.complete([app.path]);
    await upgrading;
    expect(ble.commands.map((q) => q[0]), [Op.otaBegin, Op.otaEnd]);
  });

  test('Android-style picker lifecycle resume cannot race OTA with refresh', () async {
    final selection = Completer<Object?>();
    picker = (_) => selection.future;
    final upgrading = controller.pickAndUpgrade();
    addTearDown(() async {
      if (!selection.isCompleted) selection.complete(null);
      await upgrading;
    });
    await _flush();
    expect(
      controller.pickingOta,
      isTrue,
      reason:
          '${controller.message}; busy=${controller.busy}, connected=${controller.connected}, pickerCalls=${pickerCalls.length}',
    );
    controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await _flush();
    expect(
      ble.commands,
      isEmpty,
      reason: 'resume must not start GET_STATUS/settings refresh',
    );
    selection.complete([app.path]);
    await upgrading;
    expect(ble.commands.map((q) => q[0]), [Op.otaBegin, Op.otaEnd]);
  });

  test(
    'a reconnect while the picker is open cannot send the old selection to B',
    () async {
      final selection = Completer<Object?>();
      picker = (_) => selection.future;
      final upgrading = controller.pickAndUpgrade();
      addTearDown(() async {
        if (!selection.isCompleted) selection.complete(null);
        await upgrading;
      });
      await _flush();
      expect(controller.pickingOta, isTrue, reason: controller.message);
      await ble.disconnect();
      await controller.connect('B');
      ble.commands.clear();
      final message = controller.message;
      selection.complete([app.path]);
      await upgrading;
      expect(ble.commands, isEmpty);
      expect(controller.message, message);
    },
  );

  for (final duringRead in [false, true]) {
    test(
      'session is rechecked after async file ${duringRead ? 'bytes' : 'length'}',
      () async {
        final gate = Completer<void>();
        final file = _GatedFile(
          app,
          lengthGate: duringRead ? null : gate,
          readGate: duringRead ? gate : null,
        );
        final upgrading = IOOverrides.runZoned(
          controller.pickAndUpgrade,
          createFile: (path) => path == app.path
              ? file
              : throw StateError('Unexpected file $path'),
        );
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await upgrading;
        });
        await (duringRead
            ? file.readStarted.future
            : file.lengthStarted.future);
        await ble.disconnect();
        await controller.connect('B');
        ble.commands.clear();
        final message = controller.message;
        gate.complete();
        await upgrading;
        expect(ble.commands, isEmpty);
        expect(controller.message, message);
      },
    );
  }

  test(
    'a late file error after reconnect cannot overwrite the new device message',
    () async {
      final gate = Completer<void>();
      final file = _GatedFile(app, readGate: gate);
      final upgrading = IOOverrides.runZoned(
        controller.pickAndUpgrade,
        createFile: (_) => file,
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await upgrading;
      });
      await file.readStarted.future;
      await ble.disconnect();
      await controller.connect('B');
      final message = controller.message;
      gate.completeError(const FileSystemException('old file unavailable'));
      await upgrading;
      expect(controller.message, message);
      expect(ble.commands.where((q) => q[0] == Op.otaBegin), isEmpty);
    },
  );

  test('in-flight full gallery read drains before OTA starts instead of silently returning', () async {
    ble.holdRead = Completer<void>();
    final reading = controller.readGalleryPreview(0, fullFrame: true);
    Future<void>? upgrading;
    addTearDown(() async {
      if (!ble.holdRead!.isCompleted) ble.holdRead!.complete();
      await reading;
      await upgrading;
    });
    await ble.readStarted.future;
    expect(controller.galleryReading, isTrue);
    upgrading = controller.pickAndUpgrade();
    await _flush();
    expect(ble.commands.where((q) => q[0] == Op.otaBegin), isEmpty);
    ble.holdRead!.complete();
    await reading;
    await upgrading;
    final ops = ble.commands.map((q) => q[0]).toList();
    expect(ops, contains(Op.otaBegin));
    expect(ops.lastIndexOf(Op.galleryRead), lessThan(ops.indexOf(Op.otaBegin)));
    expect(controller.message, contains('45秒'));
  });

  test('disconnect while waiting for gallery drain never begins OTA', () async {
    ble.holdRead = Completer<void>();
    final reading = controller.readGalleryPreview(0, fullFrame: true);
    Future<void>? upgrading;
    addTearDown(() async {
      if (!ble.holdRead!.isCompleted) ble.holdRead!.complete();
      await reading;
      await upgrading;
    });
    await ble.readStarted.future;
    upgrading = controller.pickAndUpgrade();
    await _flush();
    await ble.disconnect();
    ble.holdRead!.complete();
    await reading;
    await upgrading;
    expect(ble.commands.where((q) => q[0] == Op.otaBegin), isEmpty);
    expect(controller.message, contains('升级尚未开始'));
  });

  test('disposed controller ignores a pending picker without notifying or transferring', () async {
    final selection = Completer<Object?>();
    picker = (_) => selection.future;
    final upgrading = controller.pickAndUpgrade();
    addTearDown(() async {
      if (!selection.isCompleted) selection.complete(null);
      await upgrading;
    });
    await _flush();
    expect(controller.pickingOta, isTrue, reason: controller.message);
    controller.dispose();
    controllerDisposed = true;
    selection.complete([app.path]);
    await upgrading;
    expect(ble.commands.where((q) => q[0] == Op.otaBegin), isEmpty);
  });

  test('invalid app structure is rejected before OTA_BEGIN with firmware-specific text', () async {
    await app.writeAsBytes(Uint8List(1024));
    await controller.pickAndUpgrade();
    expect(ble.commands, isEmpty);
    expect(controller.message, contains('应用镜像'));
    expect(controller.message, isNot(contains('图片')));
  });

  test('device OTA rejection names firmware verification rather than image processing', () async {
    ble.endStatus = StatusCode.otaVerify;
    await controller.pickAndUpgrade();
    expect(controller.message, contains('固件镜像校验失败'));
    expect(controller.message, isNot(contains('图库')));
    expect(controller.message, isNot(contains('重新处理图片')));
  });

  test('receiving cancellation confirms OTA_ABORT and never claims waiting for reboot', () async {
    ble.holdData = Completer<void>();
    final upgrading = controller.pickAndUpgrade();
    addTearDown(() async {
      if (!ble.holdData!.isCompleted) ble.holdData!.complete();
      await upgrading;
    });
    await ble.dataStarted.future;
    expect(controller.canCancel, isTrue);
    controller.cancelTransfer();
    ble.holdData!.complete();
    await upgrading;
    expect(ble.commands.map((q) => q[0]), [Op.otaBegin, Op.otaAbort]);
    expect(controller.message, contains('固件传输已取消'));
    expect(controller.message, contains('尚未提交启动切换'));
  });

  test('unconfirmed cancellation is a receiving-session unknown, not a boot-slot submission', () async {
    ble.holdData = Completer<void>();
    ble.disconnectOnAbort = true;
    final upgrading = controller.pickAndUpgrade();
    addTearDown(() async {
      if (!ble.holdData!.isCompleted) ble.holdData!.complete();
      await upgrading;
    });
    await ble.dataStarted.future;
    controller.cancelTransfer();
    ble.holdData!.complete();
    await upgrading;
    expect(controller.message, contains('接收会话结束回执待确认'));
    expect(controller.message, contains('尚未发送启动切换提交'));
    expect(controller.message, isNot(contains('核对固件版本')));
    expect(ble.commands.map((q) => q[0]), [Op.otaBegin, Op.otaAbort]);
  });

  test('missing BEGIN reply times out as start-session unknown without sending END', () async {
    ble.omitBeginReply = true;
    await controller.pickAndUpgrade();
    expect(ble.commands.map((q) => q[0]), [Op.otaBegin]);
    expect(ble.packets, isEmpty);
    expect(controller.message, contains('升级开始回执待确认'));
    expect(controller.message, contains('尚未发送启动切换提交'));
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('an uncertain END prevents a second picker and preserves boot-slot uncertainty', () async {
    ble.endStatus = StatusCode.noMem;
    await controller.pickAndUpgrade();
    expect(controller.connected, isTrue);
    expect(controller.message, contains('提交结果待确认'));
    expect(pickerCalls, hasLength(1));
    expect(ble.commands.map((q) => q[0]), [Op.otaBegin, Op.otaEnd]);
    ble.commands.clear();
    await controller.pickAndUpgrade();
    expect(pickerCalls, hasLength(1));
    expect(ble.commands, isEmpty);
    expect(controller.message, contains('上一设备操作结果待确认'));
    expect(controller.message, contains('固件版本'));
    expect(controller.message, isNot(contains('尚未发送启动切换')));
  });

  test('disconnect after END reports unknown submission and never retries or reboots', () async {
    ble.disconnectOnEnd = true;
    await controller.pickAndUpgrade();
    expect(ble.commands.map((q) => q[0]), [Op.otaBegin, Op.otaEnd]);
    expect(controller.message, contains('提交结果待确认'));
    expect(controller.message, contains('核对固件版本'));
    expect(controller.message, isNot(contains('图库')));
    expect(controller.message, isNot(contains('校验已通过')));
  });
}

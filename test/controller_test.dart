import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/app/models.dart';
import 'package:esp_ink/core/frame_codec.dart';
import 'package:esp_ink/core/native_ble.dart';
import 'package:esp_ink/core/protocol.dart';

List<int> _le16(int value) => [value & 255, (value >> 8) & 255];
List<int> _le32(int value) => [
  value & 255,
  (value >> 8) & 255,
  (value >> 16) & 255,
  (value >> 24) & 255,
];
int _u16(Uint8List value, int offset) =>
    ByteData.sublistView(value).getUint16(offset, Endian.little);
int _u32(Uint8List value, int offset) =>
    ByteData.sublistView(value).getUint32(offset, Endian.little);

Uint8List _smallPng(int red, int green, int blue) {
  final image = img.Image(width: 2, height: 1);
  image.setPixelRgba(0, 0, red, green, blue, 255);
  image.setPixelRgba(1, 0, red, green, blue, 255);
  return Uint8List.fromList(img.encodePng(image));
}

class _Device {
  _Device({
    required this.name,
    required this.thumbnail,
    this.revision = 2,
    this.thumbnailFormat = 2,
    this.thumbnailWidth = 2,
    this.thumbnailHeight = 1,
  });

  final String name;
  int revision, thumbnailFormat, thumbnailWidth, thumbnailHeight;
  Uint8List thumbnail;
  int? current = 0;
}

/// Tests the real controller and protocol parser with binary device replies.
/// This fixture has no platform channel, image renderer, or physical BLE link.
class _FakeNativeBle extends NativeBle {
  _FakeNativeBle(this.devices);

  final Map<String, _Device> devices;
  final commands = <Uint8List>[];
  final connectedIds = <String>[];
  final _notice = StreamController<Uint8List>.broadcast(sync: true);
  final _connection = StreamController<bool>.broadcast(sync: true);
  final _scan = StreamController<List<DiscoveredDevice>>.broadcast();
  final _scanState = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  _Device? _device;
  bool _linked = false, _closed = false;
  Future<void>? _closeFuture;

  @override
  bool get supported => true;
  @override
  int get mtu => 517;
  @override
  bool get isConnected => _linked;
  @override
  bool get isScanning => false;
  @override
  Stream<Uint8List> get notifications => _notice.stream;
  @override
  Stream<bool> get connectionChanges => _connection.stream;
  @override
  Stream<List<DiscoveredDevice>> get scanResults => _scan.stream;
  @override
  Stream<bool> get scanStateChanges => _scanState.stream;
  @override
  Stream<String> get errors => _error.stream;

  @override
  Future<void> startScan() async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> openBluetoothSettings() async {}

  @override
  Future<void> connect(String id) async {
    if (_closed) throw StateError('fixture is disposed');
    _device = devices[id] ?? (throw StateError('unknown fake device $id'));
    _linked = true;
    connectedIds.add(id);
    _connection.add(true);
  }

  @override
  Future<void> disconnect() async {
    _linked = false;
    if (!_closed) _connection.add(false);
  }

  void _reply(Uint8List request, List<int> payload, {int status = 0}) {
    _notice.add(Uint8List.fromList([1, request[1], status, ...payload]));
  }

  void _displayDone(int kind) {
    _notice.add(Uint8List.fromList([0x81, EventId.displayDone, kind]));
  }

  @override
  Future<void> writeCtrl(Uint8List request) async {
    if (!_linked) throw StateError('fake BLE disconnected');
    commands.add(Uint8List.fromList(request));
    final device = _device!;
    const version = 'B2.0.0';
    switch (request[0]) {
      case Op.ping:
        _reply(request, [1, version.length, ...ascii.encode(version)]);
      case Op.getStatus:
        _reply(request, [
          1,
          0,
          0,
          ..._le16(3980),
          ..._le32(123),
          ..._le32(64000),
          ..._le16(mtu),
          0,
          ..._le32(180),
          0,
          ..._le32(0),
          1,
          version.length,
          ...ascii.encode(version),
        ]);
      case Op.getSettings:
        final name = utf8.encode(device.name);
        _reply(request, [
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
          name.length,
          ...name,
          1,
        ]);
      case Op.galleryInfo:
        _reply(request, [
          1,
          device.current ?? 255,
          8,
          ..._le32(device.revision),
        ]);
      case Op.galleryList:
        if (request[2] != 0 || request[3] != 1) {
          throw StateError('unexpected gallery pagination');
        }
        _reply(request, [
          ..._le32(device.revision),
          0,
          1,
          0,
          ..._le16(768),
          ..._le16(552),
          ..._le32(frameLength),
          ..._le16(0x2698),
          device.thumbnailFormat,
          ..._le16(device.thumbnailWidth),
          ..._le16(device.thumbnailHeight),
          ..._le32(device.thumbnail.length),
          ..._le16(crc16(device.thumbnail)),
        ]);
      case Op.galleryRead:
        if (_u32(request, 10) != device.revision) {
          _reply(request, [], status: StatusCode.stale);
          return;
        }
        if (request[2] != 0 || request[3] != 1) {
          throw StateError('fixture only supports slot 0 thumbnails');
        }
        final offset = _u32(request, 4);
        final end = math.min(
          offset + _u16(request, 8),
          device.thumbnail.length,
        );
        _reply(request, [
          0,
          1,
          ..._le32(offset),
          ..._le32(device.thumbnail.length),
          ..._le16(crc16(device.thumbnail)),
          device.thumbnailFormat,
          ...device.thumbnail.sublist(offset, end),
        ]);
      case Op.cacheShow:
        device.current = null;
        // Completion can precede the CTRL response; the client must be ready.
        _displayDone(3);
        _reply(request, []);
      case Op.ghostClear:
        device.current = null;
        _displayDone(2);
        _reply(request, []);
      default:
        throw StateError(
          'unexpected command 0x${request[0].toRadixString(16)}',
        );
    }
  }

  @override
  Future<void> writeData(Uint8List value) async {
    throw StateError('these controller regressions must not upload image data');
  }

  @override
  Future<void> dispose() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    _linked = false;
    await super.dispose();
    await Future.wait([
      _notice.close(),
      _connection.close(),
      _scan.close(),
      _scanState.close(),
      _error.close(),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Device deviceA, deviceB;
  late _FakeNativeBle ble;
  late EspInkController controller;

  setUp(() {
    deviceA = _Device(
      name: 'ESP-INK-A',
      thumbnail: _smallPng(255, 0, 0),
      revision: 2,
      thumbnailFormat: 2,
      thumbnailWidth: 2,
      thumbnailHeight: 1,
    );
    deviceB = _Device(name: 'ESP-INK-B', thumbnail: _smallPng(0, 0, 0));
    ble = _FakeNativeBle({'A': deviceA, 'B': deviceB});
    controller = EspInkController(nativeBle: ble);
    // init() starts artwork rendering and mobile picker recovery. Neither is
    // relevant to these protocol/controller tests, so connect directly.
  });

  tearDown(() async {
    controller.dispose();
    await ble.dispose();
  });

  test('switching devices discards a cached PNG despite identical revision and slot', () async {
    await controller.connect('A');
    expect(controller.connected, isTrue, reason: controller.message);
    await controller.loadGalleryPreview(0);
    expect(controller.gallery.single.png, orderedEquals(deviceA.thumbnail));
    expect(deviceA.revision, deviceB.revision);

    // Simulate link loss without explicitly clearing the controller's views.
    // connect() must independently discard cached identity from device A.
    await ble.disconnect();
    await controller.connect('B');
    expect(controller.connected, isTrue, reason: controller.message);
    expect(controller.deviceName, 'ESP-INK-B');
    expect(controller.gallery.single.slot, 0);
    expect(controller.gallery.single.png, isNull);
    await controller.loadGalleryPreview(0);
    expect(controller.gallery.single.png, orderedEquals(deviceB.thumbnail));
    expect(
      controller.gallery.single.png,
      isNot(orderedEquals(deviceA.thumbnail)),
    );
    expect(ble.connectedIds, ['A', 'B']);
  });

  test('thumbnail decode uses metadata from the downloaded revision', () async {
    deviceA
      ..thumbnailFormat = 1
      ..thumbnailWidth = 8
      ..thumbnailHeight = 1
      ..thumbnail = Uint8List.fromList([0x55, 0x55]);
    await controller.connect('A');
    expect(controller.connected, isTrue, reason: controller.message);

    // The old list describes packed 2bpp. The fresh download describes PNG;
    // decoding with the old dimensions/format would corrupt or reject it.
    final replacement = _smallPng(255, 255, 0);
    deviceA
      ..revision = 3
      ..thumbnailFormat = 2
      ..thumbnailWidth = 2
      ..thumbnailHeight = 1
      ..thumbnail = replacement;
    await controller.loadGalleryPreview(0);
    expect(
      controller.gallery.single.png,
      orderedEquals(replacement),
      reason: controller.message,
    );
    final read = ble.commands.lastWhere(
      (command) => command[0] == Op.galleryRead,
    );
    expect(_u32(read, 10), 3);
    final decoded = img.decodePng(controller.gallery.single.png!);
    expect((decoded!.width, decoded.height), (2, 1));
  });

  for (final operation in [Op.cacheShow, Op.ghostClear]) {
    test(
      '${operation == Op.cacheShow ? 'showCache' : 'clearGhost'} refreshes device state and clears gallery current',
      () async {
        await controller.connect('A');
        expect(controller.connected, isTrue, reason: controller.message);
        expect(controller.gallery.single.current, isTrue);
        final start = ble.commands.length;

        if (operation == Op.cacheShow) {
          await controller.showCache();
        } else {
          await controller.clearGhost(cycles: 3);
        }
        expect(controller.gallery, hasLength(1));
        expect(
          controller.gallery.single.current,
          isFalse,
          reason: controller.message,
        );
        expect(controller.deviceState, '就绪');
        expect(controller.busy, isFalse);
        final later = ble.commands.skip(start).toList();
        expect(later.first[0], operation);
        if (operation == Op.ghostClear) expect(later.first.sublist(2), [3]);
        expect(
          later.skip(1).map((command) => command[0]),
          containsAll([
            Op.getStatus,
            Op.getSettings,
            Op.galleryInfo,
            Op.galleryList,
          ]),
        );
      },
    );
  }

  test('demo deletion compacts logical slots and preserves the retained image identity', () async {
    final first = _smallPng(1, 2, 3);
    final second = _smallPng(4, 5, 6);
    controller
      ..demo = true
      ..gallerySupported = true
      ..gallery = [
        const GalleryItemView(slot: 0, title: 'A'),
        GalleryItemView(slot: 1, title: 'B', current: true, png: first),
        GalleryItemView(slot: 2, title: 'C', png: second),
      ];

    await controller.deleteGallery(0);
    expect(controller.gallery.map((item) => item.slot), [0, 1]);
    expect(controller.gallery.map((item) => item.title), ['B', 'C']);
    expect(controller.gallery.first.current, isTrue);
    expect(controller.gallery.first.png, same(first));
    expect(controller.gallery.last.png, same(second));
    await controller.deleteGallery(0);
    expect(controller.gallery.single.slot, 0);
    expect(controller.gallery.single.title, 'C');
    expect(controller.gallery.single.png, same(second));
    expect(controller.gallery.single.current, isFalse);
    expect(ble.commands, isEmpty);
  });
}

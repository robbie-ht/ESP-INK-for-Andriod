import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/app/image_processor.dart';
import 'package:esp_ink/app/models.dart';
import 'package:esp_ink/core/frame_codec.dart';
import 'package:esp_ink/core/native_ble.dart';
import 'package:esp_ink/core/protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<int> _le16(int n) => [n & 255, n >> 8 & 255];
List<int> _le32(int n) => [..._le16(n), ..._le16(n >> 16)];
int _u16(Uint8List p, int o) =>
    ByteData.sublistView(p).getUint16(o, Endian.little);
int _u32(Uint8List p, int o) =>
    ByteData.sublistView(p).getUint32(o, Endian.little);

class _Picture {
  _Picture({this.format = 2, this.color = 3}) {
    final image = img.Image(width: 8, height: 4);
    img.fill(image, color: img.ColorRgb8(255, color == 3 ? 0 : 255, 0));
    thumbnail = format == 2
        ? Uint8List.fromList(img.encodeJpg(image))
        : solidFrame(color: color, width: 8, height: 4);
    frame = solidFrame(color: color);
    frameCrc = crc16(frame);
  }

  final int format, color;
  late Uint8List thumbnail, frame;
  late int frameCrc;
}

class _Device {
  _Device(this.pictures);
  final List<_Picture> pictures;
  int revision = 1;
  int current = 255;
}

/// Uses actual INFO/LIST/READ response layouts, CRCs, JPEG and rotated 2bpp.
/// There is no physical radio, image renderer or platform channel in this fixture.
class _GalleryBle extends NativeBle {
  _GalleryBle(this.devices);
  final Map<String, _Device> devices;
  final _events = StreamController<Uint8List>.broadcast(sync: true);
  final _links = StreamController<bool>.broadcast(sync: true);
  final commands = <int>[];
  final commandPackets = <Uint8List>[];
  final reads = <(int, int)>[];
  _Device? _device;
  bool _connected = false;
  Completer<void>? holdNextRead;
  Completer<void>? holdNextShow;
  bool failNextRead = false;
  int failedReadStatus = StatusCode.busy;
  int activeReads = 0, maxActiveReads = 0;
  final readBlocks = <(int, int, int)>[];
  int batteryValue = 4000, stateCode = 0;
  int _uploadFlags = 0;
  bool displayFails = false;
  void Function(_Device)? afterAppend;
  void Function(_Device)? afterDelete;
  int? deleteEventSlot, deleteEventCount, deleteEventCurrent;
  int? nextInfoCount, nextInfoRevision;
  int deleteCompletionStatus = StatusCode.ok;
  bool mutateOnDeleteFailure = false;
  final uploaded = BytesBuilder(copy: false);
  int _uploadSequence = 0, _uploadCrc = 0;
  @override
  bool get supported => false;
  @override
  bool get isConnected => _connected;
  @override
  int get mtu => 517;
  @override
  Stream<Uint8List> get notifications => _events.stream;
  @override
  Stream<bool> get connectionChanges => _links.stream;
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> connect(String id) async {
    _device = devices[id]!;
    _connected = true;
    _links.add(true);
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _links.add(false);
  }

  void _reply(Uint8List request, List<int> bytes, {int status = 0}) =>
      _events.add(Uint8List.fromList([1, request[1], status, ...bytes]));

  @override
  Future<void> writeCtrl(Uint8List p) async {
    if (!_connected) throw StateError('Disconnected');
    commands.add(p[0]);
    commandPackets.add(Uint8List.fromList(p));
    final d = _device!;
    switch (p[0]) {
      case Op.ping:
        _reply(p, [1, 2, ...ascii.encode('B2')]);
      case Op.getStatus:
        _reply(p, [
          1,
          0,
          stateCode,
          ..._le16(batteryValue),
          ..._le32(1),
          ..._le32(100000),
          ..._le16(mtu),
          0,
          ..._le32(180),
          0,
          ..._le32(0),
          1,
          2,
          ...ascii.encode('B2'),
        ]);
      case Op.getSettings:
        _reply(p, [
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
          0,
          1,
        ]);
      case Op.galleryInfo:
        final infoCount = nextInfoCount ?? d.pictures.length;
        final infoRevision = nextInfoRevision ?? d.revision;
        nextInfoCount = nextInfoRevision = null;
        _reply(p, [infoCount, d.current, 8, ..._le32(infoRevision)]);
      case Op.galleryList:
        final start = p[2];
        final count = math.min(p[3], d.pictures.length - start);
        _reply(p, [
          ..._le32(d.revision),
          start,
          count,
          for (var i = start; i < start + count; i++) ...[
            i,
            ..._le16(768),
            ..._le16(552),
            ..._le32(frameLength),
            ..._le16(d.pictures[i].frameCrc),
            d.pictures[i].format,
            ..._le16(8),
            ..._le16(4),
            ..._le32(d.pictures[i].thumbnail.length),
            ..._le16(crc16(d.pictures[i].thumbnail)),
          ],
        ]);
      case Op.galleryRead:
        activeReads++;
        maxActiveReads = math.max(maxActiveReads, activeReads);
        try {
          final gate = holdNextRead;
          holdNextRead = null;
          if (gate != null) await gate.future;
          if (!_connected || !identical(d, _device)) return;
          if (failNextRead) {
            failNextRead = false;
            _reply(p, [], status: failedReadStatus);
            return;
          }
          if (_u32(p, 10) != d.revision) {
            _reply(p, [], status: StatusCode.stale);
            return;
          }
          final slot = p[2], kind = p[3], offset = _u32(p, 4);
          readBlocks.add((slot, kind, offset));
          if (offset == 0) reads.add((slot, kind));
          final picture = d.pictures[slot];
          final data = kind == 1 ? picture.thumbnail : picture.frame;
          final crc = kind == 1 ? crc16(data) : picture.frameCrc;
          final end = math.min(offset + _u16(p, 8), data.length);
          _reply(p, [
            slot,
            kind,
            ..._le32(offset),
            ..._le32(data.length),
            ..._le16(crc),
            kind == 1 ? picture.format : 1,
            ...data.sublist(offset, end),
          ]);
        } finally {
          activeReads--;
        }
      case Op.galleryShow:
        final gate = holdNextShow;
        holdNextShow = null;
        if (gate != null) await gate.future;
        d.current = p[2] == 255
            ? (d.current == 255 ? 0 : (d.current + 1) % d.pictures.length)
            : p[2];
        _events.add(Uint8List.fromList([0x81, EventId.displayDone, 4]));
        _reply(p, []);
      case Op.galleryDelete:
        if (deleteCompletionStatus == StatusCode.ok || mutateOnDeleteFailure) {
          d.pictures.removeAt(p[2]);
          d.revision = d.revision == 0xffffffff ? 1 : d.revision + 1;
          if (d.current == p[2]) {
            d.current = 255;
          } else if (d.current != 255 && d.current > p[2]) {
            d.current--;
          }
          afterDelete?.call(d);
        }
        _events.add(
          Uint8List.fromList([
            0x81,
            EventId.storeDone,
            deleteCompletionStatus,
            deleteEventSlot ?? p[2],
            deleteEventCount ?? d.pictures.length,
            deleteEventCurrent ?? d.current,
          ]),
        );
        _reply(p, []);
      case Op.galleryClear:
        d.pictures.clear();
        d.revision++;
        d.current = 255;
        _events.add(
          Uint8List.fromList([0x81, EventId.storeDone, 0, 255, 0, 255]),
        );
        _reply(p, []);
      case Op.frameBegin:
        uploaded.takeBytes();
        _uploadFlags = p[2];
        _uploadSequence = 0;
        _uploadCrc = _u16(p, 11);
        _reply(p, [..._le16(_u16(p, 13)), ..._le16(512)]);
      case Op.frameEnd:
        final frame = uploaded.toBytes();
        if (frame.length != frameLength || crc16(frame) != _uploadCrc) {
          throw StateError('Upload frame or CRC is invalid');
        }
        if (_uploadFlags & 2 != 0) {
          final picture = _Picture(color: 3)
            ..frame = frame
            ..frameCrc = crc16(frame);
          d.pictures.add(picture);
          d.revision = d.revision == 0xffffffff ? 1 : d.revision + 1;
          afterAppend?.call(d);
          _events.add(
            Uint8List.fromList([
              0x81,
              EventId.storeDone,
              0,
              d.pictures.length - 1,
              d.pictures.length,
              255,
            ]),
          );
        }
        if (_uploadFlags & 4 == 0) {
          _events.add(
            Uint8List.fromList([
              0x81,
              EventId.displayDone,
              displayFails ? 1 : 0,
            ]),
          );
        }
        _reply(p, [1]);
      default:
        throw StateError('Unexpected operation ${p[0]}');
    }
  }

  @override
  Future<void> writeData(Uint8List value) async {
    if (_u16(value, 0) != _uploadSequence++) {
      throw StateError('Upload packet sequence is invalid');
    }
    uploaded.add(value.sublist(2));
  }

  Future<void> close() async {
    await super.dispose();
    await _events.close();
    await _links.close();
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _GalleryBle ble;
  late EspInkController controller;
  late _Device a;
  late List<ComposerDraft> processedDrafts;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    a = _Device([_Picture(), _Picture(format: 1, color: 2)]);
    ble = _GalleryBle({
      'a': a,
      'b': _Device([_Picture(color: 2)]),
    });
    processedDrafts = [];
    controller = EspInkController(
      nativeBle: ble,
      artworkProcessor: (draft) async {
        processedDrafts.add(draft);
        return ProcessedArtwork(solidFrame(color: 3), a.pictures[0].thumbnail);
      },
    );
    await controller.init();
    await controller.connect('a');
    expect(controller.connected, isTrue, reason: controller.message);
  });

  tearDown(() async {
    controller.dispose();
    await ble.close();
  });

  test(
    'real JPEG and packed 2bpp thumbnail responses become usable previews',
    () async {
      final jpeg = await controller.readGalleryPreview(0);
      final packed = await controller.readGalleryPreview(1);
      expect(jpeg.ok, isTrue, reason: jpeg.error);
      expect(jpeg.png, orderedEquals(a.pictures[0].thumbnail));
      expect(img.decodeJpg(jpeg.png!)?.width, 8);
      expect(packed.ok, isTrue, reason: packed.error);
      final decoded = img.decodePng(packed.png!)!;
      expect((decoded.width, decoded.height), (8, 4));
      final pixel = decoded.getPixel(0, 0);
      expect((pixel.r, pixel.g, pixel.b), (255, 255, 0));
    },
  );

  test(
    'identical queued reads deduplicate and full frames never downgrade',
    () async {
      final gate = Completer<void>();
      ble.holdNextRead = gate;
      final first = controller.readGalleryPreview(0);
      final second = controller.readGalleryPreview(0);
      await _flush();
      expect(controller.galleryPreviewStatus(0).loading, isTrue);
      gate.complete();
      expect((await first).ok, isTrue);
      expect((await second).ok, isTrue);
      expect(ble.reads, [(0, 1)]);

      final full = await controller.readGalleryPreview(0, fullFrame: true);
      expect(full.ok, isTrue, reason: full.error);
      expect(full.fullFrame, isTrue);
      expect(img.decodePng(full.png!)?.width, 768);
      final before = ble.reads.length;
      final again = await controller.readGalleryPreview(0);
      expect(again.fullFrame, isTrue);
      expect(again.png, same(full.png));
      expect(ble.reads.length, before);
      final forced = await controller.readGalleryPreview(0, forceReload: true);
      expect(forced.fullFrame, isTrue);
      expect(ble.reads.last, (0, 0));
      expect(ble.reads.length, before + 1);
      expect(ble.maxActiveReads, 1);
    },
  );

  test('read failures remain visible and a retry can succeed', () async {
    ble.failNextRead = true;
    final failed = await controller.readGalleryPreview(0);
    expect(failed.ok, isFalse);
    expect(failed.error, isNotEmpty);
    expect(controller.galleryPreviewStatus(0).error, failed.error);
    expect(controller.gallery.first.png, isNull);
    final retried = await controller.readGalleryPreview(0);
    expect(retried.ok, isTrue, reason: retried.error);
    expect(controller.galleryPreviewStatus(0).error, isNull);
    ble.failNextRead = true;
    final fullFailed = await controller.readGalleryPreview(0, fullFrame: true);
    expect(fullFailed.ok, isFalse);
    expect(
      fullFailed.png,
      isNull,
      reason: 'An export must never fall back to the thumbnail',
    );
    expect(fullFailed.fullFrame, isFalse);
    expect(controller.gallery.first.png, same(retried.png));
  });

  test(
    'a malformed encoded thumbnail returns an error rather than a broken image',
    () async {
      a.pictures[0].thumbnail = Uint8List.fromList([1, 2, 3]);
      await controller.refreshGallery();
      final result = await controller.readGalleryPreview(0);
      expect(result.ok, isFalse);
      expect(result.error, contains('无法解码'));
      expect(controller.gallery.first.png, isNull);
    },
  );

  test(
    'an already cached demo picture remains usable during a device job',
    () async {
      final artwork = Completer<ProcessedArtwork>();
      controller.dispose();
      controller = EspInkController(
        nativeBle: ble,
        artworkProcessor: (_) => artwork.future,
      );
      controller
        ..demo = true
        ..gallerySupported = true
        ..gallery = [
          GalleryItemView(slot: 0, title: '演示', png: a.pictures[0].thumbnail),
        ];
      controller.updateDraft(const ComposerDraft(kind: CompositionKind.note));
      final sending = controller.send();
      final preview = controller.readGalleryPreview(0);
      expect(
        (await preview).ok,
        isTrue,
        reason: 'A cached image is usable even during a job',
      );
      artwork.complete(ProcessedArtwork(solidFrame(), a.pictures[0].thumbnail));
      await sending;
    },
  );

  test('preload yields to an explicitly opened slot and stops after leaving gallery', () async {
    controller.tabIndex = 1;
    final gate = Completer<void>();
    ble.holdNextRead = gate;
    final background = controller.preloadGalleryPreviews();
    await _flush();
    final full = controller.readGalleryPreview(1, fullFrame: true);
    controller.setTab(0);
    gate.complete();
    await background;
    expect((await full).fullFrame, isTrue);
    expect(ble.reads, [(0, 1), (1, 0)]);
    expect(ble.maxActiveReads, 1);
  });

  test('a user refresh cancels preload before another thumbnail', () async {
    controller.tabIndex = 1;
    final gate = Completer<void>();
    ble.holdNextRead = gate;
    final preload = controller.preloadGalleryPreviews();
    await _flush();
    final start = ble.commands.length;
    final refresh = controller.refresh();
    gate.complete();
    await refresh;
    await preload;
    final later = ble.commands.skip(start).toList();
    expect(later, contains(Op.getStatus));
    expect(later, isNot(contains(Op.galleryRead)));
    expect(ble.reads, [(0, 1)]);
    expect(ble.maxActiveReads, 1);
  });

  for (final operation in [Op.galleryShow, Op.galleryDelete, Op.galleryClear]) {
    test(
      'user operation $operation is queued ahead of background thumbnails',
      () async {
        controller.tabIndex = 1;
        final gate = Completer<void>();
        ble.holdNextRead = gate;
        final preload = controller.preloadGalleryPreviews();
        await _flush();
        final action = switch (operation) {
          Op.galleryShow => controller.showGallery(0),
          Op.galleryDelete => controller.deleteGallery(0),
          _ => controller.clearGallery(),
        };
        gate.complete();
        await action;
        await preload;
        expect(ble.commands, contains(operation));
        expect(controller.message, isNot(contains('设备正忙')));
        if (operation == Op.galleryShow) {
          expect(controller.gallery.first.current, isTrue);
        } else if (operation == Op.galleryDelete) {
          expect(controller.gallery, hasLength(1));
        } else {
          expect(controller.gallery, isEmpty);
        }
        expect(ble.maxActiveReads, 1);
      },
    );
  }

  test(
    'send during prefetch uploads the draft captured when the user clicked',
    () async {
      controller.tabIndex = 1;
      const clicked = ComposerDraft(kind: CompositionKind.note, background: 2);
      controller.updateDraft(clicked);
      final gate = Completer<void>();
      ble.holdNextRead = gate;
      final preload = controller.preloadGalleryPreviews();
      await _flush();
      final sending = controller.send();
      controller.updateDraft(clicked.copyWith(background: 0));
      gate.complete();
      await sending;
      await preload;
      expect(processedDrafts, [same(clicked)]);
      expect(ble.commands, contains(Op.frameBegin));
      expect(ble.commands, contains(Op.frameEnd));
      expect(ble.uploaded.toBytes(), orderedEquals(solidFrame(color: 3)));
      expect(controller.message, contains('刷新完成'));
      expect(ble.maxActiveReads, 1);
    },
  );

  test(
    'revisions invalidate cached previews and old slot identities',
    () async {
      final before = controller.galleryItemIdentity(0);
      expect((await controller.readGalleryPreview(0)).ok, isTrue);
      a.revision++;
      a.pictures[0] = _Picture(color: 2);
      await controller.refreshGallery();
      expect(controller.galleryItemIdentity(0), isNot(before));
      expect(controller.gallery.first.png, isNull);
      final next = await controller.readGalleryPreview(0);
      expect(next.png, orderedEquals(a.pictures[0].thumbnail));
    },
  );

  test(
    'a late read from a disconnected device cannot populate a new device',
    () async {
      final gate = Completer<void>();
      ble.holdNextRead = gate;
      final old = controller.readGalleryPreview(0);
      await _flush();
      await ble.disconnect();
      await controller.connect('b');
      gate.complete();
      final stale = await old;
      expect(stale.changed, isTrue);
      expect(controller.connected, isTrue);
      expect(controller.gallery, hasLength(1));
      expect(controller.gallery.single.png, isNull);
      final fresh = await controller.readGalleryPreview(0);
      expect(fresh.ok, isTrue, reason: fresh.error);
      expect(fresh.png, orderedEquals(ble.devices['b']!.pictures[0].thumbnail));
    },
  );

  test(
    'confirmed append preserves downloaded full frames with new identities',
    () async {
      final full = await controller.readGalleryPreview(0, fullFrame: true);
      final before = controller.galleryItemIdentity(0);
      controller.updateDraft(const ComposerDraft(kind: CompositionKind.note));
      await controller.send(saveGallery: true, storeOnly: true);
      expect(controller.gallery, hasLength(3), reason: controller.message);
      expect(controller.galleryItemIdentity(0), isNot(before));
      expect(controller.gallery.first.png, same(full.png));
      expect(controller.galleryPreviewStatus(0).fullFrame, isTrue);
      final reads = ble.reads.length;
      final cached = await controller.readGalleryPreview(0, fullFrame: true);
      expect(cached.fullFrame, isTrue);
      expect(cached.png, same(full.png));
      expect(ble.reads.length, reads);
    },
  );

  test(
    'confirmed append revision wrap skips zero and retains full frames',
    () async {
      a.revision = 0xffffffff;
      await controller.refreshGallery();
      final full = await controller.readGalleryPreview(0, fullFrame: true);
      controller.updateDraft(const ComposerDraft(kind: CompositionKind.note));
      await controller.send(saveGallery: true, storeOnly: true);
      expect(a.revision, 1);
      expect(controller.gallery.first.png, same(full.png));
      expect(controller.galleryPreviewStatus(0).fullFrame, isTrue);
    },
  );

  test(
    'append with a changed old prefix cannot retain a full-frame cache',
    () async {
      await controller.readGalleryPreview(0, fullFrame: true);
      ble.afterAppend = (device) => device.pictures[0] = _Picture(color: 2);
      controller.updateDraft(const ComposerDraft(kind: CompositionKind.note));
      await controller.send(saveGallery: true, storeOnly: true);
      expect(controller.gallery, hasLength(3));
      expect(controller.gallery.first.png, isNull);
      expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
    },
  );

  test(
    'external append does not reuse old cache merely because metadata matches',
    () async {
      await controller.readGalleryPreview(0, fullFrame: true);
      a.pictures.add(_Picture());
      a.revision++;
      await controller.refreshGallery();
      expect(controller.gallery.first.png, isNull);
      expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
    },
  );

  test(
    'saved append retains cache even when the independent display fails',
    () async {
      final full = await controller.readGalleryPreview(0, fullFrame: true);
      ble.displayFails = true;
      controller.updateDraft(const ComposerDraft(kind: CompositionKind.note));
      await controller.send(saveGallery: true);
      expect(controller.gallery, hasLength(3));
      expect(controller.gallery.first.png, same(full.png));
      expect(controller.galleryPreviewStatus(0).fullFrame, isTrue);
      expect(controller.message, contains('图片已保存到图库'));
      expect(controller.message, contains('显示作业未正常完成'));
    },
  );

  test('deleting logical slot never transfers the old full cache to the new occupant', () async {
    final full = await controller.readGalleryPreview(0, fullFrame: true);
    await controller.deleteGallery(0);
    expect(controller.gallery, hasLength(1));
    expect(controller.gallery.single.png, isNull);
    final fresh = await controller.readGalleryPreview(0, fullFrame: true);
    expect(fresh.png, isNot(orderedEquals(full.png!)));
  });

  test('deleting picture two retains picture one HD without read or display commands', () async {
    a.current = 0;
    await controller.refreshGallery();
    final full = await controller.readGalleryPreview(0, fullFrame: true);
    final oldIdentity = controller.galleryItemIdentity(0);
    final observedPngs = <Uint8List?>[];
    void observeSurvivor() {
      final survivor = controller.gallery
          .where((item) => item.slot == 0)
          .firstOrNull;
      if (survivor != null) observedPngs.add(survivor.png);
    }

    controller.addListener(observeSurvivor);
    ble.commands.clear();
    ble.commandPackets.clear();
    ble.reads.clear();
    controller.setTab(1);

    await controller.deleteGallery(1);
    expect(controller.gallery, hasLength(1));
    expect(controller.gallery.single.png, same(full.png));
    expect(controller.gallery.single.current, isTrue);
    expect(controller.galleryItemIdentity(0), isNot(oldIdentity));
    expect(controller.galleryPreviewStatus(0).fullFrame, isTrue);
    final cached = await controller.readGalleryPreview(0, fullFrame: true);
    expect(cached.png, same(full.png));
    expect(cached.fullFrame, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await _flush();
    controller.removeListener(observeSurvivor);

    expect(observedPngs, isNotEmpty);
    expect(
      observedPngs,
      everyElement(same(full.png)),
      reason: 'Every notified snapshot must retain the same PNG, without a temporary empty card',
    );
    expect(ble.reads, isEmpty);
    expect(ble.commands, [
      Op.galleryDelete,
      Op.galleryInfo,
      Op.galleryInfo,
      Op.galleryList,
    ]);
    expect(ble.commandPackets.first[2], 1);
    expect(
      ble.commands,
      everyElement(
        isIn([
          Op.galleryDelete,
          Op.galleryInfo,
          Op.galleryList,
          Op.galleryRead,
        ]),
      ),
    );
    controller.setTab(0);
  });

  test('deleting slot zero migrates two distinct HD previews and current to shifted identities', () async {
    a.pictures.add(_Picture(format: 1, color: 0));
    a.current = 2;
    await controller.refreshGallery();
    final deleted = await controller.readGalleryPreview(0, fullFrame: true);
    final second = await controller.readGalleryPreview(1, fullFrame: true);
    final third = await controller.readGalleryPreview(2, fullFrame: true);
    expect(second.png, isNot(orderedEquals(third.png!)));
    final secondIdentity = controller.galleryItemIdentity(1);
    final thirdIdentity = controller.galleryItemIdentity(2);
    ble.reads.clear();
    ble.commands.clear();
    controller.setTab(1);

    await controller.deleteGallery(0);
    expect(controller.gallery.map((item) => item.slot), [0, 1]);
    expect(controller.gallery[0].png, same(second.png));
    expect(controller.gallery[1].png, same(third.png));
    expect(controller.gallery[0].png, isNot(same(deleted.png)));
    expect(controller.gallery[0].current, isFalse);
    expect(controller.gallery[1].current, isTrue);
    expect(controller.galleryItemIdentity(0), isNot(secondIdentity));
    expect(controller.galleryItemIdentity(1), isNot(thirdIdentity));
    for (final slot in [0, 1]) {
      expect(controller.galleryPreviewStatus(slot).fullFrame, isTrue);
      expect(
        (await controller.readGalleryPreview(slot, fullFrame: true)).fullFrame,
        isTrue,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await _flush();
    expect(ble.reads, isEmpty);
    expect(ble.commands, isNot(contains(Op.galleryShow)));
    expect(ble.commands, isNot(contains(Op.cacheShow)));
    expect(ble.commands, isNot(contains(Op.ghostClear)));
    expect(ble.commands, isNot(contains(Op.frameEnd)));
    controller.setTab(0);
  });

  test(
    'deleting the current slot does not mark another cached image as displayed',
    () async {
      a.current = 1;
      await controller.refreshGallery();
      final full = await controller.readGalleryPreview(0, fullFrame: true);
      await controller.deleteGallery(1);
      expect(controller.gallery.single.png, same(full.png));
      expect(controller.gallery.single.current, isFalse);
      expect(controller.galleryPreviewStatus(0).fullFrame, isTrue);
    },
  );

  test(
    'delete revision wrap skips zero while preserving verified HD',
    () async {
      a.revision = 0xffffffff;
      await controller.refreshGallery();
      final full = await controller.readGalleryPreview(0, fullFrame: true);
      await controller.deleteGallery(1);
      expect(a.revision, 1);
      expect(controller.gallery.single.png, same(full.png));
      expect(controller.galleryPreviewStatus(0).fullFrame, isTrue);
    },
  );

  test('deleting the last cached image produces an empty gallery without refreshing the panel', () async {
    await controller.deleteGallery(1);
    a.current = 0;
    await controller.refreshGallery();
    await controller.readGalleryPreview(0, fullFrame: true);
    ble.commands.clear();
    ble.reads.clear();
    controller.setTab(1);
    await controller.deleteGallery(0);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await _flush();
    expect(controller.gallery, isEmpty);
    expect(controller.galleryItemIdentity(0), isNull);
    expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
    expect(controller.galleryPreviewStatus(0).loading, isFalse);
    expect(ble.reads, isEmpty);
    expect(ble.commands, [Op.galleryDelete, Op.galleryInfo, Op.galleryInfo]);
    controller.setTab(0);
  });

  test('a shifted thumbnail survives deletion and remains eligible for automatic HD', () async {
    final thumbnail = await controller.readGalleryPreview(1);
    await controller.deleteGallery(0);
    expect(controller.gallery.single.png, same(thumbnail.png));
    expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
    ble.commands.clear();
    ble.reads.clear();
    controller.setTab(1);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await _flush();
    expect(ble.reads, [(0, 0)]);
    expect(controller.galleryPreviewStatus(0).fullFrame, isTrue);
    expect(img.decodePng(controller.gallery.single.png!)?.width, 768);
    expect(
      ble.commands,
      everyElement(isIn([Op.galleryInfo, Op.galleryList, Op.galleryRead])),
    );
    controller.setTab(0);
  });

  for (final mismatch in [
    'slot',
    'count',
    'current',
    'revision',
    'extra mutation',
    'INFO count',
    'INFO revision',
  ]) {
    test(
      'delete proof rejects inconsistent $mismatch instead of retaining old HD',
      () async {
        await controller.readGalleryPreview(0, fullFrame: true);
        switch (mismatch) {
          case 'slot':
            ble.deleteEventSlot = 0;
          case 'count':
            ble.deleteEventCount = 2;
          case 'current':
            ble.deleteEventCurrent = 0;
          case 'revision':
            ble.afterDelete = (device) => device.revision++;
          case 'extra mutation':
            ble.afterDelete = (device) =>
                device.pictures.add(_Picture(color: 2));
          case 'INFO count':
            ble.afterDelete = (device) => ble.nextInfoCount = 2;
          case 'INFO revision':
            ble.afterDelete = (device) =>
                ble.nextInfoRevision = device.revision + 1;
        }
        await controller.deleteGallery(1);
        expect(controller.gallery.first.png, isNull);
        expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
      },
    );
  }

  test(
    'same frame CRC cannot validate deletion when thumbnail identity changed',
    () async {
      final original = a.pictures[0];
      await controller.readGalleryPreview(0, fullFrame: true);
      ble.afterDelete = (device) {
        device.pictures[0] = _Picture(format: 1, color: 2)
          ..frame = original.frame
          ..frameCrc = original.frameCrc;
      };
      await controller.deleteGallery(1);
      expect(a.pictures.single.frameCrc, original.frameCrc);
      expect(controller.gallery.single.png, isNull);
      expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
      final fresh = await controller.readGalleryPreview(0);
      expect(fresh.fullFrame, isFalse);
      expect(img.decodePng(fresh.png!)?.width, 8);
    },
  );

  test('external deletion without this app completion cannot migrate cached previews', () async {
    await controller.readGalleryPreview(0, fullFrame: true);
    a.pictures.removeAt(1);
    a.revision++;
    await controller.refreshGallery();
    expect(controller.gallery.single.png, isNull);
    expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
  });

  test(
    'failed deletion cannot grant a shifted preview a verified cache identity',
    () async {
      final first = await controller.readGalleryPreview(0, fullFrame: true);
      final second = await controller.readGalleryPreview(1, fullFrame: true);
      final oldIdentity = controller.galleryItemIdentity(0);
      ble.deleteCompletionStatus = StatusCode.flashError;
      ble.mutateOnDeleteFailure = true;
      await controller.deleteGallery(0);
      expect(controller.message, isNot('画面已删除'));
      // A failure may keep the pre-operation snapshot pending an explicit sync;
      // it must never claim that the surviving old slot 1 is already verified.
      if (controller.galleryItemIdentity(0) == oldIdentity) {
        expect(controller.gallery.first.png, same(first.png));
        expect(controller.gallery.first.png, isNot(same(second.png)));
      } else {
        expect(controller.gallery.first.png, isNull);
        expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
      }
      await controller.refreshGallery();
      expect(controller.gallery, hasLength(1));
      expect(controller.gallery.single.png, isNull);
      expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
    },
  );

  test(
    'gallery automatically fetches thumbnails first then full frames',
    () async {
      controller.setTab(1);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await _flush();
      expect(ble.reads, [(0, 1), (1, 1), (0, 0), (1, 0)]);
      expect(controller.galleryPreviewStatus(0).fullFrame, isTrue);
      expect(controller.galleryPreviewStatus(1).fullFrame, isTrue);
      expect(img.decodePng(controller.gallery.first.png!)?.width, 768);
      expect(ble.maxActiveReads, 1);
    },
  );

  test(
    'leaving gallery stops a background full read after its in-flight block',
    () async {
      controller.tabIndex = 1;
      await controller.preloadGalleryPreviews();
      final gate = Completer<void>();
      ble.holdNextRead = gate;
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(controller.galleryReading, isTrue);
      final before = ble.readBlocks.length;
      controller.setTab(0);
      gate.complete();
      await _flush();
      expect(ble.readBlocks.length, before + 1);
      expect(controller.busy, isFalse);
      expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
      expect(controller.galleryPreviewStatus(0).error, isNull);
      expect(ble.reads, [(0, 1), (1, 1), (0, 0)]);
    },
  );

  test(
    'background full read yields to user operation at the next block',
    () async {
      controller.tabIndex = 1;
      await controller.preloadGalleryPreviews();
      final gate = Completer<void>();
      ble.holdNextRead = gate;
      await Future<void>.delayed(const Duration(milliseconds: 650));
      final before = ble.readBlocks.length;
      final action = controller.showGallery(1);
      gate.complete();
      await _flush();
      await action;
      expect(ble.readBlocks.length, before + 1);
      expect(controller.gallery[1].current, isTrue);
      expect(controller.galleryPreviewStatus(0).error, isNull);
      expect(ble.maxActiveReads, 1);
      controller.setTab(0);
    },
  );

  test(
    'background failure is shown once instead of retrying forever',
    () async {
      ble.failedReadStatus = StatusCode.crc;
      await controller.readGalleryPreview(0);
      await controller.readGalleryPreview(1);
      ble.failNextRead = true;
      controller.setTab(1);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await _flush();
      final count = ble.readBlocks.length;
      expect(controller.galleryPreviewStatus(0).error, isNotEmpty);
      expect(controller.gallery.first.png, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await _flush();
      expect(ble.readBlocks.length, count);
      expect(controller.galleryPreviewStatus(1).fullFrame, isTrue);
    },
  );

  test('a temporarily invalid voltage keeps the last connection reading and marks it stale', () async {
    expect(controller.batteryMv, 4000);
    ble.batteryValue = -1;
    await controller.refresh();
    expect(controller.batteryMv, 4000);
    expect(controller.batteryReadingStale, isTrue);
    ble.batteryValue = 3890;
    await controller.refresh();
    expect(controller.batteryMv, 3890);
    expect(controller.batteryReadingStale, isFalse);
    await controller.disconnect();
    expect(controller.batteryMv, isNull);
    expect(controller.batteryLastUpdatedAt, isNull);
  });

  test(
    'a device busy response stops the remaining automatic full-frame reads',
    () async {
      await controller.readGalleryPreview(0);
      await controller.readGalleryPreview(1);
      ble.failNextRead = true;
      controller.setTab(1);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await _flush();
      expect(ble.reads, [(0, 1), (1, 1)]);
      expect(controller.galleryPreviewStatus(0).error, isNotEmpty);
      expect(controller.galleryPreviewStatus(1).fullFrame, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(ble.reads, [(0, 1), (1, 1)]);
      controller.setTab(0);
    },
  );

  test(
    'same-revision metadata replacement cannot reuse a stale full frame',
    () async {
      await controller.readGalleryPreview(0, fullFrame: true);
      final identity = controller.galleryItemIdentity(0);
      a.pictures[0] = _Picture(color: 2);
      await controller.refreshGallery();
      expect(controller.galleryItemIdentity(0), isNot(identity));
      expect(controller.gallery.first.png, isNull);
      expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
    },
  );

  test(
    'real low-battery event payload updates the current voltage directly',
    () async {
      ble.batteryValue = -1;
      await controller.refresh();
      expect(controller.batteryReadingStale, isTrue);
      ble._events.add(
        Uint8List.fromList([0x81, EventId.lowBattery, 0, ..._le16(3580)]),
      );
      await _flush();
      expect(controller.batteryMv, 3580);
      expect(controller.batteryReadingStale, isFalse);
      expect(controller.batteryLastUpdatedAt, isNotNull);
    },
  );

  test('idle status poll updates voltage and resumes full frames after device busy', () async {
    await controller.readGalleryPreview(0);
    await controller.readGalleryPreview(1);
    ble.failNextRead = true;
    controller.setTab(1);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await _flush();
    expect(controller.galleryPreviewStatus(0).error, isNotEmpty);
    expect(controller.galleryPreviewStatus(0).fullFrame, isFalse);
    expect(controller.galleryPreviewStatus(1).fullFrame, isFalse);
    expect(ble.reads, [(0, 1), (1, 1)]);

    final beforePoll = ble.commands.length;
    ble.batteryValue = 3890;
    ble.stateCode = 0;
    // The production poll runs at 15 seconds, then the gallery waits another
    // 600 ms of idle time. This deliberately exercises the actual timers.
    await Future<void>.delayed(const Duration(seconds: 15));
    final finishBudget = Stopwatch()..start();
    while ((!controller.galleryPreviewStatus(0).fullFrame ||
            !controller.galleryPreviewStatus(1).fullFrame) &&
        finishBudget.elapsed < const Duration(seconds: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _flush();
    final later = ble.commands.skip(beforePoll).toList();
    expect(later.first, Op.getStatus);
    expect(later.where((op) => op == Op.getStatus), hasLength(1));
    expect(later, isNot(contains(Op.getSettings)));
    expect(later.take(4), [
      Op.getStatus,
      Op.galleryInfo,
      Op.galleryList,
      Op.galleryRead,
    ]);
    // Each resumed full-frame download lists its own immutable snapshot.
    // The status poll itself must not add an unrelated gallery reload.
    expect(later.where((op) => op == Op.galleryInfo), hasLength(2));
    expect(later.where((op) => op == Op.galleryList), hasLength(2));
    expect(controller.batteryMv, 3890);
    expect(controller.batteryReadingStale, isFalse);
    expect(ble.reads, [(0, 1), (1, 1), (0, 0), (1, 0)]);
    expect(controller.galleryPreviewStatus(0).fullFrame, isTrue);
    expect(controller.galleryPreviewStatus(1).fullFrame, isTrue);
    expect(controller.galleryPreviewStatus(0).error, isNull);
    expect(ble.maxActiveReads, 1);
    controller.setTab(0);
  });

  test('background idle wait cannot steal a foreground job through a microtask gap', () async {
    await controller.readGalleryPreview(0);
    await controller.readGalleryPreview(1);
    final before = ble.readBlocks.length;
    final showGate = Completer<void>();
    ble.holdNextShow = showGate;
    Future<void>? action;
    var scheduled = false;
    void interleave() {
      if (scheduled || !controller.galleryPreviewStatus(0).loading) return;
      scheduled = true;
      // The inner task runs while the queued read yields at its idle await.
      scheduleMicrotask(() {
        scheduleMicrotask(() => action = controller.showGallery(1));
      });
    }

    controller.addListener(interleave);
    controller.setTab(1);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await _flush();
    expect(action, isNotNull);
    expect(controller.phase, '正在刷新屏幕');
    expect(controller.galleryReading, isFalse);
    expect(controller.galleryPreviewStatus(0).loading, isFalse);
    expect(ble.readBlocks.length, before);
    showGate.complete();
    await action;
    await _flush();
    expect(ble.readBlocks.length, before);
    // The cancelled attempt must be eligible for the next idle pass.
    await Future<void>.delayed(const Duration(milliseconds: 650));
    await _flush();
    expect(controller.galleryPreviewStatus(0).fullFrame, isTrue);
    expect(controller.galleryPreviewStatus(1).fullFrame, isTrue);
    expect(ble.reads, [(0, 1), (1, 1), (0, 0), (1, 0)]);
    controller.removeListener(interleave);
    controller.setTab(0);
  });

  test(
    'foreground read rechecks idle after its await before taking the device',
    () async {
      await controller.readGalleryPreview(0);
      final before = ble.readBlocks.length;
      final showGate = Completer<void>();
      ble.holdNextShow = showGate;
      Future<void>? action;
      var scheduled = false;
      void interleave() {
        if (scheduled || !controller.galleryPreviewStatus(0).loading) return;
        scheduled = true;
        scheduleMicrotask(() {
          scheduleMicrotask(() => action = controller.showGallery(1));
        });
      }

      controller.addListener(interleave);
      final reading = controller.readGalleryPreview(0, fullFrame: true);
      await _flush();
      expect(action, isNotNull);
      expect(controller.phase, '正在刷新屏幕');
      expect(controller.galleryReading, isFalse);
      expect(ble.readBlocks.length, before);
      expect(controller.galleryPreviewStatus(0).loading, isTrue);
      showGate.complete();
      await action;
      final result = await reading;
      expect(result.fullFrame, isTrue, reason: result.error);
      expect(ble.reads, [(0, 1), (0, 0)]);
      expect(ble.maxActiveReads, 1);
      controller.removeListener(interleave);
    },
  );
}

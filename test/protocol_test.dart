import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moink_app/core/frame_codec.dart';
import 'package:moink_app/core/protocol.dart';
import 'package:moink_app/core/transport.dart';

class FakeTransport implements MoinkTransport {
  FakeTransport({this.mtu = 517});
  @override
  int mtu;
  @override
  bool isConnected = true;
  final notice = StreamController<Uint8List>.broadcast(sync: true);
  final connection = StreamController<bool>.broadcast(sync: true);
  final ctrl = <Uint8List>[], data = <Uint8List>[];
  FutureOr<void> Function(Uint8List)? onCtrl, onData;
  @override
  Stream<Uint8List> get notifications => notice.stream;
  @override
  Stream<bool> get connectionChanges => connection.stream;
  @override
  Future<void> writeCtrl(Uint8List bytes) async {
    ctrl.add(bytes);
    await onCtrl?.call(bytes);
  }

  @override
  Future<void> writeData(Uint8List bytes) async {
    data.add(bytes);
    await onData?.call(bytes);
  }

  void reply(
    Uint8List request, [
    int status = 0,
    List<int> payload = const [],
  ]) => notice.add(Uint8List.fromList([1, request[1], status, ...payload]));
  void event(int id, int arg, [List<int> payload = const []]) =>
      notice.add(Uint8List.fromList([0x81, id, arg, ...payload]));
  @override
  Future<void> disconnect() async {
    isConnected = false;
    connection.add(false);
  }

  Future<void> close() async {
    await notice.close();
    await connection.close();
  }
}

List<int> le16(int n) => [n & 255, (n >> 8) & 255];
List<int> le32(int n) => [
  n & 255,
  (n >> 8) & 255,
  (n >> 16) & 255,
  (n >> 24) & 255,
];
int u16(Uint8List p, int o) => p[o] | (p[o + 1] << 8);
int u32(Uint8List p, int o) =>
    ByteData.sublistView(p).getUint32(o, Endian.little);
Uint8List hex(String s) => Uint8List.fromList(
  s.split(' ').map((s) => int.parse(s, radix: 16)).toList(),
);
Uint8List firmware([int size = 1025]) => Uint8List(size)
  ..[0] = 0xe9
  ..[12] = 5;

void main() {
  late FakeTransport t;
  late MoinkClient c;
  setUp(() {
    t = FakeTransport();
    c = MoinkClient(
      t,
      commandTimeout: const Duration(milliseconds: 120),
      completionTimeout: const Duration(milliseconds: 180),
      mutationTimeout: const Duration(milliseconds: 120),
    );
  });
  tearDown(() async {
    await c.dispose();
    await t.close();
  });
  void normalFrame({int? chunk, bool store = false, bool only = false}) {
    t.onCtrl = (q) {
      switch (q[0]) {
        case Op.frameBegin:
          t.reply(q, 0, [
            ...le16(chunk ?? u16(q, 13)),
            ...le16(math.min(t.mtu - 5, 512)),
          ]);
          break;
        case Op.frameEnd:
          if (store) t.event(EventId.storeDone, 0, [0, 1, 255]);
          if (!only) t.event(EventId.displayDone, 0);
          t.reply(q, 0, [1]);
          break;
        case Op.frameAbort:
          t.reply(q);
          break;
      }
    };
  }

  test('golden PING wire, matching seq, and serial CTRL queue', () async {
    final vectors = jsonDecode(
      File('test/protocol-vectors.json').readAsStringSync(),
    );
    final messages = vectors['messages'] as List;
    final ping = hex(
      messages.firstWhere((m) => m['id'] == 'ping_request')['hex'] as String,
    );
    t.onCtrl = (q) {
      t.notice.add(Uint8List.fromList([1, (q[1] + 9) & 255, 0, 1, 0]));
      t.reply(q, 0, [1, 6, ...ascii.encode('B2.0.0')]);
    };
    final values = await Future.wait([c.ping(), c.ping()]);
    expect(t.ctrl.first, ping);
    expect(t.ctrl[1], [1, 2]);
    expect(values.first, {'api': 1, 'version': 'B2.0.0'});
  });
  test(
    'timed out seq stays retired after sequence wrap and late response',
    () async {
      await expectLater(c.ping(), throwsA(isA<MoinkException>()));
      t.onCtrl = (q) {
        t.notice.add(
          Uint8List.fromList([1, 1, 0, 1, 4, ...ascii.encode('LATE')]),
        );
        t.reply(q, 0, [1, 2, ...ascii.encode('OK')]);
      };
      for (var i = 0; i < 270; i++) {
        expect((await c.ping())['version'], 'OK');
      }
      expect(t.ctrl.skip(1).any((q) => q[1] == 1), false);
    },
  );
  test('write failure seq also stays retired after sequence wrap', () async {
    t.onCtrl = (q) => throw StateError('write failed');
    await expectLater(c.ping(), throwsA(isA<MoinkException>()));
    t.onCtrl = (q) => t.reply(q, 0, [1, 0]);
    for (var i = 0; i < 260; i++) {
      await c.ping();
    }
    expect(t.ctrl.skip(1).any((q) => q[1] == 1), false);
  });
  test('truncated status and incompatible api are rejected', () async {
    t.onCtrl = (q) => t.reply(q, 0, q[0] == Op.ping ? [2, 0] : [1, 0]);
    await expectLater(c.getStatus(), throwsA(isA<MoinkException>()));
    await expectLater(c.ping(), throwsA(isA<MoinkException>()));
  });
  test(
    'status preserves signed battery readings and unknown sentinel',
    () async {
      var millivolts = 4050;
      t.onCtrl = (q) => t.reply(q, 0, [
        1,
        0,
        0,
        ...le16(millivolts),
        ...le32(42),
        ...le32(48000),
        ...le16(517),
        0,
        ...le32(180),
        0,
        ...le32(3600),
        1,
        6,
        ...ascii.encode('B2.0.0'),
      ]);
      expect((await c.getStatus())['batteryMv'], 4050);
      for (final invalid in [-1, 0, -2000]) {
        millivolts = invalid;
        expect((await c.getStatus())['batteryMv'], isNull);
        expect(c.resultUncertain, false);
        expect(t.isConnected, true);
      }
      millivolts = 3380;
      expect((await c.getStatus())['batteryMv'], 3380);
    },
  );
  test('B1 optional wakeShow and B2 wakeShow are parsed separately', () async {
    final base = [
      0,
      ...le32(180),
      0,
      ...le32(3600),
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
    ];
    t.onCtrl = (q) => t.reply(q, 0, base);
    expect((await c.getSettings())['wakeShowSupported'], false);
    t.onCtrl = (q) => t.reply(q, 0, [...base, 1]);
    expect((await c.getSettings())['wakeShow'], true);
  });
  test('settings golden TLV and whole-transaction validation', () async {
    final args = encodeSettings({
      'sleepS': 180,
      'timeoutAction': 0,
      'autoWakeS': 3600,
      'wakeShow': true,
    });
    expect(args, hex('02 04 B4 00 00 00 03 01 00 04 04 10 0E 00 00 09 01 01'));
    expect(() => encodeSettings({'name': '中文中文中文中'}), throwsArgumentError);
    expect(
      () => encodeSettings({'name': 'bad\u0000name'}),
      throwsArgumentError,
    );
    expect(() => encodeSettings({'sleepS': -1}), throwsArgumentError);
    expect(
      () => encodeSettings({
        'pins': [0, 1, 4, 3, 5, 6, 7, 10],
        'gpioPreset': 2,
      }),
      throwsArgumentError,
    );
    expect(
      () => encodeSettings({
        'pins': [0, 1, 4, 3, 5, 6, 7, 2],
        'gpioPreset': 3,
      }),
      throwsArgumentError,
    );
    expect(() => encodeSettings({'unknown': true}), throwsArgumentError);
    t.onCtrl = (q) => t.reply(q, 0, [4, 0, 0, 0]);
    expect(
      (await c.setSettings({
        'sleepS': 180,
        'timeoutAction': 0,
        'autoWakeS': 3600,
        'wakeShow': true,
      }))['applied'],
      4,
    );
  });
  test('MTU too small rejects a single CTRL instead of splitting it', () async {
    t.mtu = 23;
    await expectLater(
      c.setSettings({'name': '12345678901234567890'}),
      throwsA(isA<MoinkException>()),
    );
    expect(t.ctrl, isEmpty);
  });
  test(
    'modifying RSP timeout is not retried and blocks subsequent modification',
    () async {
      await expectLater(
        c.galleryDelete(0),
        throwsA(
          isA<MoinkException>().having((e) => e.resultUnknown, 'unknown', true),
        ),
      );
      await expectLater(c.galleryClear(), throwsA(isA<MoinkException>()));
      expect(t.ctrl.map((q) => q[0]), [Op.galleryDelete]);
      expect(c.resultUncertain, true);
    },
  );
  test('disconnect fails pending command immediately', () async {
    t.onCtrl = (q) => t.disconnect();
    final watch = Stopwatch()..start();
    await expectLater(c.ping(), throwsA(isA<MoinkException>()));
    expect(watch.elapsedMilliseconds, lessThan(100));
  });
  test('frame honors returned chunk and exact short final fragment', () async {
    t.mtu = 185;
    normalFrame(chunk: 180);
    final result = await c.sendFrame(solidFrame());
    expect(t.data.length, 589);
    expect(t.data.last.length, 146);
    expect(u16(t.data.last, 0), 588);
    expect(result['displayed'], true);
    expect(u16(t.ctrl.first, 11), 0x2698);
    expect(t.data.expand((p) => p.sublist(2)).toList(), solidFrame());
  });
  test('MTU 517 frame negotiates 510 with a device maximum of 512', () async {
    normalFrame();
    final frame = solidFrame();
    await c.sendFrame(frame);
    expect(c.mtu, 517);
    expect(u16(t.ctrl.first, 13), 510);
    expect(t.data.first.length, 512);
    expect(t.data.every((packet) => packet.length <= 512), isTrue);
    expect(t.data.length, 208);
    expect(t.data.last.length, 416);
    expect(t.data.expand((packet) => packet.sublist(2)).toList(), frame);
  });
  test('frame rejects a selected 512-byte chunk above its request', () async {
    normalFrame(chunk: 512);
    await expectLater(
      c.sendFrame(solidFrame()),
      throwsA(isA<MoinkException>()),
    );
    expect(t.data, isEmpty);
    expect(t.ctrl.map((q) => q[0]), [Op.frameBegin, Op.frameAbort]);
  });
  test(
    'store and display completions preceding END RSP are retained',
    () async {
      normalFrame(store: true);
      final result = await c.sendFrame(solidFrame(), saveGallery: true);
      expect(result['stored'], true);
      expect(result['displayed'], true);
    },
  );
  test('store-only waits only STORE_DONE, not DISPLAY_DONE', () async {
    normalFrame(store: true, only: true);
    final result = await c.sendFrame(
      solidFrame(),
      saveGallery: true,
      storeOnly: true,
    );
    expect(t.ctrl.first[2], 6);
    expect(result['displayed'], null);
    expect(result['stored'], true);
  });
  test('partial store/display outcome is exposed independently', () async {
    normalFrame();
    final previous = t.onCtrl!;
    t.onCtrl = (q) {
      if (q[0] == Op.frameEnd) {
        t.event(EventId.storeDone, 0, [0, 1, 0]);
        t.event(EventId.displayDone, 1);
        t.reply(q, 0, [1]);
      } else {
        return previous(q);
      }
    };
    await expectLater(
      c.sendFrame(solidFrame(), saveGallery: true),
      throwsA(
        isA<MoinkException>()
            .having((e) => e.outcome?['stored'], 'stored', true)
            .having((e) => e.outcome?['displayed'], 'displayed', false),
      ),
    );
    expect(t.ctrl.where((q) => q[0] == Op.frameAbort), isEmpty);
  });
  test(
    'STORE success survives DISPLAY timeout as a partial uncertain outcome',
    () async {
      normalFrame();
      final previous = t.onCtrl!;
      t.onCtrl = (q) {
        if (q[0] == Op.frameEnd) {
          t.event(EventId.storeDone, 0, [0, 1, 0]);
          t.reply(q, 0, [1]);
        } else {
          return previous(q);
        }
      };
      await expectLater(
        c.sendFrame(solidFrame(), saveGallery: true),
        throwsA(
          isA<MoinkException>()
              .having((e) => e.resultUnknown, 'unknown', true)
              .having((e) => e.outcome?['stored'], 'stored', true)
              .having((e) => e.outcome?['displayed'], 'displayed', null),
        ),
      );
      expect(t.ctrl.where((q) => q[0] == Op.frameAbort), isEmpty);
      expect(c.resultUncertain, true);
    },
  );
  test('GAP rewinds sequential data with a finite recovery budget', () async {
    normalFrame();
    var sent = false;
    t.onData = (q) {
      if (u16(q, 0) == 3 && !sent) {
        sent = true;
        t.event(EventId.transferGap, 0, le16(1));
      }
    };
    await c.sendFrame(solidFrame());
    expect(t.data.take(7).map((q) => u16(q, 0)), [0, 1, 2, 3, 1, 2, 3]);
  });
  test(
    'INCOMPLETE resumes at expected sequence; CRC restarts whole payload',
    () async {
      normalFrame();
      final previous = t.onCtrl!;
      var ends = 0;
      final total = (frameLength + c.chunkSize - 1) ~/ c.chunkSize;
      t.onCtrl = (q) {
        if (q[0] == Op.frameEnd && ends++ < 2) {
          t.reply(q, ends == 1 ? 9 : 8, le16(ends == 1 ? total - 2 : 0));
        } else {
          return previous(q);
        }
      };
      await c.sendFrame(solidFrame());
      expect(t.ctrl.where((q) => q[0] == Op.frameBegin).length, 1);
      expect(t.data.length, total + 2 + total);
      expect(u16(t.data[total], 0), total - 2);
      expect(u16(t.data[total + 2], 0), 0);
    },
  );
  test('endless recovery stops and aborts the receiving session', () async {
    normalFrame();
    t.onData = (q) => t.event(EventId.transferGap, 0, le16(0));
    await expectLater(
      c.sendFrame(solidFrame()),
      throwsA(isA<MoinkException>()),
    );
    expect(t.ctrl.where((q) => q[0] == Op.frameAbort).length, 1);
    expect(t.data.length, lessThan(12));
  });
  test('cancellation in receiving sends one ABORT', () async {
    normalFrame();
    final cancellation = TransferCancellation();
    t.onData = (q) => cancellation.cancel();
    await expectLater(
      c.sendFrame(solidFrame(), cancellation: cancellation),
      throwsA(isA<MoinkCancelled>()),
    );
    expect(t.ctrl.map((q) => q[0]), [Op.frameBegin, Op.frameAbort]);
  });
  test(
    'cancellation after queue does not ABORT or claim cancellation',
    () async {
      normalFrame();
      final cancellation = TransferCancellation();
      final result = await c.sendFrame(
        solidFrame(),
        cancellation: cancellation,
        onPhase: (p) {
          if (p == TransferPhase.queued) cancellation.cancel();
        },
      );
      expect(result['displayed'], true);
      expect(t.ctrl.where((q) => q[0] == Op.frameAbort), isEmpty);
    },
  );
  test(
    'END enters finalizing before RSP, recovery returns to receiving',
    () async {
      normalFrame();
      final previous = t.onCtrl!;
      var ends = 0;
      final phases = <TransferPhase>[];
      t.onCtrl = (q) {
        if (q[0] == Op.frameEnd) {
          expect(phases.last, TransferPhase.finalizing);
          if (ends++ == 0) {
            t.reply(q, 9, le16(206));
            return Future<void>.value();
          }
        }
        return previous(q);
      };
      await c.sendFrame(solidFrame(), onPhase: phases.add);
      expect(phases, [
        TransferPhase.receiving,
        TransferPhase.finalizing,
        TransferPhase.receiving,
        TransferPhase.finalizing,
        TransferPhase.queued,
        TransferPhase.completed,
      ]);
    },
  );
  test(
    'cancel flag during END wait cannot turn queued success into cancellation',
    () async {
      normalFrame();
      final cancellation = TransferCancellation();
      final result = await c.sendFrame(
        solidFrame(),
        cancellation: cancellation,
        onPhase: (p) {
          if (p == TransferPhase.finalizing) cancellation.cancel();
        },
      );
      expect(result['displayed'], true);
      expect(t.ctrl.where((q) => q[0] == Op.frameAbort), isEmpty);
    },
  );
  test('no END RSP is uncertain and never triggers ABORT', () async {
    normalFrame();
    final previous = t.onCtrl!;
    t.onCtrl = (q) {
      if (q[0] != Op.frameEnd) return previous(q);
    };
    await expectLater(
      c.sendFrame(solidFrame()),
      throwsA(
        isA<MoinkException>().having((e) => e.resultUnknown, 'unknown', true),
      ),
    );
    expect(t.ctrl.where((q) => q[0] == Op.frameAbort), isEmpty);
  });
  test(
    'disconnect during queued job immediately fails waiter without ABORT',
    () async {
      normalFrame();
      final previous = t.onCtrl!;
      t.onCtrl = (q) {
        if (q[0] == Op.frameEnd) {
          t.reply(q, 0, [1]);
          scheduleMicrotask(() => t.disconnect());
        } else {
          return previous(q);
        }
      };
      await expectLater(
        c.sendFrame(solidFrame()),
        throwsA(
          isA<MoinkException>().having((e) => e.resultUnknown, 'unknown', true),
        ),
      );
      expect(t.ctrl.where((q) => q[0] == Op.frameAbort), isEmpty);
    },
  );
  test('job lock spans completion and cacheShow waits DISPLAY_DONE', () async {
    normalFrame();
    final previous = t.onCtrl!;
    final end = Completer<void>();
    t.onCtrl = (q) {
      if (q[0] == Op.frameEnd) {
        t.reply(q, 0, [1]);
        end.complete();
      } else if (q[0] == Op.cacheShow) {
        t.event(EventId.displayDone, 3);
        t.reply(q);
      } else {
        return previous(q);
      }
    };
    final first = c.sendFrame(solidFrame());
    final second = c.cacheShow();
    await end.future;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(t.ctrl.where((q) => q[0] == Op.cacheShow), isEmpty);
    t.event(EventId.displayDone, 0);
    await first;
    await second;
    expect(t.ctrl.last[0], Op.cacheShow);
  });
  test('OTA validates chip and size before sending', () async {
    await expectLater(c.ota(Uint8List(1024)), throwsArgumentError);
    await expectLater(c.ota(firmware(1023)), throwsArgumentError);
    await expectLater(c.ota(firmware(0x160001)), throwsArgumentError);
    expect(t.ctrl, isEmpty);
  });
  test(
    'OTA uses image CRC32 and actual chunk, without padding final fragment',
    () async {
      t.onCtrl = (q) {
        if (q[0] == Op.otaBegin) {
          t.reply(q, 0, [180, 0, 0, 2]);
        } else {
          t.reply(q);
        }
      };
      final image = firmware();
      await c.ota(image);
      expect(u32(t.ctrl.first, 6), crc32(image));
      expect(t.data.length, 6);
      expect(t.data.last.length, 127);
      expect(t.ctrl.last[0], Op.otaEnd);
    },
  );
  test('MTU 517 OTA negotiates 510 with a device maximum of 512', () async {
    t.onCtrl = (q) {
      if (q[0] == Op.otaBegin) {
        t.reply(q, 0, [...le16(u16(q, 10)), ...le16(512)]);
      } else {
        t.reply(q);
      }
    };
    final image = firmware();
    await c.ota(image);
    expect(u16(t.ctrl.first, 10), 510);
    expect(t.data.map((packet) => packet.length), [512, 512, 7]);
    expect(t.data.expand((packet) => packet.sublist(2)).toList(), image);
    expect(t.ctrl.last[0], Op.otaEnd);
  });
  test('OTA rejects a selected 512-byte chunk above its request', () async {
    t.onCtrl = (q) {
      if (q[0] == Op.otaBegin) {
        t.reply(q, 0, [...le16(512), ...le16(512)]);
      } else {
        t.reply(q);
      }
    };
    await expectLater(c.ota(firmware()), throwsA(isA<MoinkException>()));
    expect(t.data, isEmpty);
    expect(t.ctrl.map((q) => q[0]), [Op.otaBegin, Op.otaAbort]);
  });
  test(
    'OTA 65536 sequence limit checked after negotiated BEGIN and aborted',
    () async {
      t.onCtrl = (q) {
        if (q[0] == Op.otaBegin) {
          t.reply(q, 0, [16, 0, 0, 2]);
        } else {
          t.reply(q);
        }
      };
      await expectLater(
        c.ota(firmware(1048577)),
        throwsA(isA<MoinkException>()),
      );
      expect(t.data, isEmpty);
      expect(t.ctrl.map((q) => q[0]), [Op.otaBegin, Op.otaAbort]);
    },
  );
  test(
    'OTA NO_MEM after END is unknown slot outcome and not aborted',
    () async {
      t.onCtrl = (q) {
        if (q[0] == Op.otaBegin) {
          t.reply(q, 0, [...le16(u16(q, 10)), ...le16(512)]);
        } else {
          t.reply(q, 5);
        }
      };
      await expectLater(
        c.ota(firmware()),
        throwsA(
          isA<MoinkException>().having((e) => e.resultUnknown, 'unknown', true),
        ),
      );
      expect(t.ctrl.where((q) => q[0] == Op.otaAbort), isEmpty);
    },
  );
  void gallery({
    bool stale = false,
    bool corrupt = false,
    bool mismatch = false,
    bool pageStale = false,
  }) {
    t.mtu = 39;
    final content = Uint8List(40)..fillRange(0, 40, 0x55);
    final crc = crc16(content);
    t.onCtrl = (q) {
      switch (q[0]) {
        case Op.galleryInfo:
          t.reply(q, 0, [1, 255, 8, ...le32(2)]);
          break;
        case Op.galleryList:
          t.reply(q, 0, [
            ...le32(pageStale ? 3 : 2),
            0,
            1,
            0,
            ...le16(768),
            ...le16(552),
            ...le32(frameLength),
            ...le16(0x2698),
            1,
            ...le16(8),
            ...le16(20),
            ...le32(40),
            ...le16(crc),
          ]);
          break;
        case Op.galleryRead:
          final offset = u32(q, 4);
          if (stale && offset > 0) {
            t.reply(q, 16);
            break;
          }
          final block = content.sublist(offset, offset + u16(q, 8));
          if (corrupt) block[0] = 0;
          t.reply(q, 0, [
            mismatch ? 1 : 0,
            1,
            ...le32(offset),
            ...le32(40),
            ...le16(crc),
            1,
            ...block,
          ]);
          break;
      }
    };
  }

  test('gallery download checks each block metadata and final CRC', () async {
    gallery();
    Map<String, dynamic>? metadata;
    final data = await c.galleryDownload(
      0,
      thumbnail: true,
      onMetadata: (value) => metadata = value,
    );
    expect(metadata?['revision'], 2);
    expect(metadata?['thumbnailW'], 8);
    expect(metadata?['thumbnailH'], 20);
    expect(metadata?['thumbnailFormat'], 1);
    expect(data.length, 40);
    expect(data.every((v) => v == 0x55), true);
    expect(t.ctrl.where((q) => q[0] == Op.galleryRead).map((q) => u32(q, 4)), [
      0,
      20,
    ]);
  });
  test('pre-cancelled gallery read does not send a command', () async {
    gallery();
    final cancellation = TransferCancellation()..cancel();
    await expectLater(
      c.galleryDownload(0, thumbnail: true, cancellation: cancellation),
      throwsA(isA<MoinkCancelled>()),
    );
    expect(t.ctrl, isEmpty);
    expect(c.resultUncertain, false);
  });
  test(
    'gallery cancellation during info does not request list or data',
    () async {
      gallery();
      final cancellation = TransferCancellation();
      final original = t.onCtrl!;
      t.onCtrl = (q) {
        if (q[0] == Op.galleryInfo) cancellation.cancel();
        return original(q);
      };
      await expectLater(
        c.galleryDownload(0, thumbnail: true, cancellation: cancellation),
        throwsA(isA<MoinkCancelled>()),
      );
      expect(t.ctrl.map((q) => q[0]), [Op.galleryInfo]);
    },
  );
  test(
    'gallery cancellation between blocks never requests the next one',
    () async {
      gallery();
      final cancellation = TransferCancellation();
      var metadataPublished = false;
      await expectLater(
        c.galleryDownload(
          0,
          thumbnail: true,
          cancellation: cancellation,
          onProgress: (_) => cancellation.cancel(),
          onMetadata: (_) => metadataPublished = true,
        ),
        throwsA(isA<MoinkCancelled>()),
      );
      expect(t.ctrl.where((q) => q[0] == Op.galleryRead).length, 1);
      expect(t.ctrl.where((q) => q[0] == Op.frameAbort), isEmpty);
      expect(t.ctrl.where((q) => q[0] == Op.otaAbort), isEmpty);
      expect(metadataPublished, false);
    },
  );
  test(
    'cancelling a final block never publishes a completed preview',
    () async {
      gallery();
      final cancellation = TransferCancellation();
      var metadataPublished = false;
      await expectLater(
        c.galleryDownload(
          0,
          thumbnail: true,
          cancellation: cancellation,
          onProgress: (progress) {
            if (progress == 1) cancellation.cancel();
          },
          onMetadata: (_) => metadataPublished = true,
        ),
        throwsA(isA<MoinkCancelled>()),
      );
      expect(t.ctrl.where((q) => q[0] == Op.galleryRead).length, 2);
      expect(metadataPublished, false);
    },
  );
  test(
    'in-flight gallery cancellation drains reply and leaves connection usable',
    () async {
      gallery();
      final cancellation = TransferCancellation();
      final started = Completer<void>(), release = Completer<void>();
      final original = t.onCtrl!;
      t.onCtrl = (q) async {
        if (q[0] == Op.galleryRead) {
          started.complete();
          await release.future;
        }
        await original(q);
      };
      final read = c.galleryDownload(
        0,
        thumbnail: true,
        cancellation: cancellation,
      );
      final cancelled = expectLater(read, throwsA(isA<MoinkCancelled>()));
      await started.future;
      cancellation.cancel();
      expect(t.ctrl.where((q) => q[0] == Op.galleryRead).length, 1);
      release.complete();
      await cancelled;
      expect(c.resultUncertain, false);
      expect(t.isConnected, true);
      t.onCtrl = (q) => t.reply(q, 0, [1, 0, 0, 0]);
      expect((await c.setSettings({'sleepS': 240}))['applied'], 1);
      expect(t.ctrl.map((q) => q[0]), [
        Op.galleryInfo,
        Op.galleryList,
        Op.galleryRead,
        Op.setSettings,
      ]);
    },
  );
  test('presentation error does not cancel a gallery download', () async {
    gallery();
    final data = await c.galleryDownload(
      0,
      thumbnail: true,
      onProgress: (_) => throw StateError('widget already disposed'),
    );
    expect(data.length, 40);
    expect(data.every((v) => v == 0x55), true);
    expect(t.ctrl.where((q) => q[0] == Op.galleryRead).length, 2);
  });
  test(
    'gallery STALE drops partial data without retry or revision substitution',
    () async {
      gallery(stale: true);
      await expectLater(
        c.galleryDownload(0, thumbnail: true),
        throwsA(isA<MoinkException>().having((e) => e.status, 'status', 16)),
      );
      expect(t.ctrl.where((q) => q[0] == Op.galleryRead).length, 2);
      expect(t.ctrl.where((q) => q[0] == Op.galleryInfo).length, 1);
    },
  );
  test('changed list revision is rejected', () async {
    gallery(pageStale: true);
    await expectLater(
      c.galleryList(),
      throwsA(isA<MoinkException>().having((e) => e.status, 'status', 16)),
    );
  });
  test('download CRC and identity mismatch are rejected', () async {
    gallery(corrupt: true);
    await expectLater(
      c.galleryDownload(0, thumbnail: true),
      throwsA(isA<MoinkException>().having((e) => e.status, 'status', 8)),
    );
    gallery(mismatch: true);
    await expectLater(
      c.galleryDownload(0, thumbnail: true),
      throwsA(isA<MoinkException>()),
    );
  });
  test(
    'remaining maintenance, gallery and clear commands encode correct ops',
    () async {
      t.onCtrl = (q) {
        if (q[0] == Op.galleryShow) t.event(EventId.displayDone, 4);
        if (q[0] == Op.ghostClear) t.event(EventId.displayDone, 2);
        if (q[0] == Op.galleryDelete || q[0] == Op.galleryClear) {
          t.event(EventId.storeDone, 0, [255, 0, 255]);
        }
        t.reply(q);
      };
      await c.galleryNext();
      await c.ghostClear(cycles: 4);
      await c.galleryDelete(0);
      await c.galleryClear();
      await c.abortFrame();
      await c.abortOta();
      await c.reboot();
      await c.factoryReset();
      await c.sleepNow();
      expect(t.ctrl.map((q) => q[0]), [
        0x23,
        0x30,
        0x24,
        0x25,
        0x13,
        0x43,
        0x50,
        0x51,
        0x52,
      ]);
      expect(t.ctrl.first.sublist(2), [255]);
    },
  );
}

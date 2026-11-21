import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:esp_ink/core/frame_codec.dart';
import 'package:esp_ink/core/protocol.dart';
import 'package:esp_ink/core/transport.dart';

List<int> _u16(int v) => [v & 255, (v >> 8) & 255];
List<int> _u32(int v) => [..._u16(v), ..._u16(v >> 16)];
int _read32(Uint8List v, int o) =>
    ByteData.sublistView(v).getUint32(o, Endian.little);

/// Real protocol client, deferred RSPs and completion events; no radio model.
class _DisplayLink implements EspInkTransport {
  final notices = StreamController<Uint8List>.broadcast(sync: true);
  final links = StreamController<bool>.broadcast(sync: true);
  final commands = <int>[];
  final frame = Uint8List.fromList(List.generate(1400, (i) => i & 255));
  late final checksum = crc16(frame);
  int revision = 7;
  int state = 0;
  int? flags;
  Completer<void>? holdRead;
  final beganDisplay = Completer<void>();
  final beganRead = Completer<void>();
  int readBlocks = 0;
  bool closeOnFirstBlock = false;
  bool autoDelete = true;
  void Function()? afterStatusReply;
  bool finishDisplayBeforeReply = false;
  @override
  bool isConnected = true;
  @override
  int get mtu => 517;
  @override
  Stream<Uint8List> get notifications => notices.stream;
  @override
  Stream<bool> get connectionChanges => links.stream;
  void event(int id, int arg, [List<int> payload = const []]) =>
      notices.add(Uint8List.fromList([0x81, id, arg, ...payload]));
  void reply(Uint8List p, [List<int> payload = const []]) =>
      notices.add(Uint8List.fromList([1, p[1], 0, ...payload]));
  void window(bool open, {int displayState = 3}) {
    state = displayState;
    flags = open ? 3 : 1;
    event(EventId.state, state, [flags!]);
  }

  void finish(int result) {
    state = 0;
    flags = flags == null ? null : 1;
    event(EventId.displayDone, result);
  }

  @override
  Future<void> writeCtrl(Uint8List p) async {
    commands.add(p[0]);
    switch (p[0]) {
      case Op.getStatus:
        reply(p, [
          1,
          state,
          0,
          ..._u16(3900),
          ..._u32(1),
          ..._u32(60000),
          ..._u16(517),
          0,
          ..._u32(180),
          0,
          ..._u32(0),
          0,
          2,
          66,
          50,
          ?flags,
        ]);
        afterStatusReply?.call();
      case Op.galleryInfo:
        reply(p, [1, 255, 8, ..._u32(revision)]);
      case Op.galleryList:
        reply(p, [
          ..._u32(revision),
          0,
          1,
          0,
          ..._u16(40),
          ..._u16(140),
          ..._u32(frame.length),
          ..._u16(checksum),
          1,
          ..._u16(40),
          ..._u16(140),
          ..._u32(frame.length),
          ..._u16(checksum),
        ]);
      case Op.galleryRead:
        readBlocks++;
        if (!beganRead.isCompleted) beganRead.complete();
        await holdRead?.future;
        final offset = _read32(p, 4);
        final requested = ByteData.sublistView(p).getUint16(8, Endian.little);
        final end = math.min(offset + requested, frame.length);
        if (closeOnFirstBlock && readBlocks == 1) window(false);
        reply(p, [
          0,
          p[3],
          ..._u32(offset),
          ..._u32(frame.length),
          ..._u16(checksum),
          1,
          ...frame.sublist(offset, end),
        ]);
      case Op.galleryShow:
      case Op.cacheShow:
      case Op.ghostClear:
        state = p[0] == Op.ghostClear ? 4 : 3;
        if (finishDisplayBeforeReply) {
          window(true, displayState: state);
          finish(
            p[0] == Op.galleryShow
                ? 4
                : p[0] == Op.cacheShow
                ? 3
                : 2,
          );
        }
        reply(p);
        if (!beganDisplay.isCompleted) beganDisplay.complete();
      case Op.galleryDelete:
        reply(p);
        if (autoDelete) event(EventId.storeDone, 0, [0, 0, 255]);
      case Op.frameBegin:
        reply(p, [..._u16(510), ..._u16(512)]);
      case Op.frameEnd:
        reply(p, [1]);
        if (!beganDisplay.isCompleted) beganDisplay.complete();
      default:
        reply(p);
    }
  }

  @override
  Future<void> writeData(Uint8List bytes) async {}
  @override
  Future<void> disconnect() async {
    isConnected = false;
    links.add(false);
  }

  Future<void> close() async {
    await notices.close();
    await links.close();
  }
}

void main() {
  late _DisplayLink link;
  late EspInkClient client;
  setUp(() {
    link = _DisplayLink();
    client = EspInkClient(
      link,
      commandTimeout: const Duration(seconds: 2),
      completionTimeout: const Duration(seconds: 2),
    );
  });
  tearDown(() async {
    await client.dispose();
    await link.close();
  });
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 5));

  test(
    'optional window flags fail closed for old, idle and unknown states',
    () async {
      expect((await client.getStatus())['galleryReadSupported'], false);
      link.flags = 3;
      expect((await client.getStatus())['galleryReadReady'], false);
      link.state = 3;
      expect((await client.getStatus())['galleryReadReady'], true);
      expect(client.galleryReadAvailable, true);
      link.window(false);
      expect(client.galleryReadAvailable, false);
      link.window(true, displayState: 2);
      expect(client.galleryReadAvailable, false);
    },
  );

  test(
    'append proof requires its flag and an admitted physical display window',
    () async {
      link.flags = 7;
      expect((await client.getStatus())['galleryAppendCommitted'], isFalse);
      expect(client.galleryAppendCommitted, isFalse);
      final display = client.galleryShow(0);
      await link.beganDisplay.future;
      link.window(true);
      await tick();
      expect(client.galleryReadAvailable, isTrue);
      expect(client.galleryAppendCommitted, isFalse);
      link.event(EventId.state, 3, [5]);
      expect(client.galleryAppendCommitted, isFalse);
      link.event(EventId.state, 3, [7]);
      expect(client.galleryAppendCommitted, isTrue);
      link.window(false);
      expect(client.galleryAppendCommitted, isFalse);
      link.event(EventId.state, 3, [7]);
      final deletion = client.galleryDelete(0);
      expect(client.galleryReadAvailable, isFalse);
      expect(client.galleryAppendCommitted, isFalse);
      link.finish(4);
      await Future.wait([display, deletion]);
      expect(client.galleryAppendCommitted, isFalse);
    },
  );

  for (final operation in [Op.galleryShow, Op.cacheShow, Op.ghostClear]) {
    test(
      'READ completes before display completion for op $operation',
      () async {
        final display = switch (operation) {
          Op.galleryShow => client.galleryShow(0),
          Op.cacheShow => client.cacheShow(),
          _ => client.ghostClear(),
        };
        var displayed = false;
        unawaited(display.then((_) => displayed = true));
        await link.beganDisplay.future;
        link.window(true, displayState: operation == Op.ghostClear ? 4 : 3);
        await tick();
        expect(client.galleryReadAvailable, true);
        expect(await client.galleryDownload(0), link.frame);
        expect(displayed, false);
        link.finish(
          operation == Op.galleryShow
              ? 4
              : operation == Op.cacheShow
              ? 3
              : 2,
        );
        await display;
        expect(client.galleryReadAvailable, false);
      },
    );
  }

  test(
    'save-and-display can read after store work but before late STORE_DONE',
    () async {
      final send = client.sendFrame(solidFrame(), saveGallery: true);
      await link.beganDisplay.future;
      link.window(true);
      await tick();
      expect(client.galleryReadAvailable, true);
      expect(await client.galleryDownload(0), link.frame);
      link.event(EventId.storeDone, 0, [1, 2, 1]);
      link.finish(0);
      expect((await send)['stored'], true);
    },
  );

  test('old firmware queues gallery behind complete display job', () async {
    final display = client.galleryShow(0);
    await link.beganDisplay.future;
    final read = client.galleryDownload(0);
    await tick();
    expect(link.commands, [Op.galleryShow]);
    link.finish(4);
    await display;
    expect(await read, link.frame);
  });

  test(
    'queued mutation closes admission and runs before a later gallery read',
    () async {
      final display = client.galleryShow(0);
      await link.beganDisplay.future;
      link.window(true);
      await tick();
      final deletion = client.galleryDelete(0);
      final read = client.galleryDownload(0);
      await tick();
      expect(client.galleryReadAvailable, false);
      expect(link.commands, [Op.galleryShow]);
      link.finish(4);
      await Future.wait([display, deletion, read]);
      expect(
        link.commands.indexOf(Op.galleryDelete),
        lessThan(link.commands.indexOf(Op.galleryInfo)),
      );
    },
  );

  test(
    'display completion and next mutation drain the read RSP already in flight',
    () async {
      final display = client.galleryShow(0);
      await link.beganDisplay.future;
      link.window(true);
      await tick();
      link.holdRead = Completer<void>();
      final read = client.galleryDownload(0);
      final checkedRead = expectLater(
        read,
        throwsA(
          isA<EspInkException>().having(
            (e) => e.status,
            'status',
            StatusCode.busy,
          ),
        ),
      );
      await link.beganRead.future;
      final deletion = client.galleryDelete(0);
      link.finish(4);
      await display;
      await tick();
      expect(link.commands, isNot(contains(Op.galleryDelete)));
      link.holdRead!.complete();
      await checkedRead;
      await deletion;
      expect(link.readBlocks, 1);
    },
  );

  test(
    'closing window drains current response and stops before next READ',
    () async {
      final display = client.galleryShow(0);
      await link.beganDisplay.future;
      link.window(true);
      await tick();
      link.closeOnFirstBlock = true;
      await expectLater(
        client.galleryDownload(0),
        throwsA(
          isA<EspInkException>().having(
            (e) => e.status,
            'status',
            StatusCode.busy,
          ),
        ),
      );
      expect(link.readBlocks, 1);
      link.finish(4);
      await display;
    },
  );

  test(
    'expected revision rejects changed upload metadata before reading bytes',
    () async {
      await expectLater(
        client.galleryDownload(0, expectedRevision: 6),
        throwsA(
          isA<EspInkException>().having(
            (e) => e.status,
            'status',
            StatusCode.stale,
          ),
        ),
      );
      expect(link.readBlocks, 0);
    },
  );

  for (final newerEvent in ['STATE close', 'STATE open', 'DISPLAY_DONE']) {
    test(
      'a completed status RSP cannot overwrite a newer $newerEvent notification',
      () async {
        link.state = 3;
        link.flags = newerEvent == 'STATE open' ? 1 : 3;
        link.afterStatusReply = () {
          if (newerEvent == 'DISPLAY_DONE') {
            link.finish(4);
          } else {
            link.window(newerEvent == 'STATE open', displayState: 4);
          }
        };
        // The RSP is delivered first, but getStatus resumes in a later microtask.
        // The immediately following event is therefore the newer device state.
        final status = await client.getStatus();
        expect(client.galleryReadAvailable, newerEvent == 'STATE open');
        expect(status['galleryReadReady'], newerEvent == 'STATE open');
        expect(status['stateCode'], newerEvent == 'DISPLAY_DONE' ? 0 : 4);
        expect(
          status['state'],
          newerEvent == 'DISPLAY_DONE' ? 'idle' : 'clearing',
        );
      },
    );
  }

  test('a read started by a readiness listener cannot overtake the mutation that notified it', () async {
    final display = client.galleryShow(0);
    await link.beganDisplay.future;
    link.window(true);
    await tick();
    var requested = false;
    Future<Uint8List>? reentrantRead;
    final subscription = client.galleryReadinessChanges.listen((_) {
      if (!requested && !client.galleryReadAvailable) {
        requested = true;
        reentrantRead = client.galleryDownload(0);
      }
    });
    addTearDown(subscription.cancel);
    final deletion = client.galleryDelete(0);
    await tick();
    expect(requested, isTrue);
    expect(reentrantRead, isNotNull);
    expect(link.commands, [Op.galleryShow]);
    link.finish(4);
    await Future.wait([display, deletion, reentrantRead!])
        .timeout(const Duration(seconds: 2));
    expect(
      link.commands.indexOf(Op.galleryDelete),
      lessThan(link.commands.indexOf(Op.galleryInfo)),
      reason: 'The mutation tail must be published before readiness callbacks can snapshot it',
    );
  });

  test('early STATE and DISPLAY_DONE preceding RSP cannot reopen a completed display window', () async {
    link.finishDisplayBeforeReply = true;
    await client.galleryShow(0);
    expect(client.galleryReadAvailable, isFalse);
    expect(link.commands, [Op.galleryShow]);
    expect(await client.galleryDownload(0), link.frame);
    expect(link.readBlocks, 3);
  });

  test(
    'a new mutation cannot reuse a preceding external display window',
    () async {
      link.window(true);
      expect(client.galleryReadAvailable, isTrue);
      final display = client.galleryShow(0);
      await link.beganDisplay.future;
      await tick();
      expect(client.galleryReadAvailable, isFalse);
      final read = client.galleryDownload(0);
      await tick();
      expect(link.commands, [Op.galleryShow]);
      link.finish(4);
      await display;
      expect(await read, link.frame);
      expect(link.readBlocks, 3);
    },
  );

  test('disconnect fails display, in-flight read and queued mutation without issuing another command', () async {
    final display = client.galleryShow(0);
    final checkedDisplay = expectLater(
      display,
      throwsA(isA<EspInkException>()),
    );
    await link.beganDisplay.future;
    link.window(true);
    await tick();
    link.holdRead = Completer<void>();
    final read = client.galleryDownload(0);
    final checkedRead = expectLater(read, throwsA(isA<EspInkException>()));
    await link.beganRead.future;
    final deletion = client.galleryDelete(0);
    final checkedDeletion = expectLater(
      deletion,
      throwsA(isA<EspInkException>()),
    );
    final before = List<int>.of(link.commands);
    await link.disconnect();
    link.holdRead!.complete();
    await Future.wait([checkedDisplay, checkedRead, checkedDeletion]);
    expect(client.galleryReadAvailable, isFalse);
    expect(link.commands, before);
    expect(link.commands, isNot(contains(Op.galleryDelete)));
    expect(link.readBlocks, 1);
  });
}

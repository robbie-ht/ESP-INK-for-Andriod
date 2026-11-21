import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moink_app/core/frame_codec.dart';
import 'package:moink_app/core/protocol.dart';
import 'package:moink_app/core/transport.dart';

List<int> _le16(int value) => [value & 255, (value >> 8) & 255];
List<int> _le32(int value) => [..._le16(value), ..._le16(value >> 16)];
int _u16(Uint8List value, int offset) =>
    ByteData.sublistView(value).getUint16(offset, Endian.little);
int _u32(Uint8List value, int offset) =>
    ByteData.sublistView(value).getUint32(offset, Endian.little);

/// Models the existing firmware's MTU - 19 read cap, before any firmware fix.
/// The Android receive gate must run before bytes reach MoinkClient: delivering
/// a 514-byte notification directly to Dart would hide the MTU 517 regression.
class _LegacyGalleryTransport implements MoinkTransport {
  _LegacyGalleryTransport(this.mtu);

  @override
  final int mtu;
  @override
  bool isConnected = true;

  final _notices = StreamController<Uint8List>.broadcast(sync: true);
  final _connections = StreamController<bool>.broadcast(sync: true);
  final frame = Uint8List.fromList(
    List.generate(frameLength, (index) => (index * 37 + (index >> 8)) & 255),
  );
  final thumbnail = Uint8List.fromList(
    List.generate(192 * 138 ~/ 4, (index) => (index * 53 + (index >> 4)) & 255),
  );
  late final frameCrc = crc16(frame);
  late final thumbnailCrc = crc16(thumbnail);
  final readRequests = <Uint8List>[];
  final attemptedNotifications = <Uint8List>[];
  final discardedNotifications = <Uint8List>[];

  @override
  Stream<Uint8List> get notifications => _notices.stream;
  @override
  Stream<bool> get connectionChanges => _connections.stream;

  void _reply(Uint8List request, List<int> payload) {
    final response = Uint8List.fromList([1, request[1], 0, ...payload]);
    attemptedNotifications.add(response);
    // Android rejects the whole overlong attribute value, not just its tail.
    if (response.length > 512) {
      discardedNotifications.add(response);
      return;
    }
    _notices.add(response);
  }

  @override
  Future<void> writeCtrl(Uint8List request) async {
    switch (request[0]) {
      case Op.galleryInfo:
        _reply(request, [1, 255, 8, ..._le32(2)]);
        break;
      case Op.galleryList:
        _reply(request, [
          ..._le32(2),
          0,
          1,
          0,
          ..._le16(768),
          ..._le16(552),
          ..._le32(frame.length),
          ..._le16(frameCrc),
          1,
          ..._le16(192),
          ..._le16(138),
          ..._le32(thumbnail.length),
          ..._le16(thumbnailCrc),
        ]);
        break;
      case Op.galleryRead:
        readRequests.add(Uint8List.fromList(request));
        final content = request[3] == 1 ? thumbnail : frame;
        final offset = _u32(request, 4);
        final length = math.min(
          math.min(_u16(request, 8), mtu - 19),
          content.length - offset,
        );
        _reply(request, [
          request[2],
          request[3],
          ..._le32(offset),
          ..._le32(content.length),
          ..._le16(request[3] == 1 ? thumbnailCrc : frameCrc),
          1,
          ...content.sublist(offset, offset + length),
        ]);
        break;
      default:
        throw StateError('Unexpected command ${request[0]}');
    }
  }

  @override
  Future<void> writeData(Uint8List bytes) async =>
      throw StateError('Gallery reads use CTRL only');

  @override
  Future<void> disconnect() async {
    isConnected = false;
    _connections.add(false);
  }

  Future<void> close() async {
    await _notices.close();
    await _connections.close();
  }
}

void main() {
  for (final mtu in [517, 516, 515, 512, 247, 185]) {
    for (final thumbnail in [true, false]) {
      test(
        'MTU $mtu ${thumbnail ? 'thumbnail' : 'full frame'} download survives '
        'Android 512-byte receive limit with unchanged firmware',
        () async {
          final transport = _LegacyGalleryTransport(mtu);
          final client = MoinkClient(
            transport,
            commandTimeout: const Duration(milliseconds: 120),
          );
          addTearDown(() async {
            await client.dispose();
            await transport.close();
          });
          final expected = thumbnail ? transport.thumbnail : transport.frame;
          Map<String, dynamic>? metadata;
          final progress = <double>[];

          final received = await client.galleryDownload(
            0,
            thumbnail: thumbnail,
            onMetadata: (value) => metadata = value,
            onProgress: progress.add,
          );

          expect(client.mtu, mtu, reason: 'Keep the real negotiated MTU');
          expect(received, orderedEquals(expected));
          expect(crc16(received), crc16(expected));
          expect(metadata?['revision'], 2);
          expect(
            metadata?[thumbnail ? 'thumbnailLen' : 'len'],
            expected.length,
          );
          expect(
            metadata?[thumbnail ? 'thumbnailCrc16' : 'crc16'],
            crc16(expected),
          );
          expect(progress.last, 1);
          expect(transport.discardedNotifications, isEmpty);
          expect(
            transport.attemptedNotifications.map((value) => value.length),
            everyElement(lessThanOrEqualTo(math.min(mtu - 3, 512))),
          );

          final maximumData = math.min(mtu - 19, 496);
          var offset = 0;
          for (final request in transport.readRequests) {
            expect(request[2], 0);
            expect(request[3], thumbnail ? 1 : 0);
            expect(_u32(request, 4), offset);
            expect(_u32(request, 10), 2);
            final requested = _u16(request, 8);
            expect(requested, inInclusiveRange(1, maximumData));
            offset += requested;
          }
          expect(offset, expected.length);
          expect(
            transport.readRequests.length,
            (expected.length / maximumData).ceil(),
          );
        },
      );
    }
  }

  test('receive model discards the old MTU 517 request of 498 bytes', () async {
    final transport = _LegacyGalleryTransport(517);
    addTearDown(transport.close);
    final received = <Uint8List>[];
    final subscription = transport.notifications.listen(received.add);
    addTearDown(subscription.cancel);

    Uint8List request(int length) => Uint8List.fromList([
      Op.galleryRead,
      1,
      0,
      1,
      ..._le32(0),
      ..._le16(length),
      ..._le32(2),
    ]);

    await transport.writeCtrl(request(498));
    expect(transport.attemptedNotifications.single.length, 514);
    expect(transport.discardedNotifications.single.length, 514);
    expect(received, isEmpty);

    await transport.writeCtrl(request(496));
    expect(transport.attemptedNotifications.last.length, 512);
    expect(transport.discardedNotifications.length, 1);
    expect(received.single.length, 512);
    expect(received.single.sublist(16), transport.thumbnail.sublist(0, 496));
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:esp_ink/core/frame_codec.dart';

void main() {
  final vectors = jsonDecode(
    File('test/protocol-vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  test('official CRC gold vector', () {
    final v = (vectors['crc_vectors'] as List).first;
    final bytes = ascii.encode(v['input_ascii'] as String);
    expect(crc16(bytes), int.parse(v['crc16_hex'] as String, radix: 16));
    expect(crc32(bytes), int.parse(v['crc32_hex'] as String, radix: 16));
  });
  test('official white full frame and thumbnail CRC vectors', () {
    for (final v in vectors['payloads'] as List) {
      final packed = solidFrame(
        width: v['width'] as int,
        height: v['height'] as int,
      );
      expect(packed.length, v['count']);
      expect(packed.every((b) => b == 0x55), isTrue);
      expect(crc16(packed), int.parse(v['crc16_hex'] as String, radix: 16));
    }
  });
  test('four logical corners land at exact 180 degree wire positions', () {
    final codes = Uint8List(8 * 4)..fillRange(0, 32, 1);
    codes[0] = 0;
    codes[7] = 2;
    codes[24] = 3;
    codes[31] = 0;
    final packed = pack2bpp(codes, width: 8, height: 4);
    expect(packed[0] >> 6, 0); // logical bottom-right becomes wire top-left
    expect(packed[1] & 3, 3); // logical bottom-left becomes wire top-right
    expect(packed[6] >> 6, 2); // logical top-right becomes wire bottom-left
    expect(packed[7] & 3, 0); // logical top-left becomes wire bottom-right
    expect(unpack2bpp(packed, width: 8, height: 4), codes);
  });
  test('wire ordering independently known for a two row thumbnail', () {
    expect(pack2bpp([0, 1, 2, 3, 3, 2, 1, 0], width: 4, height: 2), [
      0x1b,
      0xe4,
    ]);
    expect(unpack2bpp([0x1b, 0xe4], width: 4, height: 2), [
      0,
      1,
      2,
      3,
      3,
      2,
      1,
      0,
    ]);
  });
  test('all solid color encodings and strict validation', () {
    for (var c = 0; c < 4; c++) {
      expect(solidFrame(color: c, width: 4, height: 1), [0x55 * c]);
    }
    expect(
      () => pack2bpp([0, 1, 2, 4], width: 4, height: 1),
      throwsArgumentError,
    );
    expect(() => unpack2bpp([0], width: 8, height: 1), throwsArgumentError);
    expect(() => solidFrame(width: 5, height: 1), throwsArgumentError);
    expect(() => solidFrame(height: 0), throwsArgumentError);
  });
}

import 'dart:typed_data';

const frameWidth = 768;
const frameHeight = 552;
const frameLength = frameWidth * frameHeight ~/ 4;

/// CRC-16/CCITT-FALSE; only payload bytes, never DATA headers.
int crc16(List<int> data) {
  var crc = 0xffff;
  for (final byte in data) {
    crc ^= byte << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = ((crc << 1) ^ ((crc & 0x8000) != 0 ? 0x1021 : 0)) & 0xffff;
    }
  }
  return crc;
}

/// CRC-32/ISO-HDLC (same result as zlib.crc32).
int crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

void _geometry(int width, int height) {
  if (width <= 0 || height <= 0 || width % 4 != 0) {
    throw ArgumentError('宽度须为正的4倍数，高度须为正数');
  }
}

/// Logical top-left row-major color codes: black=0, white=1, yellow=2, red=3.
/// Rotate 180 degrees, then pack four pixels per byte, most significant first.
Uint8List pack2bpp(
  List<int> codes, {
  int width = frameWidth,
  int height = frameHeight,
}) {
  _geometry(width, height);
  if (codes.length != width * height) {
    throw ArgumentError('像素数量与尺寸不符');
  }
  final out = Uint8List(codes.length ~/ 4);
  for (var i = 0; i < codes.length; i++) {
    final code = codes[codes.length - 1 - i];
    if (code < 0 || code > 3) throw ArgumentError('色码须为0..3');
    out[i ~/ 4] |= code << (6 - (i % 4) * 2);
  }
  return out;
}

Uint8List unpack2bpp(
  List<int> packed, {
  int width = frameWidth,
  int height = frameHeight,
}) {
  _geometry(width, height);
  if (packed.length != width * height ~/ 4) {
    throw ArgumentError('2bpp载荷长度与尺寸不符');
  }
  final out = Uint8List(width * height);
  for (var i = 0; i < out.length; i++) {
    out[out.length - 1 - i] = (packed[i ~/ 4] >> (6 - (i % 4) * 2)) & 3;
  }
  return out;
}

Uint8List solidFrame({
  int color = 1,
  int width = frameWidth,
  int height = frameHeight,
}) {
  _geometry(width, height);
  if (color < 0 || color > 3) throw ArgumentError('色码须为0..3');
  return Uint8List(width * height ~/ 4)
    ..fillRange(0, width * height ~/ 4, color * 0x55);
}

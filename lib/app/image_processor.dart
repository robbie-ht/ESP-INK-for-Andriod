import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../core/frame_codec.dart';
import '../core/image_filters.dart';
import 'artwork.dart';
import 'models.dart';
import 'photo_decode.dart';

class ProcessedArtwork {
  const ProcessedArtwork(this.packed, this.png);
  final Uint8List packed, png;
}

Map<String, Object> filterOptions(ImageAdjustments a) => {
  'mode': a.style.name,
  'dither': a.dither.name,
  'space': a.colorSpace == ColorSpaceMode.standard ? 'std' : a.colorSpace.name,
  'brightness': a.brightness,
  'contrast': a.contrast,
  'gamma': a.gamma,
  'saturation': a.saturation,
  'warmCast': a.warmCast,
  'castRamp': a.castRamp,
  'warmCenter': a.warmCenter,
  'warmSpan': a.warmSpan,
  'warmBoost': a.warmBoost,
  'coolPull': a.coolPull,
  'coolCap': a.coolCap,
  'coolDesat': a.coolDesat,
  'warmPull': a.warmPull,
  'warmPullCap': a.warmPullCap,
  'autoLevels': a.autoLevels,
  'sharpen': a.sharpen,
  'ditherStrength': a.ditherStrength,
};

Future<Uint8List> _render(void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final picture = recorder.endRecording();
  ui.Image? rendered;
  try {
    rendered = await picture.toImage(frameWidth, frameHeight);
    final bytes = await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) throw StateError('无法渲染这张图片');
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    rendered?.dispose();
    picture.dispose();
  }
}

Future<ui.Image> _imageFromRgba(Uint8List rgba) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: frameWidth,
    height: frameHeight,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  ui.Codec? codec;
  try {
    codec = await descriptor.instantiateCodec();
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

/// Photo color processing runs first, then palette text is composited and snapped.
/// Preview and packed bytes originate from the same final device-code buffer.
Future<ProcessedArtwork> processArtwork(ComposerDraft draft) async {
  ui.Image? photo;
  ui.Image? processedBase;
  try {
    if (draft.kind == CompositionKind.photo && draft.photoBytes != null) {
      photo = await decodePhoto(draft.photoBytes!);
    }
    final baseRgba = await _render(
      (canvas) => PaperArtPainter(
        draft,
        photo: photo,
        drawText: false,
      ).paint(canvas, const Size(768, 552)),
    );
    final rect = photoContentRect(draft);
    final baseArgs = <String, Object>{
      'rgba': baseRgba,
      'filterImage': draft.kind == CompositionKind.photo && photo != null,
      'options': filterOptions(draft.adjustments),
      // Only the image-content rectangle enters levels/dithering. Padding stays white.
      'left': rect.left.ceil(), 'top': rect.top.ceil(),
      'right': rect.right.floor(), 'bottom': rect.bottom.floor(),
    };
    if (!draft.textEnabled ||
        draft.textLayers.every((t) => t.text.trim().isEmpty)) {
      final converted = await compute(quantizeArtwork, baseArgs);
      return ProcessedArtwork(converted['packed']!, converted['png']!);
    }
    final paletteRgba = await compute(quantizeArtworkBase, baseArgs);
    processedBase = await _imageFromRgba(paletteRgba);
    final finalRgba = await _render((canvas) {
      canvas.drawImage(processedBase!, Offset.zero, Paint());
      PaperArtPainter(
        draft,
        drawBase: false,
      ).paint(canvas, const Size(768, 552));
    });
    final converted = await compute(quantizeArtwork, <String, Object>{
      'rgba': finalRgba,
      'filterImage': false,
    });
    return ProcessedArtwork(converted['packed']!, converted['png']!);
  } finally {
    photo?.dispose();
    processedBase?.dispose();
  }
}

Uint8List _codesFromRgba(Map<String, Object> args) {
  final width = args['width'] as int? ?? frameWidth;
  final height = args['height'] as int? ?? frameHeight;
  final rgba = args['rgba']! as Uint8List;
  if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
    throw ArgumentError('RGBA 尺寸错误');
  }
  final codes = Uint8List(width * height);
  for (var i = 0; i < codes.length; i++) {
    codes[i] = snapPalette(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]);
  }
  if (args['filterImage'] != true) return codes;
  final left = args['left'] as int? ?? 0, top = args['top'] as int? ?? 0;
  final right = args['right'] as int? ?? width,
      bottom = args['bottom'] as int? ?? height;
  if (left < 0 ||
      top < 0 ||
      right > width ||
      bottom > height ||
      right <= left ||
      bottom <= top) {
    throw ArgumentError('图片处理区域超出画布');
  }
  final w = right - left, h = bottom - top;
  final rgb = Float64List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final source = ((top + y) * width + left + x) * 4,
          target = (y * w + x) * 3;
      for (var c = 0; c < 3; c++) {
        rgb[target + c] = rgba[source + c].toDouble();
      }
    }
  }
  final options =
      args['options'] as Map<String, Object>? ?? const <String, Object>{};
  final pixels = quantize(warmMap(rgb, w, h, options), w, h, options);
  for (var y = 0; y < h; y++) {
    codes.setRange(
      (top + y) * width + left,
      (top + y) * width + right,
      pixels,
      y * w,
    );
  }
  return codes;
}

Uint8List _rgbaFromCodes(Uint8List codes) {
  final rgba = Uint8List(codes.length * 4);
  for (var i = 0; i < codes.length; i++) {
    final p = devicePalette[codes[i]], o = i * 4;
    rgba[o] = p[0];
    rgba[o + 1] = p[1];
    rgba[o + 2] = p[2];
    rgba[o + 3] = 255;
  }
  return rgba;
}

/// Isolate entry point: style and quantize the photo before text is drawn.
Uint8List quantizeArtworkBase(Map<String, Object> args) =>
    _rgbaFromCodes(_codesFromRgba(args));

Map<String, Uint8List> quantizeArtwork(Map<String, Object> args) {
  final width = args['width'] as int? ?? frameWidth;
  final height = args['height'] as int? ?? frameHeight;
  final codes = _codesFromRgba(args);
  return {
    'packed': pack2bpp(codes, width: width, height: height),
    'png': _codesToPng(codes, width, height),
  };
}

Uint8List _codesToPng(Uint8List codes, int width, int height) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: _rgbaFromCodes(codes).buffer,
    numChannels: 4,
  );
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List packedToPng(Uint8List packed, int width, int height) => _codesToPng(
  unpack2bpp(packed, width: width, height: height),
  width,
  height,
);

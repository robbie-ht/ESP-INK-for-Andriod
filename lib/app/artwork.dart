import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'models.dart';
import 'photo_geometry.dart';

/// Exact device palette; decorative UI colors are intentionally separate.
const artPalette = [
  Color(0xFF000000),
  Color(0xFFFFFFFF),
  Color(0xFFFFFF00),
  Color(0xFFFF0000),
];

String textFontFamily(TextFont font) => switch (font) {
  TextFont.sans => 'NotoSansSC',
  TextFont.serif => 'NotoSerifSC',
  TextFont.mono => 'NotoSansMonoSC',
};

TextPainter textLayerPainter(TextLayer layer, {bool outline = false}) {
  final foreground = outline
      ? (Paint()
          ..color = artPalette[layer.strokeColor.clamp(0, 3)]
          ..style = PaintingStyle.stroke
          ..strokeWidth = layer.stroke * 2
          ..strokeJoin = StrokeJoin.round)
      : null;
  return TextPainter(
    text: TextSpan(
      text: layer.text,
      style: TextStyle(
        fontFamily: textFontFamily(layer.font),
        fontSize: layer.size.clamp(6, 240),
        fontWeight: layer.bold ? FontWeight.w700 : FontWeight.w500,
        height: 1.35,
        color: outline ? null : artPalette[layer.color.clamp(0, 3)],
        foreground: foreground,
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
  )..layout(maxWidth: layer.wrap.clamp(24, 768));
}

/// Local unrotated bounds, centered at (0, 0), shared by paint and hit testing.
Rect textLayerBounds(TextLayer layer) {
  final p = textLayerPainter(layer);
  final rect = Rect.fromCenter(
    center: Offset.zero,
    width: math.max(24, p.width + layer.size * .56),
    height: math.max(24, p.height + layer.size * .36),
  );
  p.dispose();
  return rect;
}

Rect photoContentRect(ComposerDraft draft) {
  if (!draft.paddingEnabled) return const Rect.fromLTWH(0, 0, 768, 552);
  final left = draft.padLeft.clamp(0.0, 300.0);
  final top = draft.padTop.clamp(0.0, 246.0);
  final right = draft.padRight.clamp(0.0, 300.0);
  final bottom = draft.padBottom.clamp(0.0, 246.0);
  return Rect.fromLTWH(
    left,
    top,
    math.max(60, 768 - left - right),
    math.max(60, 552 - top - bottom),
  );
}

/// Logical editing coordinates are horizontal 768×552. Wire packing stays outside.
/// The image processor quantizes drawText:false first, then overlays drawBase:false
/// and snaps the composed frame to the four pure palette colors.
class PaperArtPainter extends CustomPainter {
  const PaperArtPainter(
    this.draft, {
    this.photo,
    this.drawBase = true,
    this.drawText = true,
  });
  final ComposerDraft draft;
  final ui.Image? photo;
  final bool drawBase, drawText;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 768, size.height / 552);
    canvas.clipRect(const Rect.fromLTWH(0, 0, 768, 552));
    if (drawBase) {
      canvas.drawColor(
        draft.kind == CompositionKind.note
            ? artPalette[draft.background.clamp(0, 3)]
            : Colors.white,
        BlendMode.src,
      );
      if (draft.kind == CompositionKind.photo && photo != null) {
        _photo(canvas, photo!);
      }
    }
    if (drawText && draft.textEnabled) {
      for (final layer in draft.textLayers) {
        if (layer.text.trim().isEmpty) continue;
        canvas.save();
        canvas.translate(layer.x, layer.y);
        canvas.rotate(layer.rotation * math.pi / 180);
        final bounds = textLayerBounds(layer);
        if (layer.background != null) {
          canvas.drawRect(
            bounds,
            Paint()..color = artPalette[layer.background!.clamp(0, 3)],
          );
        }
        final text = textLayerPainter(layer);
        final position = Offset(-text.width / 2, -text.height / 2);
        if (layer.stroke > 0) {
          final outline = textLayerPainter(layer, outline: true);
          outline.paint(canvas, position);
          outline.dispose();
        }
        text.paint(canvas, position);
        text.dispose();
        canvas.restore();
      }
    }
    canvas.restore();
  }

  void _photo(Canvas canvas, ui.Image image) {
    paintPhotoGeometry(
      canvas,
      image,
      resolvePhotoGeometry(
        draft: draft,
        imageSize: Size(image.width.toDouble(), image.height.toDouble()),
        targetRect: photoContentRect(draft),
      ),
    );
  }

  @override
  bool shouldRepaint(PaperArtPainter old) =>
      old.draft != draft ||
      old.photo != photo ||
      old.drawBase != drawBase ||
      old.drawText != drawText;
}

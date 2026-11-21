import 'dart:math' as math;
import 'dart:ui' as ui;

import 'models.dart';

const photoMinZoom = 1.0;
const photoMaxZoom = 8.0;

/// A single image-to-canvas transform, shared by editing and final rendering.
/// [scale] is canvas pixels per source pixel; [radians] rotates clockwise.
class PhotoGeometry {
  const PhotoGeometry._({
    required this.imageSize,
    required this.targetRect,
    required this.center,
    required this.scale,
    required this.radians,
    required this.mirror,
  });

  final ui.Size imageSize;
  final ui.Rect targetRect;
  final ui.Offset center;
  final double scale;
  final double radians;
  final bool mirror;

  ui.Offset imageToViewport(ui.Offset point) {
    var local = point - imageSize.center(ui.Offset.zero);
    if (mirror) local = ui.Offset(-local.dx, local.dy);
    return center + _rotate(local * scale, radians);
  }

  ui.Offset viewportToImage(ui.Offset point) {
    var local = _rotate(point - center, -radians) / scale;
    if (mirror) local = ui.Offset(-local.dx, local.dy);
    return imageSize.center(ui.Offset.zero) + local;
  }

  List<ui.Offset> get imageCorners => [
    imageToViewport(ui.Offset.zero),
    imageToViewport(ui.Offset(imageSize.width, 0)),
    imageToViewport(ui.Offset(imageSize.width, imageSize.height)),
    imageToViewport(ui.Offset(0, imageSize.height)),
  ];
}

/// Offsets retain the existing draft units: half of the target width/height.
/// They are deliberately not limited to ±1: zoomed photos must reach every edge.
PhotoGeometry resolvePhotoGeometry({
  required ComposerDraft draft,
  required ui.Size imageSize,
  required ui.Rect targetRect,
}) {
  _validateSize(imageSize, 'imageSize');
  _validateRect(targetRect, 'targetRect');
  final angle = _angle(draft);
  final scale =
      _baseScale(draft.fit, imageSize, targetRect.size, angle) *
      _zoom(draft.zoom);
  final requestedCenter =
      targetRect.center +
      ui.Offset(
        _finite(draft.offsetX).clamp(-1e6, 1e6) * targetRect.width / 2,
        _finite(draft.offsetY).clamp(-1e6, 1e6) * targetRect.height / 2,
      );
  return PhotoGeometry._(
    imageSize: imageSize,
    targetRect: targetRect,
    center: _clampCenter(
      requestedCenter,
      imageSize,
      targetRect,
      angle,
      scale,
      draft.fit,
    ),
    scale: scale,
    radians: angle,
    mirror: draft.mirror,
  );
}

ComposerDraft normalizePhotoDraft({
  required ComposerDraft draft,
  required ui.Size imageSize,
  required ui.Rect targetRect,
}) {
  final geometry = resolvePhotoGeometry(
    draft: draft,
    imageSize: imageSize,
    targetRect: targetRect,
  );
  return draft.copyWith(
    quarterTurns: draft.quarterTurns % 4,
    rotation: _degrees(_finite(draft.rotation)),
    zoom: _zoom(draft.zoom),
    offsetX: (geometry.center.dx - targetRect.center.dx) * 2 / targetRect.width,
    offsetY:
        (geometry.center.dy - targetRect.center.dy) * 2 / targetRect.height,
  );
}

/// Apply a gesture relative to its initial draft, without accumulating deltas.
/// [anchor] is the initial focal point and [focalPoint] its current position.
/// Coordinates use the same canvas as [targetRect]; rotation is in radians.
/// The source pixel below the anchor stays under the moving focal point until
/// an image boundary or the minimum-cover/maximum-zoom constraint is reached.
ComposerDraft transformPhotoDraft({
  required ComposerDraft draft,
  required ui.Size imageSize,
  required ui.Rect targetRect,
  required ui.Offset anchor,
  required ui.Offset focalPoint,
  double scaleFactor = 1,
  double rotationDelta = 0,
}) {
  _validatePoint(anchor, 'anchor');
  _validatePoint(focalPoint, 'focalPoint');
  final old = resolvePhotoGeometry(
    draft: draft,
    imageSize: imageSize,
    targetRect: targetRect,
  );
  final rotation = _degrees(
    _finite(draft.rotation) + _finite(rotationDelta) * 180 / math.pi,
  );
  final rotated = draft.copyWith(rotation: rotation);
  final angle = _angle(rotated);
  final desiredScale =
      old.scale * (scaleFactor.isFinite && scaleFactor > 0 ? scaleFactor : 1);
  final zoom = _zoom(
    desiredScale / _baseScale(draft.fit, imageSize, targetRect.size, angle),
  );
  final scale = _baseScale(draft.fit, imageSize, targetRect.size, angle) * zoom;
  var local = old.viewportToImage(anchor) - imageSize.center(ui.Offset.zero);
  if (draft.mirror) local = ui.Offset(-local.dx, local.dy);
  final center = focalPoint - _rotate(local * scale, angle);
  return normalizePhotoDraft(
    draft: rotated.copyWith(
      zoom: zoom,
      offsetX: (center.dx - targetRect.center.dx) * 2 / targetRect.width,
      offsetY: (center.dy - targetRect.center.dy) * 2 / targetRect.height,
    ),
    imageSize: imageSize,
    targetRect: targetRect,
  );
}

/// Re-express a crop in a resized/moved fixed-aspect viewport while keeping the
/// photograph stationary on the canvas. Use this for corner crop handles.
/// On acceptance the resulting draft can be drawn in any equally shaped rect,
/// including the full device content rect, without further coordinate changes.
ComposerDraft resizePhotoCrop({
  required ComposerDraft draft,
  required ui.Size imageSize,
  required ui.Rect oldRect,
  required ui.Rect newRect,
}) {
  _validateRect(oldRect, 'oldRect');
  _validateRect(newRect, 'newRect');
  if ((oldRect.width / oldRect.height - newRect.width / newRect.height).abs() >
      oldRect.width / oldRect.height * 1e-5) {
    throw ArgumentError(
      'Photo crop rectangles must retain the output aspect ratio',
    );
  }
  final old = resolvePhotoGeometry(
    draft: draft,
    imageSize: imageSize,
    targetRect: oldRect,
  );
  return normalizePhotoDraft(
    draft: draft.copyWith(
      zoom:
          old.scale /
          _baseScale(draft.fit, imageSize, newRect.size, old.radians),
      offsetX: (old.center.dx - newRect.center.dx) * 2 / newRect.width,
      offsetY: (old.center.dy - newRect.center.dy) * 2 / newRect.height,
    ),
    imageSize: imageSize,
    targetRect: newRect,
  );
}

/// Select [cropRect] in the currently displayed [targetRect], then expand that
/// selection to the full output. Crop and output must have the same aspect ratio.
ComposerDraft reframePhotoDraft({
  required ComposerDraft draft,
  required ui.Size imageSize,
  required ui.Rect targetRect,
  required ui.Rect cropRect,
}) => resizePhotoCrop(
  draft: draft,
  imageSize: imageSize,
  oldRect: targetRect,
  newRect: cropRect,
);

/// [clip] may be disabled by an editor to reveal the image outside the crop.
void paintPhotoGeometry(
  ui.Canvas canvas,
  ui.Image image,
  PhotoGeometry geometry, {
  bool clip = true,
  ui.FilterQuality filterQuality = ui.FilterQuality.high,
}) {
  canvas.save();
  if (clip) canvas.clipRect(geometry.targetRect);
  canvas.translate(geometry.center.dx, geometry.center.dy);
  canvas.rotate(geometry.radians);
  if (geometry.mirror) canvas.scale(-1, 1);
  canvas.drawImageRect(
    image,
    ui.Offset.zero & geometry.imageSize,
    ui.Rect.fromCenter(
      center: ui.Offset.zero,
      width: geometry.imageSize.width * geometry.scale,
      height: geometry.imageSize.height * geometry.scale,
    ),
    ui.Paint()..filterQuality = filterQuality,
  );
  canvas.restore();
}

double _baseScale(
  ImageFitMode fit,
  ui.Size image,
  ui.Size target,
  double angle,
) {
  final c = math.cos(angle).abs(), s = math.sin(angle).abs();
  if (fit == ImageFitMode.cover) {
    // Project target corners into the rotated photo axes. A rotated bounding
    // box alone would under-fill diagonal corners and expose blank triangles.
    return math.max(
      (c * target.width + s * target.height) / image.width,
      (s * target.width + c * target.height) / image.height,
    );
  }
  return math.min(
    target.width / (c * image.width + s * image.height),
    target.height / (s * image.width + c * image.height),
  );
}

ui.Offset _clampCenter(
  ui.Offset center,
  ui.Size image,
  ui.Rect target,
  double angle,
  double scale,
  ImageFitMode fit,
) {
  final c = math.cos(angle).abs(), s = math.sin(angle).abs();
  if (fit == ImageFitMode.cover) {
    final local = _rotate(center - target.center, -angle);
    final maxX = math.max(
      0.0,
      (image.width * scale - c * target.width - s * target.height) / 2,
    );
    final maxY = math.max(
      0.0,
      (image.height * scale - s * target.width - c * target.height) / 2,
    );
    return target.center +
        _rotate(
          ui.Offset(local.dx.clamp(-maxX, maxX), local.dy.clamp(-maxY, maxY)),
          angle,
        );
  }
  // At 1×, keep the whole rotated photo inside its deliberate white margins.
  // Once enlarged, allow panning to its edges while keeping it on screen.
  final maxX =
      (scale * (c * image.width + s * image.height) - target.width).abs() / 2;
  final maxY =
      (scale * (s * image.width + c * image.height) - target.height).abs() / 2;
  return target.center +
      ui.Offset(
        (center.dx - target.center.dx).clamp(-maxX, maxX),
        (center.dy - target.center.dy).clamp(-maxY, maxY),
      );
}

ui.Offset _rotate(ui.Offset p, double a) => ui.Offset(
  p.dx * math.cos(a) - p.dy * math.sin(a),
  p.dx * math.sin(a) + p.dy * math.cos(a),
);

double _finite(double value) => value.isFinite ? value : 0;
double _zoom(double value) =>
    value.isFinite ? value.clamp(photoMinZoom, photoMaxZoom) : photoMinZoom;
double _degrees(double angle) => (angle + 180) % 360 - 180;
double _angle(ComposerDraft draft) =>
    _degrees(draft.quarterTurns % 4 * 90 + _finite(draft.rotation)) *
    math.pi /
    180;

void _validateSize(ui.Size size, String name) {
  if (!size.width.isFinite || !size.height.isFinite || size.isEmpty) {
    throw ArgumentError.value(size, name, 'Must be finite and positive');
  }
}

void _validateRect(ui.Rect rect, String name) {
  if (!rect.isFinite || rect.isEmpty) {
    throw ArgumentError.value(rect, name, 'Must be finite and positive');
  }
}

void _validatePoint(ui.Offset point, String name) {
  if (!point.dx.isFinite || !point.dy.isFinite) {
    throw ArgumentError.value(point, name, 'Must be finite');
  }
}

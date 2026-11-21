import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:moink_app/app/artwork.dart';
import 'package:moink_app/app/models.dart';
import 'package:moink_app/app/photo_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const target = ui.Rect.fromLTWH(40, 70, 384, 276);
  const imageSize = ui.Size(1600, 1200);
  const epsilon = 1e-7;

  void expectPoint(ui.Offset actual, ui.Offset expected) {
    expect(actual.dx, closeTo(expected.dx, epsilon));
    expect(actual.dy, closeTo(expected.dy, epsilon));
  }

  test('cover encloses every corner for all orientations and large pans', () {
    for (final size in [
      imageSize,
      const ui.Size(200, 1600),
      const ui.Size(3000, 100),
    ]) {
      for (final angle in [
        -179.0,
        -135.0,
        -90.0,
        -33.0,
        0.0,
        17.0,
        45.0,
        90.0,
        179.0,
      ]) {
        for (final zoom in [1.0, 1.4, 8.0]) {
          for (final offset in [
            ui.Offset.zero,
            const ui.Offset(99, -99),
            const ui.Offset(-99, 99),
          ]) {
            final geometry = resolvePhotoGeometry(
              draft: ComposerDraft(
                rotation: angle,
                zoom: zoom,
                offsetX: offset.dx,
                offsetY: offset.dy,
              ),
              imageSize: size,
              targetRect: target,
            );
            for (final corner in [
              target.topLeft,
              target.topRight,
              target.bottomLeft,
              target.bottomRight,
            ]) {
              final p = geometry.viewportToImage(corner);
              expect(
                p.dx,
                inInclusiveRange(-epsilon, size.width + epsilon),
                reason: '$size, $angle°, $zoom×',
              );
              expect(
                p.dy,
                inInclusiveRange(-epsilon, size.height + epsilon),
                reason: '$size, $angle°, $zoom×',
              );
            }
          }
        }
      }
    }
  });

  test(
    'contain shows the whole original at every angle including pan limits',
    () {
      for (final angle in [-135.0, -90.0, -17.0, 0.0, 31.0, 90.0, 179.0]) {
        for (final size in [imageSize, const ui.Size(200, 1600)]) {
          final geometry = resolvePhotoGeometry(
            draft: ComposerDraft(
              fit: ImageFitMode.contain,
              rotation: angle,
              offsetX: 99,
              offsetY: -99,
            ),
            imageSize: size,
            targetRect: target,
          );
          for (final corner in geometry.imageCorners) {
            expect(
              corner.dx,
              inInclusiveRange(target.left - epsilon, target.right + epsilon),
            );
            expect(
              corner.dy,
              inInclusiveRange(target.top - epsilon, target.bottom + epsilon),
            );
          }
        }
      }
    },
  );

  test('inverse transform retains exact source pixel even after mirroring', () {
    for (final mirror in [false, true]) {
      final geometry = resolvePhotoGeometry(
        draft: ComposerDraft(
          quarterTurns: 3,
          rotation: 13,
          zoom: 2.7,
          offsetX: .7,
          offsetY: -.6,
          mirror: mirror,
        ),
        imageSize: imageSize,
        targetRect: target,
      );
      for (final point in [
        ui.Offset.zero,
        const ui.Offset(700, 200),
        const ui.Offset(1600, 1200),
      ]) {
        expectPoint(
          geometry.viewportToImage(geometry.imageToViewport(point)),
          point,
        );
      }
    }
  });

  test(
    'pinch, pan and rotation preserve the source pixel below the focal point',
    () {
      for (final mirror in [false, true]) {
        final draft = ComposerDraft(zoom: 2, rotation: 7, mirror: mirror);
        const anchor = ui.Offset(230, 195), focus = ui.Offset(246, 210);
        final old = resolvePhotoGeometry(
          draft: draft,
          imageSize: imageSize,
          targetRect: target,
        );
        final changed = transformPhotoDraft(
          draft: draft,
          imageSize: imageSize,
          targetRect: target,
          anchor: anchor,
          focalPoint: focus,
          scaleFactor: 1.2,
          rotationDelta: .12,
        );
        final current = resolvePhotoGeometry(
          draft: changed,
          imageSize: imageSize,
          targetRect: target,
        );
        expectPoint(
          current.viewportToImage(focus),
          old.viewportToImage(anchor),
        );
        expect(current.scale, closeTo(old.scale * 1.2, epsilon));
      }
    },
  );

  test(
    'normalization is idempotent and permits reaching a zoomed photo edge',
    () {
      const draft = ComposerDraft(
        zoom: 8,
        offsetX: 90,
        offsetY: -90,
        rotation: 405,
        quarterTurns: -1,
      );
      final normal = normalizePhotoDraft(
        draft: draft,
        imageSize: imageSize,
        targetRect: target,
      );
      final again = normalizePhotoDraft(
        draft: normal,
        imageSize: imageSize,
        targetRect: target,
      );
      expect(normal.zoom, 8);
      expect(normal.rotation, 45);
      expect(normal.quarterTurns, 3);
      expect(normal.offsetX.abs(), greaterThan(1));
      expect(normal.offsetY.abs(), greaterThan(1));
      expectPoint(
        ui.Offset(again.offsetX, again.offsetY),
        ui.Offset(normal.offsetX, normal.offsetY),
      );
      final restored = ComposerDraft.fromJson(
        jsonDecode(jsonEncode(normal.toJson())) as Map<String, dynamic>,
      );
      expect(restored.zoom, normal.zoom);
      expect(restored.offsetX, normal.offsetX);
      expect(restored.offsetY, normal.offsetY);
    },
  );

  test(
    'corner crop preserves image on stage then expands the selected region',
    () {
      const draft = ComposerDraft(zoom: 1.4, rotation: 13, mirror: true);
      final crop = ui.Rect.fromLTWH(
        target.left + 20,
        target.top + 10,
        target.width * .7,
        target.height * .7,
      );
      final old = resolvePhotoGeometry(
        draft: draft,
        imageSize: imageSize,
        targetRect: target,
      );
      final changed = resizePhotoCrop(
        draft: draft,
        imageSize: imageSize,
        oldRect: target,
        newRect: crop,
      );
      final stationary = resolvePhotoGeometry(
        draft: changed,
        imageSize: imageSize,
        targetRect: crop,
      );
      expectPoint(stationary.center, old.center);
      expect(stationary.scale, closeTo(old.scale, epsilon));
      final finalFrame = resolvePhotoGeometry(
        draft: changed,
        imageSize: imageSize,
        targetRect: target,
      );
      for (final pair in [
        (crop.topLeft, target.topLeft),
        (crop.topRight, target.topRight),
        (crop.bottomLeft, target.bottomLeft),
        (crop.bottomRight, target.bottomRight),
      ]) {
        expectPoint(
          finalFrame.viewportToImage(pair.$2),
          old.viewportToImage(pair.$1),
        );
      }
      final reframed = reframePhotoDraft(
        draft: draft,
        imageSize: imageSize,
        targetRect: target,
        cropRect: crop,
      );
      expect(reframed.zoom, changed.zoom);
      expectPoint(
        ui.Offset(reframed.offsetX, reframed.offsetY),
        ui.Offset(changed.offsetX, changed.offsetY),
      );
    },
  );

  test('scaled editor viewport and final output resolve the same photo coordinates', () {
    const draft = ComposerDraft(
      quarterTurns: 1,
      rotation: -12,
      zoom: 3,
      offsetX: 1.2,
      offsetY: -.7,
      mirror: true,
    );
    final editor = resolvePhotoGeometry(
      draft: draft,
      imageSize: imageSize,
      targetRect: target,
    );
    const output = ui.Rect.fromLTWH(0, 0, 768, 552);
    final finalFrame = resolvePhotoGeometry(
      draft: draft,
      imageSize: imageSize,
      targetRect: output,
    );
    for (final normalized in [
      ui.Offset.zero,
      const ui.Offset(.25, .75),
      const ui.Offset(1, 1),
    ]) {
      expectPoint(
        editor.viewportToImage(
          target.topLeft +
              ui.Offset(
                normalized.dx * target.width,
                normalized.dy * target.height,
              ),
        ),
        finalFrame.viewportToImage(
          ui.Offset(
            normalized.dx * output.width,
            normalized.dy * output.height,
          ),
        ),
      );
    }
  });

  test('invalid persisted transforms recover while invalid image sizes fail clearly', () {
    final normal = normalizePhotoDraft(
      draft: const ComposerDraft(
        zoom: double.nan,
        rotation: double.infinity,
        offsetX: double.nan,
        offsetY: double.negativeInfinity,
      ),
      imageSize: imageSize,
      targetRect: target,
    );
    expect(normal.zoom, 1);
    expect(normal.rotation, 0);
    expect(normal.offsetX.isFinite && normal.offsetY.isFinite, isTrue);
    final extreme = normalizePhotoDraft(
      draft: const ComposerDraft(zoom: 8, offsetX: 1e308, offsetY: -1e308),
      imageSize: imageSize,
      targetRect: target,
    );
    expect(extreme.offsetX.isFinite && extreme.offsetY.isFinite, isTrue);
    expect(
      () => resolvePhotoGeometry(
        draft: const ComposerDraft(),
        imageSize: ui.Size.zero,
        targetRect: target,
      ),
      throwsArgumentError,
    );
    expect(
      () => resizePhotoCrop(
        draft: const ComposerDraft(),
        imageSize: imageSize,
        oldRect: target,
        newRect: const ui.Rect.fromLTWH(0, 0, 50, 50),
      ),
      throwsArgumentError,
    );
  });

  Future<ui.Image> sourceImage() async {
    final recorder = ui.PictureRecorder();
    // The actual recorded canvas below uses four distinct opaque source areas.
    final sourceCanvas = ui.Canvas(recorder);
    sourceCanvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 80, 60),
      ui.Paint()..color = const ui.Color(0xFF0077CC),
    );
    sourceCanvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 40, 30),
      ui.Paint()..color = const ui.Color(0xFFFF3300),
    );
    sourceCanvas.drawRect(
      const ui.Rect.fromLTWH(40, 30, 40, 30),
      ui.Paint()..color = const ui.Color(0xFF33AA00),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(80, 60);
    picture.dispose();
    return image;
  }

  Future<Uint8List> render(
    ui.Image photo,
    ComposerDraft draft,
    bool finalPainter,
  ) async {
    final recorder = ui.PictureRecorder(), canvas = ui.Canvas(recorder);
    if (finalPainter) {
      PaperArtPainter(
        draft,
        photo: photo,
        drawText: false,
      ).paint(canvas, const ui.Size(768, 552));
    } else {
      canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
      paintPhotoGeometry(
        canvas,
        photo,
        resolvePhotoGeometry(
          draft: draft,
          imageSize: const ui.Size(80, 60),
          targetRect: photoContentRect(draft),
        ),
      );
    }
    final picture = recorder.endRecording(),
        output = await picture.toImage(768, 552);
    final bytes = (await output.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
    output.dispose();
    picture.dispose();
    return bytes;
  }

  test('real raster painter exactly matches final artwork with rotation, mirror and padding', () async {
    final photo = await sourceImage();
    const draft = ComposerDraft(
      zoom: 2.3,
      quarterTurns: 1,
      rotation: 21,
      mirror: true,
      offsetX: .7,
      offsetY: -.4,
      paddingEnabled: true,
    );
    final editorPixels = await render(photo, draft, false),
        outputPixels = await render(photo, draft, true);
    expect(editorPixels, outputPixels);
    photo.dispose();
  });

  test(
    'rotated cover never rasterizes a transparent hole inside crop',
    () async {
      final photo = await sourceImage();
      for (final angle in [17.0, 45.0, 89.0, 135.0]) {
        final bytes = await render(
          photo,
          ComposerDraft(rotation: angle, zoom: 1, offsetX: 50, offsetY: -50),
          true,
        );
        for (var y = 2; y < 550; y += 7) {
          for (var x = 2; x < 766; x += 7) {
            final i = (y * 768 + x) * 4;
            expect(bytes[i + 3], 255);
            expect(
              bytes.sublist(i, i + 3),
              isNot([255, 255, 255]),
              reason: 'White gap at $x,$y / $angle°',
            );
          }
        }
      }
      photo.dispose();
    },
  );
}

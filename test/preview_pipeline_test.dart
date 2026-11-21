import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/app/image_processor.dart';
import 'package:esp_ink/app/models.dart';
import 'package:esp_ink/core/frame_codec.dart';

class _RenderRequest {
  _RenderRequest(this.draft);

  final ComposerDraft draft;
  final result = Completer<ProcessedArtwork>();
}

/// Each result is released by the test, independently of editing and UI time.
class _ControlledProcessor {
  final requests = <_RenderRequest>[];

  Future<ProcessedArtwork> call(ComposerDraft draft) {
    final request = _RenderRequest(draft);
    requests.add(request);
    return request.result.future;
  }
}

ProcessedArtwork _artwork(int paletteCode) {
  final pixel = img.Image(width: 1, height: 1)
    ..setPixelRgba(0, 0, paletteCode * 60, 20, 255, 255);
  return ProcessedArtwork(
    solidFrame(color: paletteCode),
    Uint8List.fromList(img.encodePng(pixel)),
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  late _ControlledProcessor processor;
  late EspInkController controller;

  setUp(() {
    processor = _ControlledProcessor();
    controller = EspInkController(artworkProcessor: processor.call);
  });

  tearDown(() => controller.dispose());

  testWidgets('continuous edits never start dot conversion or block editing', (
    tester,
  ) async {
    for (var i = 0; i < 40; i++) {
      controller.updateDraft(
        controller.draft.copyWith(zoom: 1 + i / 20, rotation: i / 2),
      );
    }
    await tester.pump(const Duration(seconds: 2));

    expect(processor.requests, isEmpty);
    expect(controller.draft.zoom, 2.95);
    expect(controller.draft.rotation, 19.5);
    expect(controller.rendering, isFalse);
    expect(controller.previewReady, isFalse);
  });

  testWidgets(
    'a late conversion is discarded without automatically rendering edits',
    (tester) async {
      final original = controller.draft.copyWith(rotation: 12);
      controller.updateDraft(original);
      final pending = controller.renderPreview();
      await _flush(tester);
      expect(processor.requests, hasLength(1));
      expect(processor.requests.single.draft, same(original));
      expect(controller.rendering, isTrue);

      final edited = original.copyWith(zoom: 2.5, rotation: -15);
      controller.updateDraft(edited);
      processor.requests.single.result.complete(_artwork(0));
      await _flush(tester);
      await pending;
      await tester.pump(const Duration(seconds: 2));

      expect(controller.draft, same(edited));
      expect(controller.previewPng, isNull);
      expect(controller.previewReady, isFalse);
      expect(controller.rendering, isFalse);
      expect(processor.requests, hasLength(1));
    },
  );

  testWidgets(
    'concurrent explicit requests for the same edit share one conversion',
    (tester) async {
      controller.updateDraft(const ComposerDraft(kind: CompositionKind.note));
      final pending = [
        controller.renderPreview(),
        controller.renderPreview(),
        controller.renderPreview(),
      ];
      await _flush(tester);
      expect(processor.requests, hasLength(1));

      final rendered = _artwork(2);
      processor.requests.single.result.complete(rendered);
      await _flush(tester);
      await Future.wait(pending);

      expect(processor.requests, hasLength(1));
      expect(controller.previewPng, orderedEquals(rendered.png));
      expect(controller.previewReady, isTrue);
      expect(controller.rendering, isFalse);

      controller.updateDraft(controller.draft.copyWith(background: 0));
      expect(controller.previewReady, isFalse);
      expect(controller.rendering, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(processor.requests, hasLength(1));
    },
  );

  testWidgets('explicit newer requests merge into the latest requested edit', (
    tester,
  ) async {
    controller.updateDraft(const ComposerDraft(rotation: 4));
    final pending = <Future<void>>[controller.renderPreview()];
    await _flush(tester);
    expect(processor.requests, hasLength(1));

    controller.updateDraft(controller.draft.copyWith(rotation: 8));
    pending.add(controller.renderPreview());
    pending.add(controller.renderPreview());
    final latest = controller.draft.copyWith(rotation: 17, zoom: 2);
    controller.updateDraft(latest);
    pending.add(controller.renderPreview());
    pending.add(controller.renderPreview());
    expect(processor.requests, hasLength(1));

    processor.requests.first.result.complete(_artwork(0));
    await _flush(tester);
    expect(processor.requests, hasLength(2));
    expect(processor.requests.last.draft, same(latest));
    expect(controller.previewReady, isFalse);
    expect(controller.previewPng, isNull);

    final rendered = _artwork(3);
    processor.requests.last.result.complete(rendered);
    await _flush(tester);
    await Future.wait(pending);

    expect(processor.requests, hasLength(2));
    expect(controller.previewPng, orderedEquals(rendered.png));
    expect(controller.previewReady, isTrue);
    expect(controller.rendering, isFalse);
  });

  testWidgets(
    'editing during demo send cannot change its saved picture or title',
    (tester) async {
      final sentArtwork = _artwork(3);
      final photo = ComposerDraft(photoBytes: sentArtwork.png, rotation: 11);
      controller
        ..demo = true
        ..gallerySupported = true;
      controller.updateDraft(photo);

      final sending = controller.send(saveGallery: true);
      await _flush(tester);
      expect(processor.requests, hasLength(1));
      expect(processor.requests.single.draft, same(photo));
      expect(controller.busy, isTrue);

      controller.updateDraft(
        const ComposerDraft(kind: CompositionKind.note, background: 2),
      );
      processor.requests.single.result.complete(sentArtwork);
      await _flush(tester);
      // The demo has accepted the generated frame but has not completed its send.
      expect(controller.busy, isTrue);
      controller.updateDraft(
        controller.draft.copyWith(background: 0, rotation: -7),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await sending;

      expect(controller.gallery, hasLength(1));
      expect(controller.gallery.single.title, '我的照片');
      expect(controller.gallery.single.png, orderedEquals(sentArtwork.png));
      expect(controller.gallery.single.current, isTrue);
      expect(controller.draft.kind, CompositionKind.note);
      expect(controller.previewReady, isFalse);
      expect(controller.busy, isFalse);
      expect(processor.requests, hasLength(1));
    },
  );

  testWidgets('ink mode renders immediately then debounces fast adjustments', (
    tester,
  ) async {
    controller.updateDraft(const ComposerDraft(kind: CompositionKind.note));
    controller.setInkPreviewActive(true);
    await _flush(tester);
    expect(processor.requests, hasLength(1));
    final previous = _artwork(0);
    processor.requests.first.result.complete(previous);
    await _flush(tester);
    for (var i = 0; i < 40; i++) {
      controller.updateDraft(controller.draft.copyWith(rotation: i.toDouble()));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(processor.requests, hasLength(1));
    expect(controller.previewPng, same(previous.png));
    expect(controller.previewReady, isFalse);
    await tester.pump(const Duration(milliseconds: 230));
    expect(processor.requests, hasLength(2));
    expect(processor.requests.last.draft.rotation, 39);
    processor.requests.last.result.complete(_artwork(3));
    await _flush(tester);
    expect(controller.previewReady, isTrue);
  });

  testWidgets(
    'slow ink conversion merges edits and discards obsolete results',
    (tester) async {
      controller.setInkPreviewActive(true);
      await _flush(tester);
      for (var i = 1; i <= 4; i++) {
        controller.updateDraft(
          controller.draft.copyWith(rotation: i.toDouble()),
        );
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(processor.requests, hasLength(1));
      final latest = controller.draft;
      processor.requests.first.result.complete(_artwork(0));
      await _flush(tester);
      expect(processor.requests, hasLength(2));
      expect(processor.requests.last.draft, same(latest));
      expect(controller.previewPng, isNull);
      processor.requests.last.result.complete(_artwork(2));
      await _flush(tester);
      expect(controller.previewReady, isTrue);
    },
  );

  testWidgets(
    'leaving ink mode cancels queued edits but caches the active result',
    (tester) async {
      controller.setInkPreviewActive(true);
      await _flush(tester);
      controller.updateDraft(controller.draft.copyWith(rotation: 9));
      await tester.pump(const Duration(milliseconds: 250));
      controller.setInkPreviewActive(false);
      processor.requests.first.result.complete(_artwork(0));
      await _flush(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(processor.requests, hasLength(1));
      expect(controller.previewReady, isFalse);
      controller.setInkPreviewActive(true);
      await _flush(tester);
      expect(processor.requests, hasLength(2));
      final latest = _artwork(2);
      controller.setTab(1);
      processor.requests.last.result.complete(latest);
      await _flush(tester);
      expect(controller.inkPreviewActive, isFalse);
      expect(controller.previewPng, same(latest.png));
      expect(controller.previewReady, isTrue);
    },
  );

  testWidgets(
    'changing the source photo clears only the previous source effect',
    (tester) async {
      final photo = _artwork(0).png;
      controller.updateDraft(ComposerDraft(photoBytes: photo));
      controller.setInkPreviewActive(true);
      await _flush(tester);
      final previous = _artwork(0);
      processor.requests.first.result.complete(previous);
      await _flush(tester);
      controller.updateDraft(controller.draft.copyWith(zoom: 2));
      expect(controller.previewPng, same(previous.png));
      controller.updateDraft(
        controller.draft.copyWith(photoBytes: _artwork(3).png),
      );
      expect(controller.previewPng, isNull);
      controller.setInkPreviewActive(false);
    },
  );

  testWidgets('send reuses the current ink task and its captured snapshot', (
    tester,
  ) async {
    controller
      ..demo = true
      ..gallerySupported = true;
    controller.updateDraft(const ComposerDraft(kind: CompositionKind.note));
    controller.setInkPreviewActive(true);
    await _flush(tester);
    final sending = controller.send(saveGallery: true);
    controller.updateDraft(controller.draft.copyWith(rotation: 17));
    controller.setInkPreviewActive(false);
    final sent = _artwork(2);
    processor.requests.first.result.complete(sent);
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await sending;
    expect(processor.requests, hasLength(1));
    expect(controller.gallery.single.png, same(sent.png));
    expect(controller.previewReady, isFalse);
  });
}

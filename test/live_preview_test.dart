import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/app/artwork.dart';
import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/app/image_processor.dart';
import 'package:esp_ink/app/models.dart';
import 'package:esp_ink/core/frame_codec.dart';
import 'package:esp_ink/main.dart';
import 'package:esp_ink/ui/source_artwork_canvas.dart';

Uint8List _sourcePng() {
  final image = img.Image(width: 8, height: 5);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgba(x, y, x * 30, y * 50, 120, 255);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

ProcessedArtwork _deviceArtwork() {
  final image = img.Image(width: 2, height: 1)
    ..setPixelRgba(0, 0, 255, 255, 0, 255)
    ..setPixelRgba(1, 0, 255, 0, 0, 255);
  return ProcessedArtwork(
    solidFrame(color: 2),
    Uint8List.fromList(img.encodePng(image)),
  );
}

class _ControlledProcessor {
  final drafts = <ComposerDraft>[];
  final results = <Completer<ProcessedArtwork>>[];

  Future<ProcessedArtwork> call(ComposerDraft draft) {
    drafts.add(draft);
    final result = Completer<ProcessedArtwork>();
    results.add(result);
    return result.future;
  }
}

PaperArtPainter _livePainter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byKey(const ValueKey('live-source-paint')),
            )
            .painter!
        as PaperArtPainter;

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

// Engine image decoding finishes outside the widget test's fake timer zone.
// Advance real asynchronous work while pumping only until the requested state
// appears, rather than settling an indefinitely animated loading indicator.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('The source image decoder did not reach the expected UI state: $finder');
}

void main() {
  Future<void> launch(WidgetTester tester, EspInkController controller) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(controller.dispose);
    await tester.pumpWidget(EspInkApp(controller: controller));
    await _waitFor(tester, find.byKey(const ValueKey('live-source-paint')));
    await tester.pumpAndSettle();
    expect(_livePainter(tester).photo, isNotNull);
  }

  testWidgets(
    'pending dot conversion keeps the decoded source photograph visible',
    (tester) async {
      final processor = _ControlledProcessor();
      final controller = EspInkController(artworkProcessor: processor.call);
      controller.updateDraft(ComposerDraft(photoBytes: _sourcePng()));
      // An older device preview must never replace the source while editing.
      controller.previewPng = _deviceArtwork().png;
      await launch(tester, controller);
      expect(processor.drafts, isEmpty);
      expect(find.byKey(const ValueKey('device-preview-image')), findsNothing);

      await tester.tap(find.text('墨水屏效果'));
      await _flush(tester);

      expect(controller.rendering, isTrue);
      expect(processor.drafts, hasLength(1));
      expect(_livePainter(tester).photo, isNotNull);
      expect(find.byKey(const ValueKey('device-preview-image')), findsNothing);
      expect(find.text('正在生成效果，当前仍显示原图'), findsOneWidget);
      expect(
        tester
            .widget<SegmentedButton<bool>>(
              find.byKey(const ValueKey('preview-mode')),
            )
            .selected,
        {true},
      );

      processor.results.single.complete(_deviceArtwork());
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('device-preview-image')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a completed dot result cannot switch the user back from source mode',
    (tester) async {
      final processor = _ControlledProcessor();
      final controller = EspInkController(artworkProcessor: processor.call);
      controller.updateDraft(ComposerDraft(photoBytes: _sourcePng()));
      await launch(tester, controller);
      await tester.tap(find.text('墨水屏效果'));
      await _flush(tester);
      expect(processor.results, hasLength(1));

      await tester.tap(find.text('原图'));
      await _flush(tester);
      expect(controller.rendering, isTrue);
      processor.results.single.complete(_deviceArtwork());
      await _flush(tester);
      await _waitFor(tester, find.byKey(const ValueKey('live-source-paint')));
      await tester.pumpAndSettle();

      expect(controller.previewReady, isTrue);
      expect(_livePainter(tester).photo, isNotNull);
      expect(find.byKey(const ValueKey('device-preview-image')), findsNothing);
      expect(
        tester
            .widget<SegmentedButton<bool>>(
              find.byKey(const ValueKey('preview-mode')),
            )
            .selected,
        {false},
      );
      expect(processor.drafts, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('geometry edits paint immediately and reuse the decoded source', (
    tester,
  ) async {
    final processor = _ControlledProcessor();
    final controller = EspInkController(artworkProcessor: processor.call);
    controller.updateDraft(ComposerDraft(photoBytes: _sourcePng()));
    await launch(tester, controller);
    final decodedPhoto = _livePainter(tester).photo;
    final edited = controller.draft.copyWith(
      zoom: 2.3,
      rotation: 23,
      offsetX: .6,
      offsetY: -.4,
      mirror: true,
    );

    controller.updateDraft(edited);
    await tester.pump();

    expect(_livePainter(tester).draft, same(edited));
    expect(_livePainter(tester).photo, same(decodedPhoto));
    expect(controller.rendering, isFalse);
    expect(processor.drafts, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(processor.drafts, isEmpty);
    expect(find.byKey(const ValueKey('device-preview-image')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'main effect mode refreshes edits and keeps its last result visible',
    (tester) async {
      final processor = _ControlledProcessor();
      final controller = EspInkController(artworkProcessor: processor.call);
      controller.updateDraft(ComposerDraft(photoBytes: _sourcePng()));
      await launch(tester, controller);
      await tester.tap(find.text('墨水屏效果'));
      await _flush(tester);
      processor.results.first.complete(_deviceArtwork());
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('device-preview-image')),
        findsOneWidget,
      );

      controller.updateDraft(
        controller.draft.copyWith(
          adjustments: controller.draft.adjustments.copyWith(brightness: 32),
        ),
      );
      await tester.pump(const Duration(milliseconds: 280));
      await _flush(tester);
      expect(processor.drafts, hasLength(2));
      expect(
        find.byKey(const ValueKey('device-preview-image')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('live-source-paint')), findsNothing);
      expect(find.text('更新预览'), findsNothing);
      processor.results.last.complete(_deviceArtwork());
      await _flush(tester);
      await tester.pumpAndSettle();
      expect(controller.previewReady, isTrue);

      await tester.tap(find.text('原图'));
      controller.updateDraft(controller.draft.copyWith(rotation: 13));
      await tester.pump(const Duration(milliseconds: 500));
      expect(processor.drafts, hasLength(2));
      expect(find.byKey(const ValueKey('device-preview-image')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an invalid replacement removes the old photograph and offers reselect',
    (tester) async {
      final draft = ValueNotifier(ComposerDraft(photoBytes: _sourcePng()));
      addTearDown(draft.dispose);
      var reselects = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 384,
                height: 276,
                child: ValueListenableBuilder<ComposerDraft>(
                  valueListenable: draft,
                  builder: (context, value, _) => SourceArtworkCanvas(
                    draft: value,
                    onReselect: () => reselects++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _waitFor(tester, find.byKey(const ValueKey('live-source-paint')));
      await tester.pumpAndSettle();
      expect(_livePainter(tester).photo, isNotNull);

      draft.value = draft.value.copyWith(
        photoBytes: Uint8List.fromList([0, 1, 2, 3, 4]),
      );
      await tester.pump();
      await _waitFor(tester, find.text('无法读取这张照片，请重新选择'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('live-source-paint')), findsNothing);
      expect(find.text('无法读取这张照片，请重新选择'), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      await tester.tap(find.text('重新选图'));
      expect(reselects, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

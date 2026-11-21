import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/app/image_processor.dart';
import 'package:esp_ink/app/models.dart';
import 'package:esp_ink/core/frame_codec.dart';
import 'package:esp_ink/ui/composer_settings.dart';

Uint8List _png(int level) => Uint8List.fromList(
  img.encodePng(
    img.Image(width: 8, height: 6)..clear(img.ColorRgb8(level, 50, 30)),
  ),
);

void main() {
  Future<void> open(WidgetTester tester, EspInkController c, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showImageSettingsSheet(context, c),
              child: const Text('调整效果'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('调整效果'));
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('effect preview stays visible while controls scroll at $size', (
      tester,
    ) async {
      final c = EspInkController(
        artworkProcessor: (_) async =>
            ProcessedArtwork(solidFrame(color: 1), _png(210)),
      );
      c.updateDraft(ComposerDraft(photoBytes: _png(160)));
      await open(tester, c, size);
      final preview = find.byKey(const ValueKey('ink-effect-fixed-preview'));
      final before = tester.getRect(preview);
      expect(before.top, greaterThanOrEqualTo(0));
      expect(before.bottom, lessThanOrEqualTo(size.height));
      expect(
        find.byKey(
          ValueKey(
            size.width >= 720
                ? 'ink-effect-side-layout'
                : 'ink-effect-stacked-layout',
          ),
        ),
        findsOneWidget,
      );
      final scroll = find
          .descendant(
            of: find.byKey(const PageStorageKey('ink-effect-controls')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('恢复默认图像参数'),
        350,
        scrollable: scroll,
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(preview), before);
      expect(find.byKey(const ValueKey('ink-effect-image')), findsOneWidget);
      expect(find.text('更新预览'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(c.inkPreviewActive, isFalse);
    });
  }

  testWidgets(
    'adjustment updates effect automatically without a refresh button',
    (tester) async {
      final rendered = <ComposerDraft>[];
      final c = EspInkController(
        artworkProcessor: (draft) async {
          rendered.add(draft);
          return ProcessedArtwork(
            solidFrame(color: 1),
            _png((150 + draft.adjustments.brightness).round()),
          );
        },
      );
      c.updateDraft(ComposerDraft(photoBytes: _png(160)));
      await open(tester, c, const Size(390, 844));
      expect(rendered, hasLength(1));
      final before = c.previewPng;
      final brightness = find.byWidgetPredicate(
        (widget) => widget is ValueSlider && widget.label == '亮度',
      );
      tester.widget<ValueSlider>(brightness).onChanged(27);
      await tester.pump(const Duration(milliseconds: 280));
      await tester.pumpAndSettle();
      expect(rendered, hasLength(2));
      expect(rendered.last.adjustments.brightness, 27);
      expect(c.previewReady, isTrue);
      expect(c.previewPng, isNot(orderedEquals(before!)));
      expect(find.text('更新预览'), findsNothing);
      expect(find.text('效果已更新 · 调整后自动刷新'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('closing editor restores an already active main effect preview', (
    tester,
  ) async {
    final c = EspInkController(
      artworkProcessor: (_) async =>
          ProcessedArtwork(solidFrame(color: 1), _png(190)),
    );
    c.updateDraft(ComposerDraft(photoBytes: _png(160)));
    c.setInkPreviewActive(true);
    await open(tester, c, const Size(390, 844));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(c.inkPreviewActive, isTrue);
    expect(tester.takeException(), isNull);
  });
}

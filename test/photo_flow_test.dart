import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/app/image_processor.dart';
import 'package:esp_ink/app/models.dart';
import 'package:esp_ink/core/frame_codec.dart';
import 'package:esp_ink/main.dart';

Uint8List _photo([int level = 120]) => Uint8List.fromList(
  img.encodePng(
    img.Image(width: 8, height: 6)..clear(img.ColorRgb8(level, 70, 40)),
  ),
);

class _FlowController extends EspInkController {
  _FlowController() : super(artworkProcessor: _artwork);

  Completer<bool>? selection;
  int picks = 0;

  static Future<ProcessedArtwork> _artwork(ComposerDraft draft) async =>
      ProcessedArtwork(
        solidFrame(color: 1),
        _photo((150 + draft.adjustments.brightness).round()),
      );

  @override
  Future<bool> pickPhoto() async {
    picks++;
    final selected = await (selection?.future ?? Future.value(true));
    if (!selected) return false;
    updateDraft(
      draft.copyWith(
        kind: CompositionKind.photo,
        photoBytes: _photo(90 + picks),
        quarterTurns: 0,
        rotation: 0,
        zoom: 1,
        offsetX: 0,
        offsetY: 0,
        mirror: false,
      ),
    );
    return true;
  }
}

const _select = ValueKey('select-photo');
const _adjust = ValueKey('adjust-photo');
const _editor = ValueKey('composition-editor');
const _mode = ValueKey('preview-mode');

// Tiny source images still decode outside fake async. Finish that work before
// settling route animations; a pending picker itself must only be pumped.
Future<void> _settleUi(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Future<_FlowController> _launch(
  WidgetTester tester, {
  ComposerDraft? draft,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = _FlowController();
  if (draft != null) c.updateDraft(draft);
  addTearDown(c.dispose);
  await tester.pumpWidget(EspInkApp(controller: c));
  await _settleUi(tester);
  expect(find.byKey(_select), findsOneWidget);
  expect(find.byKey(_adjust), findsOneWidget);
  expect(find.byKey(_editor), findsNothing);
  expect(find.byKey(_mode), findsNothing);
  expect(find.text('照片风格'), findsNothing);
  expect(find.text('裁剪与位置'), findsNothing);
  return c;
}

Future<void> _openAdjust(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_adjust));
  await tester.tap(find.byKey(_adjust));
  await _settleUi(tester);
  expect(find.byKey(_editor), findsOneWidget);
  expect(find.byKey(_mode), findsOneWidget);
}

Future<void> _finishAdjust(WidgetTester tester) async {
  await tester.tap(find.text('完成').last);
  await _settleUi(tester);
  expect(find.byKey(_editor), findsNothing);
  expect(find.byKey(_mode), findsNothing);
  expect(find.byKey(_select), findsOneWidget);
}

void main() {
  testWidgets(
    'a successful album selection opens exactly one adjustment page',
    (tester) async {
      final c = await _launch(tester);
      await tester.tap(find.byKey(_select));
      await _settleUi(tester);

      expect(c.picks, 1);
      expect(c.draft.photoBytes, isNotNull);
      expect(find.byKey(_editor), findsOneWidget);
      expect(find.byKey(_mode), findsOneWidget);
      expect(find.byKey(_select), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final existingPhoto in [false, true]) {
    testWidgets(
      'album cancellation stays on A ${existingPhoto ? 'with an old photograph' : 'without a photograph'}',
      (tester) async {
        final original = ComposerDraft(
          photoBytes: existingPhoto ? _photo() : null,
          zoom: 2,
          rotation: 12,
        );
        final c = await _launch(tester, draft: original);
        c.selection = Completer<bool>();
        await tester.tap(find.byKey(_select));
        await tester.pump();
        expect(c.picks, 1);
        c.selection!.complete(false);
        await _settleUi(tester);

        expect(c.draft, same(original));
        expect(find.byKey(_editor), findsNothing);
        expect(find.byKey(_select), findsOneWidget);
        expect(c.inkPreviewActive, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'one flow lock covers pending selection and is released after C',
    (tester) async {
      final c = await _launch(tester);
      c.selection = Completer<bool>();
      await tester.tap(find.byKey(_select));
      await tester.pump();
      await tester.tap(find.byKey(_select));
      await tester.tap(find.byKey(_adjust));
      await tester.pump();
      expect(c.picks, 1);
      expect(find.byKey(_editor), findsNothing);

      c.selection!.complete(true);
      await _settleUi(tester);
      expect(find.byKey(_editor), findsOneWidget);
      expect(c.picks, 1);
      await _finishAdjust(tester);

      c.selection = null;
      await tester.tap(find.byKey(_select));
      await _settleUi(tester);
      expect(c.picks, 2);
      expect(find.byKey(_editor), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('finishing C retains the last edits and final effect on A', (
    tester,
  ) async {
    final c = await _launch(tester, draft: ComposerDraft(photoBytes: _photo()));
    await _openAdjust(tester);
    c.updateDraft(
      c.draft.copyWith(
        quarterTurns: 1,
        rotation: 12,
        zoom: 2.3,
        mirror: true,
        adjustments: c.draft.adjustments.copyWith(
          brightness: 29,
          dither: DitherMode.bayer,
        ),
      ),
    );
    // Leave before the 240 ms debounce fires. A must still receive the final
    // draft's effect, rather than displaying the previous successful result.
    await tester.pump(const Duration(milliseconds: 20));
    await _finishAdjust(tester);

    expect(c.draft.quarterTurns, 1);
    expect(c.draft.rotation, 12);
    expect(c.draft.zoom, 2.3);
    expect(c.draft.mirror, isTrue);
    expect(c.draft.adjustments.brightness, 29);
    expect(c.draft.adjustments.dither, DitherMode.bayer);
    expect(c.previewReady, isTrue);
    expect(c.previewPng, orderedEquals(_photo(179)));
    expect(c.inkPreviewActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening C preserves photo geometry and effect parameters', (
    tester,
  ) async {
    final initial = ComposerDraft(
      photoBytes: _photo(),
      quarterTurns: 1,
      rotation: -17,
      zoom: 2.4,
      offsetX: .3,
      offsetY: -.2,
      mirror: true,
      adjustments: const ImageAdjustments(
        brightness: 31,
        dither: DitherMode.bayer,
      ),
    );
    final c = await _launch(tester, draft: initial);
    await _openAdjust(tester);
    await _finishAdjust(tester);
    await _openAdjust(tester);

    expect(c.picks, 0);
    expect(c.draft.photoBytes, same(initial.photoBytes));
    expect(c.draft.quarterTurns, 1);
    expect(c.draft.rotation, -17);
    expect(c.draft.zoom, 2.4);
    expect(c.draft.offsetX, .3);
    expect(c.draft.offsetY, -.2);
    expect(c.draft.mirror, isTrue);
    expect(c.draft.adjustments.brightness, 31);
    expect(c.draft.adjustments.dither, DitherMode.bayer);
    expect(c.previewReady, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adjustment is available without choosing a photograph first', (
    tester,
  ) async {
    final c = await _launch(tester);
    await _openAdjust(tester);
    await tester.tap(find.text('便签').last);
    await _settleUi(tester);

    expect(c.picks, 0);
    expect(c.draft.kind, CompositionKind.note);
    expect(find.byTooltip('添加文字'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'C cannot exit while a replacement photograph is being selected',
    (tester) async {
      final c = await _launch(
        tester,
        draft: ComposerDraft(photoBytes: _photo()),
      );
      await _openAdjust(tester);
      final originalPhoto = c.draft.photoBytes;
      c.selection = Completer<bool>();
      final replace = find.byKey(const ValueKey('composition-pick-photo'));
      await tester.ensureVisible(replace);
      await tester.tap(replace);
      await tester.pump();

      final done = find.widgetWithText(TextButton, '完成');
      expect(c.picks, 1);
      expect(tester.widget<TextButton>(done).onPressed, isNull);
      await tester.tap(done);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(_editor), findsOneWidget);
      expect(find.byKey(_select), findsNothing);
      expect(c.draft.photoBytes, same(originalPhoto));

      c.selection!.complete(true);
      await _settleUi(tester);
      expect(tester.widget<TextButton>(done).onPressed, isNotNull);
      expect(c.draft.photoBytes, isNot(same(originalPhoto)));
      await _finishAdjust(tester);
      expect(c.picks, 1);
      expect(c.previewReady, isTrue);
      expect(c.inkPreviewActive, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

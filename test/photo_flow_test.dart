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
const _modeSheet = ValueKey('composition-mode-sheet');
const _choosePhoto = ValueKey('choose-photo-mode');
const _chooseNote = ValueKey('choose-note-mode');
const _photoEditor = ValueKey('composition-editor-photo');
const _noteEditor = ValueKey('composition-editor-note');

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
  expect(find.byKey(_modeSheet), findsNothing);
}

Future<void> _openModeSheet(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_select));
  await tester.tap(find.byKey(_select));
  await _settleUi(tester);
  expect(find.byKey(_modeSheet), findsOneWidget);
  expect(find.byKey(_choosePhoto), findsOneWidget);
  expect(find.byKey(_chooseNote), findsOneWidget);
  expect(find.byKey(_editor), findsNothing);
}

Future<void> _selectPhotoMode(
  WidgetTester tester, {
  bool selectionPending = false,
}) async {
  await _openModeSheet(tester);
  await tester.tap(find.byKey(_choosePhoto));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  if (!selectionPending) await _settleUi(tester);
}

Future<void> _selectNoteMode(WidgetTester tester) async {
  await _openModeSheet(tester);
  await tester.tap(find.byKey(_chooseNote));
  await _settleUi(tester);
  expect(find.byKey(_noteEditor), findsOneWidget);
  expect(find.byKey(_photoEditor), findsNothing);
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
      await _openModeSheet(tester);
      expect(c.picks, 0);
      await tester.tap(find.byKey(_choosePhoto));
      await _settleUi(tester);

      expect(c.picks, 1);
      expect(c.draft.photoBytes, isNotNull);
      expect(find.byKey(_editor), findsOneWidget);
      expect(find.byKey(_photoEditor), findsOneWidget);
      expect(find.byKey(_noteEditor), findsNothing);
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
        await _selectPhotoMode(tester, selectionPending: true);
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
      await _selectPhotoMode(tester, selectionPending: true);
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
      await _selectPhotoMode(tester);
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
    await _selectNoteMode(tester);

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

  testWidgets(
    'dismissing the composition mode sheet preserves the entire draft',
    (tester) async {
      final original = ComposerDraft(
        kind: CompositionKind.note,
        photoBytes: _photo(),
        zoom: 2.2,
        adjustments: const ImageAdjustments(brightness: 27),
        photoTexts: const [TextLayer(id: 'photo', text: '照片文字')],
        noteTexts: const [TextLayer(id: 'note', text: '便签文字')],
      );
      final c = await _launch(tester, draft: original);
      await _openModeSheet(tester);
      expect(c.picks, 0);
      expect(c.draft, same(original));
      await tester.binding.handlePopRoute();
      await _settleUi(tester);

      expect(find.byKey(_modeSheet), findsNothing);
      expect(find.byKey(_editor), findsNothing);
      expect(c.picks, 0);
      expect(c.draft, same(original));
      await _openAdjust(tester);
      expect(find.byKey(_noteEditor), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in CompositionKind.values) {
    testWidgets('${kind.name} adjustment page exposes only its own tools', (
      tester,
    ) async {
      final c = await _launch(
        tester,
        draft: ComposerDraft(kind: kind, photoBytes: _photo()),
      );
      await _openAdjust(tester);
      final photo = kind == CompositionKind.photo;
      final page = find.byKey(photo ? _photoEditor : _noteEditor);
      Finder onPage(Finder finder) =>
          find.descendant(of: page, matching: finder);
      expect(page, findsOneWidget);
      expect(find.byKey(photo ? _noteEditor : _photoEditor), findsNothing);
      expect(onPage(find.text(photo ? '调整拍立得' : '调整便签')), findsOneWidget);
      expect(find.byKey(const ValueKey('composition-kind')), findsNothing);
      expect(onPage(find.byTooltip('添加文字')), findsOneWidget);
      expect(
        onPage(find.byKey(const ValueKey('composition-pick-photo'))),
        photo ? findsOneWidget : findsNothing,
      );
      expect(
        onPage(find.byKey(const ValueKey('open-photo-crop'))),
        photo ? findsOneWidget : findsNothing,
      );
      expect(onPage(find.text('照片留白')), photo ? findsOneWidget : findsNothing);
      expect(onPage(find.text('图像调整')), photo ? findsOneWidget : findsNothing);
      expect(onPage(find.text('便签底色')), photo ? findsNothing : findsOneWidget);
      expect(
        c.picks,
        0,
        reason: 'Adjust resumes the current mode without opening the album',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'finishing a note then adjusting again resumes C2 without another mode choice',
    (tester) async {
      final c = await _launch(tester);
      await _selectNoteMode(tester);
      c.updateDraft(
        c.draft.copyWith(
          background: 2,
          noteTexts: const [
            TextLayer(id: 'remember-note', text: '记住这张便签', color: 3),
          ],
        ),
      );
      await _finishAdjust(tester);
      expect(c.draft.kind, CompositionKind.note);
      expect(c.previewReady, isTrue);
      await _openAdjust(tester);

      expect(find.byKey(_noteEditor), findsOneWidget);
      expect(find.byKey(_modeSheet), findsNothing);
      expect(c.picks, 0);
      expect(c.draft.background, 2);
      expect(c.draft.noteTexts.single.text, '记住这张便签');
      expect(c.draft.noteTexts.single.color, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'photo and note text objects remain independent across A mode choices',
    (tester) async {
      final c = await _launch(
        tester,
        draft: ComposerDraft(
          photoBytes: _photo(),
          photoTexts: const [
            TextLayer(id: 'photo-text', text: '拍立得文字', size: 36, color: 3),
          ],
          noteTexts: const [
            TextLayer(id: 'note-text', text: '便签文字', size: 62, color: 0),
          ],
        ),
      );
      await _selectNoteMode(tester);
      expect(c.picks, 0);
      expect(c.draft.textLayers.single.id, 'note-text');
      c.updateDraft(
        c.draft.copyWith(
          noteTexts: [
            c.draft.noteTexts.single.copyWith(text: '只改便签', size: 72, color: 2),
          ],
        ),
      );
      await _finishAdjust(tester);

      await _selectPhotoMode(tester);
      expect(find.byKey(_photoEditor), findsOneWidget);
      expect(c.draft.textLayers.single.id, 'photo-text');
      expect(c.draft.photoTexts.single.text, '拍立得文字');
      expect(c.draft.photoTexts.single.size, 36);
      expect(c.draft.noteTexts.single.text, '只改便签');
      c.updateDraft(
        c.draft.copyWith(
          photoTexts: [
            c.draft.photoTexts.single.copyWith(text: '只改拍立得', size: 42),
          ],
        ),
      );
      await _finishAdjust(tester);
      await _selectNoteMode(tester);

      expect(c.picks, 1);
      expect(c.draft.textLayers.single.id, 'note-text');
      expect(c.draft.noteTexts.single.text, '只改便签');
      expect(c.draft.noteTexts.single.size, 72);
      expect(c.draft.noteTexts.single.color, 2);
      expect(c.draft.photoTexts.single.text, '只改拍立得');
      expect(c.draft.photoTexts.single.size, 42);
      expect(c.draft.photoTexts.single.color, 3);
      expect(tester.takeException(), isNull);
    },
  );
}

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/app/models.dart';
import 'package:esp_ink/ui/photo_crop_editor.dart';

class CropController extends EspInkController {
  int commits = 0;

  @override
  void updateDraft(ComposerDraft value) {
    commits++;
    draft = value;
    notifyListeners();
  }
}

Uint8List _photograph() {
  final image = img.Image(width: 180, height: 120);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgb(x, y, x, y * 2, 140);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  Future<CropController> launch(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    ComposerDraft? draft,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = CropController();
    c.draft = draft ?? ComposerDraft(photoBytes: _photograph());
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, fontFamily: 'NotoSansSC'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showPhotoCropEditor(context, c),
                child: const Text('打开裁剪'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开裁剪'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    return c;
  }

  Slider slider(WidgetTester tester, String key) =>
      tester.widget<Slider>(find.byKey(Key(key)));

  testWidgets(
    'phone keeps the live original and both adjustment sliders visible',
    (tester) async {
      final c = await launch(tester);
      expect(find.byKey(const Key('crop-workspace')), findsOneWidget);
      expect(find.text('原图 · 实时调整'), findsOneWidget);
      final workspace = tester.getRect(find.byKey(const Key('crop-workspace')));
      final zoom = tester.getRect(find.byKey(const Key('crop-zoom')));
      expect(workspace.height, greaterThan(320));
      expect(zoom.bottom, lessThanOrEqualTo(844));
      expect(workspace.bottom, lessThan(zoom.top));
      expect(c.commits, 0);
      expect(c.rendering, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel discards local rotation mirror and zoom edits', (
    tester,
  ) async {
    final c = await launch(tester);
    final original = c.draft;
    await tester.tap(find.text('右转 90°'));
    await tester.tap(find.text('镜像'));
    slider(tester, 'crop-zoom').onChanged!(3);
    await tester.pump();
    expect(c.draft, same(original));
    expect(c.commits, 0);
    await tester.tap(find.byTooltip('取消裁剪'));
    await tester.pumpAndSettle();
    expect(c.draft, same(original));
    expect(c.commits, 0);
    expect(find.text('打开裁剪'), findsOneWidget);
  });

  testWidgets(
    'apply commits one final draft without generating a dot preview',
    (tester) async {
      final c = await launch(tester);
      await tester.tap(find.text('右转 90°'));
      await tester.tap(find.text('镜像'));
      slider(tester, 'crop-zoom').onChanged!(3.5);
      await tester.pump();
      expect(c.commits, 0);
      await tester.tap(find.byKey(const Key('crop-apply')));
      await tester.pumpAndSettle();
      expect(c.commits, 1);
      expect(c.draft.quarterTurns, 1);
      expect(c.draft.mirror, isTrue);
      expect(c.draft.zoom, closeTo(3.5, .001));
      expect(c.previewPng, isNull);
      expect(c.rendering, isFalse);
    },
  );

  testWidgets('dragging a zoomed photograph changes its crop position', (
    tester,
  ) async {
    final c = await launch(tester);
    slider(tester, 'crop-zoom').onChanged!(3);
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('crop-workspace')),
      const Offset(60, 30),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('crop-apply')));
    await tester.pumpAndSettle();
    expect(c.draft.offsetX, greaterThan(0));
    expect(c.draft.offsetY, greaterThan(0));
    expect(c.draft.zoom, closeTo(3, .001));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'two fingers zoom and rotate the cached original in one gesture',
    (tester) async {
      final c = await launch(tester);
      final center = tester.getCenter(find.byKey(const Key('crop-workspace')));
      final first = await tester.startGesture(center - const Offset(45, 0));
      final second = await tester.startGesture(
        center + const Offset(45, 0),
        pointer: 2,
      );
      await tester.pump();
      await first.moveTo(center - const Offset(75, 22));
      await second.moveTo(center + const Offset(75, 22));
      await tester.pump();
      await first.moveTo(center - const Offset(95, 32));
      await second.moveTo(center + const Offset(95, 32));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pump();
      await tester.tap(find.byKey(const Key('crop-apply')));
      await tester.pumpAndSettle();
      expect(c.draft.zoom, greaterThan(1.2));
      expect(c.draft.rotation.abs(), greaterThan(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a corner handle reframes at the fixed panel aspect ratio', (
    tester,
  ) async {
    final c = await launch(tester);
    final workspace = tester.getRect(find.byKey(const Key('crop-workspace')));
    final scale = math.min(
      (workspace.width - 48) / 768,
      (workspace.height - 76) / 552,
    );
    final corner = workspace.center + Offset(768 * scale / 2, 552 * scale / 2);
    final gesture = await tester.startGesture(corner);
    await gesture.moveBy(const Offset(-22, -16));
    await tester.pump();
    await gesture.moveBy(const Offset(-70, -50));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.tap(find.byKey(const Key('crop-apply')));
    await tester.pumpAndSettle();
    expect(c.draft.zoom, greaterThan(1.2));
    expect(c.draft.offsetX.abs() + c.draft.offsetY.abs(), greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'fine rotation keeps a stable quarter turn at the plus 45 endpoint',
    (tester) async {
      final c = await launch(tester);
      slider(tester, 'crop-rotation').onChanged!(45);
      await tester.pump();
      slider(tester, 'crop-rotation').onChanged!(44);
      await tester.pump();
      await tester.tap(find.byKey(const Key('crop-apply')));
      await tester.pumpAndSettle();
      expect(c.draft.quarterTurns, 0);
      expect(c.draft.rotation, closeTo(44, .0001));
    },
  );

  testWidgets('landscape keeps the workspace beside scrollable controls', (
    tester,
  ) async {
    await launch(tester, size: const Size(844, 390));
    final workspace = tester.getRect(find.byKey(const Key('crop-workspace')));
    final zoom = tester.getRect(find.byKey(const Key('crop-zoom')));
    expect(workspace.width, greaterThan(450));
    expect(workspace.height, greaterThan(250));
    expect(workspace.right, lessThanOrEqualTo(zoom.left));
    expect(tester.takeException(), isNull);
  });

  testWidgets('padding uses the actual photograph window dimensions', (
    tester,
  ) async {
    await launch(
      tester,
      draft: ComposerDraft(photoBytes: _photograph(), paddingEnabled: true),
    );
    expect(find.text('704 × 456'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy extreme geometry opens with finite bounded controls', (
    tester,
  ) async {
    final c = await launch(
      tester,
      draft: ComposerDraft(
        photoBytes: _photograph(),
        quarterTurns: -9999999,
        rotation: 1e308,
        zoom: double.nan,
        offsetX: double.infinity,
      ),
    );
    expect(slider(tester, 'crop-rotation').value.isFinite, isTrue);
    expect(slider(tester, 'crop-zoom').value, 1);
    await tester.tap(find.byKey(const Key('crop-apply')));
    await tester.pumpAndSettle();
    expect(c.draft.rotation.abs(), lessThanOrEqualTo(45));
    expect(c.draft.offsetX.isFinite, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing and invalid photos cannot apply an invisible crop', (
    tester,
  ) async {
    final c = await launch(tester, draft: const ComposerDraft());
    expect(find.text('请返回并选择一张照片，再调整裁剪。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('crop-apply')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('取消裁剪'));
    await tester.pumpAndSettle();
    c.draft = ComposerDraft(photoBytes: Uint8List.fromList([1, 2, 3]));
    await tester.tap(find.text('打开裁剪'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.text('这张照片暂时无法打开，请返回后重新选择。'), findsOneWidget);
    expect(find.byKey(const Key('crop-workspace')), findsNothing);
    expect(c.commits, 0);
    expect(tester.takeException(), isNull);
  });
}

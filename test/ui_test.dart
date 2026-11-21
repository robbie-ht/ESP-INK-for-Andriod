import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/app/image_processor.dart';
import 'package:esp_ink/app/models.dart';
import 'package:esp_ink/core/frame_codec.dart';
import 'package:esp_ink/main.dart';

class UiController extends EspInkController {
  UiController({ArtworkProcessor? artworkProcessor})
    : super(artworkProcessor: artworkProcessor ?? _uiArtwork);

  int scans = 0, sends = 0, saves = 0;
  @override
  Future<void> scan() async {
    scans++;
  }

  @override
  Future<bool> pickPhoto() async {
    updateDraft(
      draft.copyWith(
        photoBytes: Uint8List.fromList(
          img.encodePng(img.Image(width: 4, height: 4)),
        ),
      ),
    );
    return true;
  }

  @override
  Future<void> enterDemo() async {
    demo = true;
    deviceName = 'ESP-INK · 体验设备';
    gallerySupported = true;
    gallery = [
      for (var i = 0; i < 3; i++)
        GalleryItemView(slot: i, title: '演示便签 ${i + 1}'),
    ];
    notifyListeners();
  }

  @override
  Future<void> send({bool saveGallery = false, bool storeOnly = false}) async {
    sends++;
  }

  @override
  Future<void> saveSettings(SettingsView value) async {
    saves++;
    settings = value;
    notifyListeners();
  }
}

Future<ProcessedArtwork> _uiArtwork(ComposerDraft _) async => ProcessedArtwork(
  solidFrame(color: 1),
  Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4))),
);

void main() {
  Future<void> launch(WidgetTester tester, UiController c, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(c.dispose);
    await tester.pumpWidget(EspInkApp(controller: c));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'phone starts with an empty photograph and explicit BLE or demo entry',
    (tester) async {
      final c = UiController();
      await launch(tester, c, const Size(390, 844));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('选择一张照片'), findsOneWidget);
      expect(find.text('海报'), findsNothing);
      expect(find.text('日出慢行'), findsNothing);
      expect(c.draft.photoBytes, isNull);
      expect(c.draft.textLayers, isEmpty);
      await tester.tap(find.text('未连接设备'));
      await tester.pumpAndSettle();
      expect(find.text('连接你的墨水屏'), findsOneWidget);
      expect(c.connected, isFalse);
      expect(c.sends, 0);
      await tester.tap(find.text('体验演示'));
      await tester.pumpAndSettle();
      expect(c.demo, isTrue);
      expect(c.connected, isFalse);
      expect(find.text('本地演示 · 操作不会发送到真实设备'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide layout offers only photo and note, and adds independently styled text objects',
    (tester) async {
      final c = UiController();
      await launch(tester, c, const Size(1440, 1000));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(const ValueKey('preview-mode')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('adjust-photo')));
      await tester.tap(find.byKey(const ValueKey('adjust-photo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composition-editor')), findsOneWidget);
      await tester.tap(find.text('便签').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加文字'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('layer-text-input')),
        '想记住这一天',
      );
      await tester.ensureVisible(find.text('添加到画面'));
      await tester.tap(find.text('添加到画面'));
      await tester.pumpAndSettle();
      expect(c.draft.kind, CompositionKind.note);
      expect(c.draft.noteTexts.single.text, '想记住这一天');
      expect(c.draft.photoTexts, isEmpty);
      await tester.tap(find.text('拍立得').first);
      await tester.pumpAndSettle();
      expect(c.draft.textLayers, isEmpty);
      await tester.tap(find.text('便签').last);
      await tester.pumpAndSettle();
      expect(c.draft.noteTexts.single.text, '想记住这一天');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('demo transmission is explicit and does not require fake BLE', (
    tester,
  ) async {
    final c = UiController();
    await c.enterDemo();
    c.draft = const ComposerDraft(
      kind: CompositionKind.note,
      noteTexts: [TextLayer(id: 'test', text: '今天很好')],
    );
    await launch(tester, c, const Size(1200, 950));
    await tester.ensureVisible(find.text('演示发送'));
    await tester.tap(find.text('演示发送'));
    await tester.pumpAndSettle();
    expect(find.text('本地演示 · 不向真实设备发送'), findsOneWidget);
    await tester.tap(find.text('立即显示'));
    await tester.pumpAndSettle();
    expect(c.sends, 1);
    expect(c.connected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'device name enforces UTF8 length and closes safely after valid save',
    (tester) async {
      final c = UiController();
      await c.enterDemo();
      c.tabIndex = 2;
      await launch(tester, c, const Size(390, 844));
      await tester.ensureVisible(find.text('屏幕与名称'));
      await tester.tap(find.text('屏幕与名称'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '这是一段非常长的设备名称');
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(c.saves, 0);
      expect(find.text('名称最多 20 个 UTF-8 字节（约 6 个汉字）'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '我的墨水屏');
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(c.saves, 1);
      expect(c.settings.name, '我的墨水屏');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'device scroll and advanced expansion restore independently across tabs',
    (tester) async {
      final c = UiController();
      await c.enterDemo();
      c.tabIndex = 2;
      await launch(tester, c, const Size(390, 844));

      final deviceScroll = find.byKey(const PageStorageKey('tab-2'));
      double scrollOffset() => tester
          .state<ScrollableState>(
            find.descendant(
              of: deviceScroll,
              matching: find.byType(Scrollable),
            ),
          )
          .position
          .pixels;
      Future<void> selectTab(String label) async {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
        );
        await tester.pumpAndSettle();
      }

      await tester.drag(deviceScroll, const Offset(0, -360));
      await tester.pumpAndSettle();
      final savedOffset = scrollOffset();
      expect(savedOffset, greaterThan(0));
      await selectTab('创作');
      await selectTab('设备');
      expect(tester.takeException(), isNull);
      expect(scrollOffset(), closeTo(savedOffset, 1));

      await tester.ensureVisible(find.text('高级设置'));
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      expect(find.text('接线与 GPIO'), findsOneWidget);
      final expandedOffset = scrollOffset();
      await selectTab('创作');
      await selectTab('设备');
      expect(tester.takeException(), isNull);
      expect(find.text('接线与 GPIO'), findsOneWidget);
      expect(scrollOffset(), closeTo(expandedOffset, 1));
    },
  );

  testWidgets(
    'gallery has no fabricated image when a thumbnail is unavailable',
    (tester) async {
      final c = UiController();
      await c.enterDemo();
      c.tabIndex = 1;
      await launch(tester, c, const Size(360, 800));
      expect(find.text('3 / 8 张'), findsOneWidget);
      expect(find.text('本地演示图库'), findsOneWidget);
      await tester.ensureVisible(find.text('演示便签 3'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.photo_outlined), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'geometry applies once and image settings update actual draft fields',
    (tester) async {
      final previews = <ComposerDraft>[];
      final c = UiController(
        artworkProcessor: (draft) async {
          previews.add(draft);
          return ProcessedArtwork(
            solidFrame(color: 1),
            Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4))),
          );
        },
      );
      Future<void> tapAndSettleAutomaticEffect(Finder control) async {
        await tester.tap(control);
        await tester.pump(const Duration(milliseconds: 280));
        await tester.pumpAndSettle();
        expect(c.previewReady, isTrue);
      }

      await c.pickPhoto();
      await launch(tester, c, const Size(1440, 1000));
      await tester.ensureVisible(find.byKey(const ValueKey('adjust-photo')));
      await tester.tap(find.byKey(const ValueKey('adjust-photo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composition-editor')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('open-photo-crop')));
      await tester.tap(find.byKey(const ValueKey('open-photo-crop')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('右转 90°'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('镜像'));
      await tester.pumpAndSettle();
      expect(c.draft.quarterTurns, 0);
      expect(c.draft.mirror, isFalse);
      final zoom = find.byKey(const Key('crop-zoom'));
      await tester.drag(zoom, const Offset(100, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(c.draft.quarterTurns, 1);
      expect(c.draft.mirror, isTrue);
      expect(c.draft.zoom, greaterThan(1));
      await tester.ensureVisible(find.text('Floyd–Steinberg'));
      await tester.tap(find.text('Floyd–Steinberg'));
      await tester.pumpAndSettle();
      expect(find.text('Bayer 8 × 8'), findsOneWidget);
      await tapAndSettleAutomaticEffect(find.text('Bayer 8 × 8'));
      expect(c.draft.adjustments.dither, DitherMode.bayer);
      await tester.ensureVisible(find.text('自动色阶'));
      await tapAndSettleAutomaticEffect(find.text('自动色阶'));
      expect(c.draft.adjustments.autoLevels, isFalse);
      expect(previews.last.adjustments.dither, DitherMode.bayer);
      expect(previews.last.adjustments.autoLevels, isFalse);
      expect(c.rendering, isFalse);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composition-editor')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty text cannot be added to the canvas', (tester) async {
    final c = UiController();
    c.draft = const ComposerDraft(kind: CompositionKind.note);
    await launch(tester, c, const Size(390, 844));
    await tester.ensureVisible(find.byKey(const ValueKey('adjust-photo')));
    await tester.tap(find.byKey(const ValueKey('adjust-photo')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('添加文字'));
    await tester.tap(find.byTooltip('添加文字'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('添加到画面'));
    await tester.tap(find.text('添加到画面'));
    await tester.pumpAndSettle();
    expect(c.draft.textLayers, isEmpty);
    expect(find.text('请先输入文字'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

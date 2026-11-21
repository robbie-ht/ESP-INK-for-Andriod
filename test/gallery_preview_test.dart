import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/app/models.dart';
import 'package:esp_ink/core/image_export.dart';
import 'package:esp_ink/ui/gallery_page.dart';

Uint8List _png(int red) {
  final image = img.Image(width: 48, height: 32);
  img.fill(image, color: img.ColorRgb8(red, 170, 210));
  return Uint8List.fromList(img.encodePng(image));
}

class GalleryTestController extends EspInkController {
  GalleryTestController({Uint8List? cached}) {
    gallerySupported = true;
    tabIndex = 1;
    gallery = [GalleryItemView(slot: 0, title: '我的画面', png: cached)];
  }

  String identity = 'device-A:slot-0:revision-1';
  bool online = true, isReading = false;
  int preloads = 0, shows = 0;
  final List<bool> reads = [];
  final List<bool> forcedReads = [];
  GalleryPreviewStatus status = const GalleryPreviewStatus();
  Future<GalleryPreviewResult> Function(bool fullFrame)? reader;

  @override
  bool get connected => online;
  @override
  bool get galleryReading => isReading;
  @override
  String? galleryItemIdentity(int slot) =>
      gallery.any((g) => g.slot == slot) ? identity : null;
  @override
  GalleryPreviewStatus galleryPreviewStatus(int slot) => status;
  @override
  Future<void> preloadGalleryPreviews() async => preloads++;
  @override
  Future<GalleryPreviewResult> readGalleryPreview(
    int slot, {
    bool fullFrame = false,
    bool forceReload = false,
  }) async {
    reads.add(fullFrame);
    forcedReads.add(forceReload);
    return reader != null
        ? await reader!(fullFrame)
        : GalleryPreviewResult(
            png: _png(fullFrame ? 200 : 30),
            fullFrame: fullFrame || demo,
            identity: identity,
          );
  }

  @override
  Future<void> showGallery(int slot) async => shows++;

  void updateStatus(GalleryPreviewStatus value) {
    status = value;
    notifyListeners();
  }

  void replaceIdentity() {
    identity = 'device-A:slot-0:revision-2';
    notifyListeners();
  }

  void completeBackgroundFull(Uint8List png) {
    gallery = [GalleryItemView(slot: 0, title: '我的画面', png: png)];
    status = const GalleryPreviewStatus(fullFrame: true);
    notifyListeners();
  }
}

void main() {
  Future<void> screen(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> finishImages(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> viewer(
    WidgetTester tester,
    GalleryTestController c, {
    Size size = const Size(390, 844),
    bool downloadOnOpen = false,
    GalleryImageSaver? saveImage,
  }) async {
    await screen(tester, size);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, fontFamily: 'NotoSansSC'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => GalleryImageViewer(
                      c: c,
                      slot: 0,
                      downloadOnOpen: downloadOnOpen,
                      saveImage: saveImage ?? saveGalleryImage,
                    ),
                  ),
                ),
                child: const Text('打开画面'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开画面'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> cards(WidgetTester tester, GalleryTestController c) async {
    await screen(tester, const Size(390, 844));
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: GalleryPage(c: c),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('cards preload once, show each read state and offer a download', (
    tester,
  ) async {
    final c = GalleryTestController();
    c.status = const GalleryPreviewStatus(loading: true, progress: .4);
    await cards(tester, c);
    expect(c.preloads, 1);
    expect(find.text('正在读取设备预览…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byTooltip('下载完整图片'), findsOneWidget);
    c.updateStatus(const GalleryPreviewStatus(error: '数据校验失败'));
    await tester.pump();
    expect(c.preloads, 1);
    expect(find.text('读取失败 · 点按重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'opening the viewer is immediate while the device read is pending',
    (tester) async {
      final c = GalleryTestController();
      final pending = Completer<GalleryPreviewResult>();
      c.reader = (_) => pending.future;
      await viewer(tester, c);
      expect(find.byType(GalleryImageViewer), findsOneWidget);
      expect(find.text('正在读取设备预览…'), findsNWidgets(2));
      expect(c.reads, [false]);
      pending.complete(
        GalleryPreviewResult(png: _png(30), identity: c.identity),
      );
      await finishImages(tester);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.fit, BoxFit.contain);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('read failure is visible in the viewer and retry recovers', (
    tester,
  ) async {
    final c = GalleryTestController();
    var attempts = 0;
    c.reader = (_) async => ++attempts == 1
        ? GalleryPreviewResult(error: '蓝牙读取超时', identity: c.identity)
        : GalleryPreviewResult(png: _png(40), identity: c.identity);
    await viewer(tester, c);
    await finishImages(tester);
    expect(find.text('蓝牙读取超时'), findsOneWidget);
    await tester.tap(find.text('重试读取'));
    await finishImages(tester);
    expect(c.reads, [false, false]);
    expect(c.forcedReads, [false, true]);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('蓝牙读取超时'), findsNothing);
  });

  testWidgets(
    'full frame failure retains the thumbnail and can retry full detail',
    (tester) async {
      final c = GalleryTestController();
      var fullAttempts = 0;
      c.reader = (full) async => full && ++fullAttempts == 1
          ? GalleryPreviewResult(error: '完整画面校验失败', identity: c.identity)
          : GalleryPreviewResult(
              png: _png(full ? 210 : 40),
              fullFrame: full,
              identity: c.identity,
            );
      await viewer(tester, c);
      await finishImages(tester);
      await tester.tap(find.byKey(const Key('gallery-read-full')));
      await finishImages(tester);
      expect(find.text('完整画面校验失败'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.text('重试读取'));
      await finishImages(tester);
      expect(c.reads, [false, true, true]);
      expect(find.text('完整画面 · 768 × 552'), findsOneWidget);
      expect(find.text('已读取完整画面'), findsOneWidget);
    },
  );

  testWidgets(
    'double tap zooms and restores, with pan available while enlarged',
    (tester) async {
      final c = GalleryTestController();
      await viewer(tester, c);
      await finishImages(tester);
      final image = find.byKey(const Key('gallery-image-viewer'));
      final transform = tester
          .widget<InteractiveViewer>(image)
          .transformationController!;
      final center = tester.getCenter(image);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 300));
      expect(transform.value.getMaxScaleOnAxis(), closeTo(2.5, .001));
      final before = transform.value.getTranslation().x;
      await tester.drag(image, const Offset(45, 20));
      await tester.pumpAndSettle();
      expect(transform.value.getTranslation().x, isNot(closeTo(before, .01)));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 300));
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1, .001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changed gallery identity hides the old image and ignores a late read',
    (tester) async {
      final c = GalleryTestController(cached: _png(40));
      final oldIdentity = c.identity;
      final pending = Completer<GalleryPreviewResult>();
      c.reader = (_) => pending.future;
      await viewer(tester, c);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      c.replaceIdentity();
      await tester.pump();
      expect(find.text('这张画面已发生变化'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      pending.complete(
        GalleryPreviewResult(png: _png(40), identity: oldIdentity),
      );
      await finishImages(tester);
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.byKey(const Key('gallery-download')), findsNothing);
    },
  );

  testWidgets('landscape leaves image and scrollable controls side by side', (
    tester,
  ) async {
    final c = GalleryTestController();
    await viewer(tester, c, size: const Size(844, 390));
    await finishImages(tester);
    final image = tester.getRect(find.byKey(const Key('gallery-image-viewer')));
    final read = tester.getRect(find.byKey(const Key('gallery-read-full')));
    expect(image.height, greaterThan(300));
    expect(image.right, lessThanOrEqualTo(read.left));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an open thumbnail upgrades to background full frame without resetting zoom',
    (tester) async {
      final c = GalleryTestController(cached: _png(25));
      await viewer(tester, c);
      await finishImages(tester);
      final interactive = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      interactive.transformationController!.value = Matrix4.diagonal3Values(
        2,
        2,
        1,
      );
      final full = _png(230);
      c.completeBackgroundFull(full);
      await finishImages(tester);
      final image = tester.widget<Image>(find.byType(Image).first);
      expect((image.image as MemoryImage).bytes, same(full));
      expect(find.text('完整画面 · 768 × 552'), findsOneWidget);
      expect(
        interactive.transformationController!.value.getMaxScaleOnAxis(),
        2,
      );
      expect(c.reads, [false]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'download reads the full image and displays the real export result',
    (tester) async {
      final c = GalleryTestController();
      final full = _png(240);
      c.reader = (isFull) async => GalleryPreviewResult(
        png: isFull ? full : _png(20),
        fullFrame: isFull,
        identity: c.identity,
      );
      Uint8List? saved;
      String? filename;
      await viewer(
        tester,
        c,
        saveImage: (png, {required fileName}) async {
          saved = png;
          filename = fileName;
          return '已发起下载：ESP-INK.png（请查看浏览器下载列表）';
        },
      );
      await finishImages(tester);
      await tester.tap(find.byKey(const Key('gallery-download')));
      await finishImages(tester);
      expect(c.reads, [false, true]);
      expect(saved, same(full));
      expect(filename, startsWith('ESP-INK-画面-1-'));
      expect(find.text('已发起下载：ESP-INK.png（请查看浏览器下载列表）'), findsOneWidget);
      expect(find.text('完整画面 · 768 × 552'), findsOneWidget);
    },
  );

  testWidgets('failed full read never exports the cached thumbnail', (
    tester,
  ) async {
    final c = GalleryTestController();
    c.reader = (full) async => GalleryPreviewResult(
      png: full ? null : _png(20),
      fullFrame: false,
      error: full ? '连接已断开，未能读取完整画面' : null,
      identity: c.identity,
    );
    var saves = 0;
    await viewer(
      tester,
      c,
      saveImage: (_, {required fileName}) async {
        saves++;
        return 'should not save';
      },
    );
    await finishImages(tester);
    await tester.tap(find.byKey(const Key('gallery-download')));
    await finishImages(tester);
    expect(saves, 0);
    expect(find.text('连接已断开，未能读取完整画面'), findsOneWidget);
    expect(find.text('重试下载图片'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('export errors stay visible and retry can save successfully', (
    tester,
  ) async {
    final c = GalleryTestController();
    var attempts = 0;
    await viewer(
      tester,
      c,
      saveImage: (_, {required fileName}) async {
        if (++attempts == 1) {
          throw ImageExportException('相册保存失败，请重试', code: 'save_failed');
        }
        return '已保存到相册：Pictures/ESP-INK/test.png';
      },
    );
    await finishImages(tester);
    await tester.tap(find.byKey(const Key('gallery-download')));
    await finishImages(tester);
    expect(find.text('相册保存失败，请重试'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('gallery-download')));
    await tester.tap(find.byKey(const Key('gallery-download')));
    await finishImages(tester);
    expect(attempts, 2);
    expect(find.text('已保存到相册：Pictures/ESP-INK/test.png'), findsOneWidget);
    expect(find.text('相册保存失败，请重试'), findsNothing);
  });

  testWidgets('a thumbnail returned for a full request is never saved', (
    tester,
  ) async {
    final c = GalleryTestController();
    c.reader = (_) async => GalleryPreviewResult(
      png: _png(20),
      fullFrame: false,
      identity: c.identity,
    );
    var saves = 0;
    await viewer(
      tester,
      c,
      saveImage: (_, {required fileName}) async {
        saves++;
        return 'should not save';
      },
    );
    await finishImages(tester);
    await tester.tap(find.byKey(const Key('gallery-download')));
    await finishImages(tester);
    expect(saves, 0);
    expect(find.text('完整画面尚未读取，未保存缩略图。请重试下载。'), findsOneWidget);
  });

  testWidgets(
    'download entry opens directly into full read and prevents reentry',
    (tester) async {
      final c = GalleryTestController();
      final saving = Completer<String>();
      var saves = 0;
      await viewer(
        tester,
        c,
        downloadOnOpen: true,
        saveImage: (_, {required fileName}) {
          saves++;
          return saving.future;
        },
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
      expect(c.reads, [true]);
      expect(saves, 1);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('gallery-download')))
            .onPressed,
        isNull,
      );
      saving.complete('已保存到相册：Pictures/ESP-INK/test.png');
      await finishImages(tester);
      expect(find.byKey(const Key('gallery-save-result')), findsOneWidget);
    },
  );

  testWidgets('background reading keeps show and refresh actions available', (
    tester,
  ) async {
    final c = GalleryTestController(cached: _png(20));
    c.busy = true;
    c.isReading = true;
    await cards(tester, c);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '刷新图库',
            ),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '在墨水屏上显示',
            ),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byTooltip('在墨水屏上显示'));
    expect(c.shows, 1);
    expect(tester.takeException(), isNull);
  });
}

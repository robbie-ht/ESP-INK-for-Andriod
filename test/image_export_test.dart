import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/core/image_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.robbieht.espink/image_export');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));
  late List<MethodCall> calls;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return '已保存到相册：Pictures/ESP-INK/test-unique.png';
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('exports actual PNG bytes to the separate Android channel', () async {
    final result = await saveGalleryImage(png, fileName: '墨水屏-图库-1.png');
    expect(result, '已保存到相册：Pictures/ESP-INK/test-unique.png');
    expect(calls.single.method, 'savePng');
    expect(calls.single.arguments['png'], orderedEquals(png));
    expect(calls.single.arguments['fileName'], '墨水屏-图库-1.png');
  });

  test(
    'empty, wrong-format and truncated images never reach Android',
    () async {
      for (final bytes in [
        Uint8List(0),
        Uint8List(80),
        Uint8List.sublistView(png, 0, png.length - 5),
      ]) {
        await expectLater(
          saveGalleryImage(bytes, fileName: 'test.png'),
          throwsA(
            isA<ImageExportException>().having(
              (e) => e.code,
              'code',
              'invalid_image',
            ),
          ),
        );
      }
      expect(calls, isEmpty);
    },
  );

  test('unsafe and oversized filenames never reach Android', () async {
    for (final name in [
      '../test.png',
      r'folder\test.png',
      'test\u0000.png',
      '.png',
      'test.jpg',
      '${'长' * 60}.png',
    ]) {
      await expectLater(
        saveGalleryImage(png, fileName: name),
        throwsA(
          isA<ImageExportException>().having(
            (e) => e.code,
            'code',
            'invalid_filename',
          ),
        ),
      );
    }
    expect(calls, isEmpty);
  });

  test('permission denial preserves the actionable native error', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'permission_denied',
        message: '未获得存储权限，图片未保存。',
      );
    });
    await expectLater(
      saveGalleryImage(png, fileName: 'test.png'),
      throwsA(
        isA<ImageExportException>()
            .having((e) => e.code, 'code', 'permission_denied')
            .having((e) => e.toString(), 'message', '未获得存储权限，图片未保存。'),
      ),
    );
  });

  test(
    'missing service and missing save result never report success',
    () async {
      messenger.setMockMethodCallHandler(channel, null);
      await expectLater(
        saveGalleryImage(png, fileName: 'test.png'),
        throwsA(
          isA<ImageExportException>().having(
            (e) => e.code,
            'code',
            'missing_plugin',
          ),
        ),
      );
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      await expectLater(
        saveGalleryImage(png, fileName: 'test.png'),
        throwsA(isA<ImageExportException>()),
      );
    },
  );

  test('native cancellation is kept distinct from a failed save', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'cancelled', message: '已取消保存。');
    });
    await expectLater(
      saveGalleryImage(png, fileName: 'test.png'),
      throwsA(
        isA<ImageExportException>().having((e) => e.code, 'code', 'cancelled'),
      ),
    );
  });

  group('Windows PNG export', () {
    const selectorChannel = MethodChannel('plugins.flutter.io/file_selector');
    late Directory temporary;
    late String selectedPath;
    late List<MethodCall> selectorCalls;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await Directory('build').create(recursive: true);
      temporary = await Directory('build').createTemp('图片 导出 测试-');
      selectedPath = '${temporary.path}/保存 结果.png';
      selectorCalls = [];
      messenger.setMockMethodCallHandler(selectorChannel, (call) async {
        selectorCalls.add(call);
        return selectedPath;
      });
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(selectorChannel, null);
      await temporary.delete(recursive: true);
    });

    // The real selector adapter and XFile writer run; no OS dialog is opened.
    test(
      'writes the complete PNG to the selected Unicode path with spaces',
      () async {
        final result = await saveGalleryImage(png, fileName: '墨水屏 图库-1.png');
        expect(result, '已保存到：$selectedPath');
        final written = await File(selectedPath).readAsBytes();
        expect(written, orderedEquals(png));
        final decoded = img.decodePng(written)!;
        expect((decoded.width, decoded.height), (8, 8));
        expect(
          calls,
          isEmpty,
          reason: 'Windows must not use Android MediaStore',
        );
        expect(selectorCalls.single.method, 'getSavePath');
        final arguments =
            selectorCalls.single.arguments as Map<Object?, Object?>;
        expect(arguments['suggestedName'], '墨水屏 图库-1.png');
        expect(arguments['confirmButtonText'], '保存图片');
        final groups = arguments['acceptedTypeGroups'] as List<Object?>;
        final pngGroup = groups.single as Map<Object?, Object?>;
        expect(pngGroup['extensions'], ['png']);
        expect(pngGroup['mimeTypes'], ['image/png']);
      },
    );

    test(
      'cancelling the save dialog creates no file and reports cancellation',
      () async {
        messenger.setMockMethodCallHandler(selectorChannel, (call) async {
          selectorCalls.add(call);
          return null;
        });
        await expectLater(
          saveGalleryImage(png, fileName: '取消保存.png'),
          throwsA(
            isA<ImageExportException>()
                .having((e) => e.code, 'code', 'cancelled')
                .having((e) => e.message, 'message', '已取消保存。'),
          ),
        );
        expect(await temporary.list().toList(), isEmpty);
        expect(selectorCalls.single.method, 'getSavePath');
        expect(calls, isEmpty);
      },
    );

    test('an actual write error returns a readable failure without reporting success', () async {
      selectedPath = '${temporary.path}/不存在的目录/不能保存.png';
      await expectLater(
        saveGalleryImage(png, fileName: '不能保存.png'),
        throwsA(
          isA<ImageExportException>()
              .having((e) => e.code, 'code', 'save_failed')
              .having((e) => e.message, 'message', '图片保存失败，请检查目标位置与可用空间后重试。'),
        ),
      );
      expect(await File(selectedPath).exists(), isFalse);
      expect(await temporary.list().toList(), isEmpty);
      expect(selectorCalls.single.method, 'getSavePath');
      expect(calls, isEmpty);
    });
  });
}

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
}

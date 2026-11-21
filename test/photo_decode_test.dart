import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:moink_app/app/photo_decode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List photo(int width, int height) {
    final image = img.Image(width: width, height: height, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(44, 122, 210, 255));
    return Uint8List.fromList(img.encodePng(image));
  }

  Future<void> expectImageSize(
    Uint8List bytes,
    int width,
    int height, {
    int maxDimension = 2400,
  }) async {
    final image = await decodePhoto(bytes, maxDimension: maxDimension);
    try {
      expect(image.width, width);
      expect(image.height, height);
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(pixels, isNotNull);
      // The returned image remains alive after all decoder handles are freed.
      final center = ((height ~/ 2) * width + width ~/ 2) * 4;
      expect(pixels!.buffer.asUint8List().sublist(center, center + 4), [
        44,
        122,
        210,
        255,
      ]);
    } finally {
      image.dispose();
    }
  }

  test(
    'extremely tall photos are bounded by height without width upsampling',
    () async {
      await expectImageSize(photo(80, 8000), 24, 2400);
    },
  );

  test('extremely wide photos are bounded by width', () async {
    await expectImageSize(photo(8000, 80), 2400, 24);
  });

  test(
    'small photos retain native dimensions instead of being upsampled',
    () async {
      await expectImageSize(photo(40, 30), 40, 30);
      await expectImageSize(photo(20, 100), 20, 100);
    },
  );

  test(
    'custom limits preserve aspect ratio within one rounding pixel',
    () async {
      await expectImageSize(photo(321, 201), 100, 63, maxDimension: 100);
      await expectImageSize(photo(201, 321), 63, 100, maxDimension: 100);
    },
  );

  test('a one-pixel-wide photo never rounds its short side to zero', () async {
    await expectImageSize(photo(1, 3000), 1, 2400);
  });

  test(
    'corrupt and empty images fail and do not prevent a later valid decode',
    () async {
      await expectLater(
        decodePhoto(Uint8List.fromList([1, 3, 7, 9])),
        throwsA(anything),
      );
      await expectLater(decodePhoto(Uint8List(0)), throwsA(anything));
      await expectImageSize(photo(12, 10), 12, 10);
    },
  );

  test(
    'invalid dimension limits fail before trying to decode the image',
    () async {
      await expectLater(
        decodePhoto(Uint8List(0), maxDimension: 0),
        throwsArgumentError,
      );
      await expectLater(
        decodePhoto(Uint8List(0), maxDimension: -3),
        throwsArgumentError,
      );
    },
  );
}

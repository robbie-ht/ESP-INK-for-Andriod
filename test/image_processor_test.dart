import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:esp_ink/app/image_processor.dart';
import 'package:esp_ink/app/models.dart';
import 'package:esp_ink/core/frame_codec.dart';
import 'package:esp_ink/core/image_filters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List rgbaFor(int width, int height, int color) {
    final rgba = Uint8List(width * height * 4), p = devicePalette[color];
    for (var i = 0; i < width * height; i++) {
      rgba.setRange(i * 4, i * 4 + 4, [...p, 255]);
    }
    return rgba;
  }

  void expectPngMatchesCodes(
    Uint8List png,
    Uint8List codes,
    int width,
    int height,
  ) {
    final preview = img.decodePng(png)!;
    expect(preview.width, width);
    expect(preview.height, height);
    for (var i = 0; i < codes.length; i++) {
      final p = preview.getPixel(i % width, i ~/ width),
          c = devicePalette[codes[i]];
      if (p.r != c[0] || p.g != c[1] || p.b != c[2]) {
        fail('Preview and transmitted image disagree at pixel $i');
      }
    }
  }

  test(
    'pure four pigments retain upright positions in PNG and wire roundtrip',
    () {
      const width = 4, height = 2;
      final rgba = Uint8List(width * height * 4);
      const expected = [0, 1, 2, 3, 3, 0, 1, 2];
      for (var i = 0; i < expected.length; i++) {
        rgba.setRange(i * 4, i * 4 + 4, [...devicePalette[expected[i]], 255]);
      }
      final converted = quantizeArtwork({
        'rgba': rgba,
        'width': width,
        'height': height,
      });
      final codes = unpack2bpp(
        converted['packed']!,
        width: width,
        height: height,
      );
      expect(codes, expected);
      expectPngMatchesCodes(converted['png']!, codes, width, height);
      expect(
        packedToPng(converted['packed']!, width, height),
        converted['png'],
      );
    },
  );

  test(
    'only content rectangle is filtered, white padding is never dithered',
    () {
      const width = 12, height = 8;
      final converted = quantizeArtwork({
        'rgba': rgbaFor(width, height, 1),
        'width': width,
        'height': height,
        'filterImage': true,
        'left': 2,
        'top': 2,
        'right': 10,
        'bottom': 6,
        'options': <String, Object>{
          'mode': 'naive',
          'contrast': -100.0,
          'autoLevels': false,
          'sharpen': 0.0,
          'dither': 'none',
        },
      });
      final codes = unpack2bpp(
        converted['packed']!,
        width: width,
        height: height,
      );
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          expect(
            codes[y * width + x],
            x >= 2 && x < 10 && y >= 2 && y < 6 ? 0 : 1,
          );
        }
      }
      expectPngMatchesCodes(converted['png']!, codes, width, height);
    },
  );

  test('model defaults match every reference algorithm default', () {
    expect(filterOptions(const ImageAdjustments()), imageFilterDefaults);
    expect(
      filterOptions(
        const ImageAdjustments(colorSpace: ColorSpaceMode.linear),
      )['space'],
      'linear',
    );
  });

  test('invalid geometry fails before packing', () {
    expect(() => quantizeArtwork({'rgba': Uint8List(20)}), throwsArgumentError);
    expect(
      () => quantizeArtwork({
        'rgba': rgbaFor(4, 2, 1),
        'width': 4,
        'height': 2,
        'filterImage': true,
        'left': -1,
      }),
      throwsArgumentError,
    );
  });

  test(
    'note background and empty photo bypass all image adjustments',
    () async {
      const adjustments = ImageAdjustments(
        brightness: -100,
        contrast: -100,
        style: ImageStyle.adaptive,
        warmCast: 1,
        ditherStrength: 1.5,
      );
      final note = await processArtwork(
        const ComposerDraft(
          kind: CompositionKind.note,
          background: 2,
          textEnabled: false,
          adjustments: adjustments,
        ),
      );
      expect(unpack2bpp(note.packed), everyElement(2));
      final empty = await processArtwork(
        const ComposerDraft(textEnabled: false, adjustments: adjustments),
      );
      expect(unpack2bpp(empty.packed), everyElement(1));
    },
  );

  test(
    'text overlays the quantized photo and never enters the color filter',
    () async {
      final source = img.Image(width: 16, height: 16);
      img.fill(source, color: img.ColorRgb8(255, 255, 255));
      final sourcePng = Uint8List.fromList(img.encodePng(source));
      const text = TextLayer(
        id: 'layer',
        text: 'TEXT',
        color: 3,
        size: 120,
        bold: true,
      );
      const adjustments = ImageAdjustments(
        style: ImageStyle.naive,
        contrast: -100,
        autoLevels: false,
        sharpen: 0,
        dither: DitherMode.none,
      );
      // Every photo pixel becomes black. Filtering the text together with the
      // photo would also turn its red pixels black, violating this comparison.
      final photo = await processArtwork(
        ComposerDraft(
          photoBytes: sourcePng,
          photoTexts: const [text],
          adjustments: adjustments,
        ),
      );
      final note = await processArtwork(
        const ComposerDraft(
          kind: CompositionKind.note,
          background: 0,
          noteTexts: [text],
        ),
      );
      final codes = unpack2bpp(photo.packed);
      expect(codes.where((c) => c == 3).length, greaterThan(100));
      expect(photo.packed, orderedEquals(note.packed));
      expectPngMatchesCodes(photo.png, codes, frameWidth, frameHeight);
    },
  );
}

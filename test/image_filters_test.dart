import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:esp_ink/core/image_filters.dart';

void main() {
  final fixture = jsonDecode(
    File('test/image_filter_vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final width = fixture['width'] as int, height = fixture['height'] as int;
  final input = Float64List.fromList(
    (fixture['rgb'] as List).map((v) => (v as num).toDouble()).toList(),
  );
  for (final (index, raw) in (fixture['vectors'] as List).indexed) {
    final vector = raw as Map<String, dynamic>;
    final options = Map<String, Object>.from(vector['options'] as Map);
    test(
      'JS reference $index: ${options['mode']}/${options['dither']}/${options['space']}/${options['castRamp'] ?? 'default'}',
      () {
        final snapshot = Float64List.fromList(input);
        final mapped = warmMap(input, width, height, options);
        expect(
          input,
          orderedEquals(snapshot),
          reason: 'Do not mutate the frame snapshot',
        );
        if (vector.containsKey('mapped')) {
          final expected = vector['mapped'] as List;
          for (var i = 0; i < mapped.length; i++) {
            expect(
              mapped[i],
              closeTo((expected[i] as num).toDouble(), 1e-8),
              reason: 'Mapped channel $i',
            );
          }
        }
        expect(
          quantize(mapped, width, height, options).join(),
          vector['codes'],
        );
      },
    );
  }
  test('pure device colors survive direct sRGB snapping', () {
    for (var i = 0; i < 4; i++) {
      final p = devicePalette[i];
      expect(snapPalette(p[0], p[1], p[2]), i);
    }
    expect(snapPalette(128, 128, 128), 1);
  });
  test('zero diffusion strength equals no dither for all kernels', () {
    final mapped = warmMap(input, width, height);
    final expected = quantize(mapped, width, height, {'dither': 'none'});
    for (final mode in [
      'fs',
      'stucki',
      'jarvis',
      'burkes',
      'sierra',
      'atkinson',
      'bayer',
    ]) {
      expect(
        quantize(mapped, width, height, {
          'dither': mode,
          'ditherStrength': 0.0,
        }),
        orderedEquals(expected),
      );
    }
  });
  test('levels leaves flat fields alone and maps endpoint values', () {
    final flat = Float64List.fromList(List.filled(24, 85.0));
    autoLevels(flat);
    expect(flat, everyElement(85.0));
    final gradient = Float64List.fromList([30, 30, 30, 210, 210, 210]);
    autoLevels(gradient);
    expect(gradient, [18, 18, 18, 246, 246, 246]);
  });
  test('invalid dimensions and filter values fail explicitly', () {
    expect(() => warmMap(input, 0, height), throwsArgumentError);
    expect(() => quantize(input, width + 1, height), throwsArgumentError);
    expect(
      () => warmMap(input, width, height, {'gamma': double.nan}),
      throwsArgumentError,
    );
    expect(
      () => warmMap(input, width, height, {'dither': 'unknown'}),
      throwsArgumentError,
    );
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:esp_ink/app/models.dart';

void main() {
  test('photo and note retain separate text layers and advanced settings', () {
    final draft = ComposerDraft(
      kind: CompositionKind.note,
      mirror: true,
      rotation: 17,
      zoom: 1.5,
      adjustments: const ImageAdjustments(
        style: ImageStyle.adaptive,
        dither: DitherMode.jarvis,
        colorSpace: ColorSpaceMode.linear,
        brightness: 18,
        sharpen: .6,
      ),
      photoTexts: const [TextLayer(id: 'photo-1', text: '照片文字', color: 3)],
      noteTexts: const [
        TextLayer(
          id: 'note-1',
          text: '便签文字',
          font: TextFont.serif,
          background: 2,
          stroke: 2,
        ),
      ],
      paddingEnabled: true,
      padTop: 24,
      padBottom: 80,
    );
    final restored = ComposerDraft.fromJson(
      jsonDecode(jsonEncode(draft.toJson())) as Map<String, dynamic>,
    );
    expect(restored.kind, CompositionKind.note);
    expect(restored.textLayers.single.text, '便签文字');
    expect(
      restored.copyWith(kind: CompositionKind.photo).textLayers.single.text,
      '照片文字',
    );
    expect(restored.adjustments.dither, DitherMode.jarvis);
    expect(restored.adjustments.sharpen, .6);
    expect(restored.mirror, isTrue);
    expect(restored.rotation, 17);
    expect(restored.padBottom, 80);
  });
  test(
    'transparent text background can be restored without changing pigment',
    () {
      const layer = TextLayer(id: 'text', color: 3, background: 0);
      expect(layer.copyWith(clearBackground: true).background, isNull);
      expect(layer.copyWith(clearBackground: true).color, 3);
    },
  );
  test('local initial settings match the current board preset without overwriting hardware', () {
    const settings = SettingsView();
    expect(settings.gpioPreset, 2);
    expect(settings.pins, [0, 1, 4, 3, 5, 6, 7, 10]);
    expect(settings.panel, 0);
  });
}

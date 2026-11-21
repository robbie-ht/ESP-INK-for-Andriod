import 'package:flutter/material.dart';

import '../app/artwork.dart';
import '../app/controller.dart';
import '../app/models.dart';
import 'components.dart';
import 'ink_effect_editor.dart';
import 'photo_crop_editor.dart';

const styleLabels = {
  ImageStyle.natural: '自然暖调',
  ImageStyle.adaptive: '全面暖色',
  ImageStyle.gray: '灰度',
  ImageStyle.naive: '原色直出',
};
const fontLabels = {
  TextFont.sans: '黑体',
  TextFont.serif: '宋体',
  TextFont.mono: '等宽',
};
const ditherLabels = {
  DitherMode.fs: 'Floyd–Steinberg',
  DitherMode.stucki: 'Stucki',
  DitherMode.jarvis: 'Jarvis',
  DitherMode.burkes: 'Burkes',
  DitherMode.sierra: 'Sierra Lite',
  DitherMode.atkinson: 'Atkinson',
  DitherMode.bayer: 'Bayer 8 × 8',
  DitherMode.none: '无抖动',
};

class ValueSlider extends StatelessWidget {
  const ValueSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.percentage = false,
    this.decimals = 0,
    this.suffix = '',
    this.divisions,
  });
  final String label, suffix;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  final bool percentage;
  final int decimals;
  final int? divisions;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 13),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
            Text(
              '${(percentage ? value * 100 : value).toStringAsFixed(decimals)}${percentage ? '%' : suffix}',
              style: const TextStyle(fontSize: 11, color: mutedText),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    ),
  );
}

class PaletteSelector extends StatelessWidget {
  const PaletteSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.transparent = false,
  });
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool transparent;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 9,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      if (transparent)
        ChoiceChip(
          label: const Text('透明', style: TextStyle(fontSize: 11)),
          selected: value == null,
          onSelected: (_) => onChanged(null),
        ),
      for (final index in [0, 1, 2, 3])
        Tooltip(
          message: const ['黑', '白', '黄', '红'][index],
          child: Semantics(
            button: true,
            selected: value == index,
            label: const ['黑色', '白色', '黄色', '红色'][index],
            child: InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: () => onChanged(index),
              child: Container(
                width: 37,
                height: 37,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: value == index
                        ? const Color(0xFF1967D2)
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: artPalette[index],
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFD3D9E2)),
                  ),
                  child: value == index
                      ? Icon(
                          Icons.check_rounded,
                          size: 17,
                          color: index == 0 ? Colors.white : Colors.black,
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

Future<void> _sheet(
  BuildContext context,
  MoinkController c,
  String title,
  List<Widget> Function(BuildContext) body,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .9,
        ),
        child: SingleChildScrollView(
          key: PageStorageKey<String>('composer-settings-scroll-$title'),
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('完成'),
                  ),
                ],
              ),
              const SizedBox(height: 17),
              ...body(context),
            ],
          ),
        ),
      ),
    ),
  ),
);

Future<void> showPhotoGeometrySheet(BuildContext context, MoinkController c) =>
    showPhotoCropEditor(context, c);

double _snap(double value) {
  final near = (value / 90).round() * 90.0;
  return (value - near).abs() <= 3 ? near : value;
}

Future<void> showPaddingSheet(BuildContext context, MoinkController c) =>
    _sheet(context, c, '照片留白', (context) {
      final d = c.draft;
      return [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('开启白色边框', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '四边可独立设置，0 表示不留白',
            style: TextStyle(fontSize: 11),
          ),
          value: d.paddingEnabled,
          onChanged: (v) => c.updateDraft(d.copyWith(paddingEnabled: v)),
        ),
        if (d.paddingEnabled) ...[
          ValueSlider(
            label: '上边',
            value: d.padTop,
            min: 0,
            max: 246,
            suffix: ' px',
            onChanged: (v) => c.updateDraft(d.copyWith(padTop: v)),
          ),
          ValueSlider(
            label: '下边',
            value: d.padBottom,
            min: 0,
            max: 246,
            suffix: ' px',
            onChanged: (v) => c.updateDraft(d.copyWith(padBottom: v)),
          ),
          ValueSlider(
            label: '左边',
            value: d.padLeft,
            min: 0,
            max: 300,
            suffix: ' px',
            onChanged: (v) => c.updateDraft(d.copyWith(padLeft: v)),
          ),
          ValueSlider(
            label: '右边',
            value: d.padRight,
            min: 0,
            max: 300,
            suffix: ' px',
            onChanged: (v) => c.updateDraft(d.copyWith(padRight: v)),
          ),
          TextButton(
            onPressed: () => c.updateDraft(
              d.copyWith(padTop: 32, padBottom: 64, padLeft: 32, padRight: 32),
            ),
            child: const Text('恢复拍立得留白'),
          ),
        ],
      ];
    });

Future<void> showImageSettingsSheet(
  BuildContext context,
  MoinkController c,
) => showInkEffectEditor(
  context,
  c,
  controlsBuilder: (context) {
    final a = c.draft.adjustments;
    void update(ImageAdjustments value) =>
        c.updateDraft(c.draft.copyWith(adjustments: value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '滑动调整，效果会自动更新。文字保持纯四色。',
          style: TextStyle(fontSize: 12, color: mutedText),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 7,
          runSpacing: 5,
          children: [
            for (final style in ImageStyle.values)
              ChoiceChip(
                label: Text(styleLabels[style]!),
                selected: a.style == style,
                onSelected: (_) => update(a.copyWith(style: style)),
              ),
          ],
        ),
        if (a.style == ImageStyle.natural || a.style == ImageStyle.adaptive)
          ValueSlider(
            label: a.style == ImageStyle.natural ? '色彩强度' : '暖色浓度',
            value: a.style == ImageStyle.natural ? a.warmBoost : a.warmCast,
            min: 0,
            max: 1,
            percentage: true,
            onChanged: (value) => update(
              a.style == ImageStyle.natural
                  ? a.copyWith(warmBoost: value)
                  : a.copyWith(warmCast: value),
            ),
          ),
        const SizedBox(height: 20),
        DropdownButtonFormField<DitherMode>(
          initialValue: a.dither,
          decoration: const InputDecoration(labelText: '抖动算法'),
          items: DitherMode.values
              .map(
                (m) =>
                    DropdownMenuItem(value: m, child: Text(ditherLabels[m]!)),
              )
              .toList(),
          onChanged: (v) {
            if (v != null) update(a.copyWith(dither: v));
          },
        ),
        ValueSlider(
          label: '抖动强度',
          value: a.ditherStrength,
          min: 0,
          max: 1,
          percentage: true,
          onChanged: (v) => update(a.copyWith(ditherStrength: v)),
        ),
        DropdownButtonFormField<ColorSpaceMode>(
          initialValue: a.colorSpace,
          decoration: const InputDecoration(labelText: '色域'),
          items: const [
            DropdownMenuItem(value: ColorSpaceMode.standard, child: Text('标准')),
            DropdownMenuItem(value: ColorSpaceMode.linear, child: Text('线性光')),
            DropdownMenuItem(value: ColorSpaceMode.srgb, child: Text('sRGB')),
          ],
          onChanged: (v) {
            if (v != null) update(a.copyWith(colorSpace: v));
          },
        ),
        const SizedBox(height: 7),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动色阶', style: TextStyle(fontSize: 14)),
          value: a.autoLevels,
          onChanged: (v) => update(a.copyWith(autoLevels: v)),
        ),
        ValueSlider(
          label: '亮度',
          value: a.brightness,
          min: -100,
          max: 100,
          onChanged: (v) => update(a.copyWith(brightness: v)),
        ),
        ValueSlider(
          label: '对比度',
          value: a.contrast,
          min: -100,
          max: 100,
          onChanged: (v) => update(a.copyWith(contrast: v)),
        ),
        ValueSlider(
          label: '饱和度',
          value: a.saturation,
          min: 0,
          max: 2,
          percentage: true,
          onChanged: (v) => update(a.copyWith(saturation: v)),
        ),
        ValueSlider(
          label: '伽马',
          value: a.gamma,
          min: .2,
          max: 3,
          decimals: 2,
          onChanged: (v) => update(a.copyWith(gamma: v)),
        ),
        ValueSlider(
          label: '锐化',
          value: a.sharpen,
          min: 0,
          max: 1,
          percentage: true,
          onChanged: (v) => update(a.copyWith(sharpen: v)),
        ),
        ExpansionTile(
          key: const PageStorageKey<String>('photo-warm-expansion'),
          tilePadding: EdgeInsets.zero,
          shape: const Border(),
          title: const Text('暖色精细调节', style: TextStyle(fontSize: 14)),
          children: [
            ValueSlider(
              label: '暖色中心',
              value: a.warmCenter,
              min: 0,
              max: 360,
              suffix: '°',
              onChanged: (v) => update(a.copyWith(warmCenter: v)),
            ),
            ValueSlider(
              label: '暖色跨度',
              value: a.warmSpan,
              min: 1,
              max: 180,
              suffix: '°',
              onChanged: (v) => update(a.copyWith(warmSpan: v)),
            ),
            ValueSlider(
              label: '冷色抑制',
              value: a.coolPull,
              min: 0,
              max: 1,
              percentage: true,
              onChanged: (v) => update(a.copyWith(coolPull: v)),
            ),
            ValueSlider(
              label: '冷色限制角度',
              value: a.coolCap,
              min: 0,
              max: 180,
              suffix: '°',
              onChanged: (v) => update(a.copyWith(coolCap: v)),
            ),
            ValueSlider(
              label: '冷色去饱和',
              value: a.coolDesat,
              min: 0,
              max: 1,
              percentage: true,
              onChanged: (v) => update(a.copyWith(coolDesat: v)),
            ),
            ValueSlider(
              label: '暖色吸引',
              value: a.warmPull,
              min: 0,
              max: 1,
              percentage: true,
              onChanged: (v) => update(a.copyWith(warmPull: v)),
            ),
            ValueSlider(
              label: '暖色吸引范围',
              value: a.warmPullCap,
              min: 0,
              max: 90,
              suffix: '°',
              onChanged: (v) => update(a.copyWith(warmPullCap: v)),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: a.castRamp,
              decoration: const InputDecoration(labelText: '暖色映射'),
              items: const [
                DropdownMenuItem(value: 'sunset', child: Text('落日')),
                DropdownMenuItem(value: 'ember', child: Text('余烬')),
                DropdownMenuItem(value: 'duotone', child: Text('双色')),
                DropdownMenuItem(value: 'sepia', child: Text('复古')),
              ],
              onChanged: (v) {
                if (v != null) update(a.copyWith(castRamp: v));
              },
            ),
            const SizedBox(height: 18),
          ],
        ),
        const SizedBox(height: 14),
        OutlinedButton(
          onPressed: () => update(const ImageAdjustments()),
          child: const Text('恢复默认图像参数'),
        ),
      ],
    );
  },
);

Future<TextLayer?> showTextEditorSheet(
  BuildContext context,
  TextLayer? initial,
) async {
  var value =
      initial ??
      TextLayer(id: 'text-${DateTime.now().microsecondsSinceEpoch}', text: '');
  final form = GlobalKey<FormState>();
  return showModalBottomSheet<TextLayer>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void update(TextLayer layer) => setState(() => value = layer);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .92,
            ),
            child: SingleChildScrollView(
              key: PageStorageKey<String>('text-editor-scroll-${value.id}'),
              padding: EdgeInsets.fromLTRB(
                24,
                0,
                24,
                28 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          initial == null ? '添加文字' : '编辑文字',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Form(
                    key: form,
                    child: TextFormField(
                      key: const ValueKey('layer-text-input'),
                      initialValue: value.text,
                      minLines: 2,
                      maxLines: 5,
                      maxLength: 400,
                      decoration: const InputDecoration(
                        labelText: '想写下的话',
                        hintText: '输入文字，支持换行',
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? '请先输入文字' : null,
                      onChanged: (v) => value = value.copyWith(text: v),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<TextFont>(
                          initialValue: value.font,
                          decoration: const InputDecoration(labelText: '字体'),
                          items: TextFont.values
                              .map(
                                (f) => DropdownMenuItem(
                                  value: f,
                                  child: Text(
                                    fontLabels[f]!,
                                    style: TextStyle(
                                      fontFamily: textFontFamily(f),
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) update(value.copyWith(font: v));
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilterChip(
                        label: const Text('加粗'),
                        selected: value.bold,
                        onSelected: (v) => update(value.copyWith(bold: v)),
                      ),
                    ],
                  ),
                  ValueSlider(
                    label: '字号',
                    value: value.size,
                    min: 16,
                    max: 220,
                    suffix: ' px',
                    onChanged: (v) => update(value.copyWith(size: v)),
                  ),
                  const Text('文字颜色', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 9),
                  PaletteSelector(
                    value: value.color,
                    onChanged: (v) => update(value.copyWith(color: v)),
                  ),
                  const SizedBox(height: 20),
                  const Text('文字底色', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 9),
                  PaletteSelector(
                    value: value.background,
                    transparent: true,
                    onChanged: (v) => update(
                      value.copyWith(background: v, clearBackground: v == null),
                    ),
                  ),
                  ValueSlider(
                    label: '文字方向',
                    value: value.rotation,
                    min: -180,
                    max: 180,
                    divisions: 360,
                    suffix: '°',
                    onChanged: (v) =>
                        update(value.copyWith(rotation: _snap(v))),
                  ),
                  ExpansionTile(
                    key: const PageStorageKey<String>(
                      'text-position-expansion',
                    ),
                    tilePadding: EdgeInsets.zero,
                    shape: const Border(),
                    title: const Text(
                      '位置、换行与描边',
                      style: TextStyle(fontSize: 14),
                    ),
                    children: [
                      ValueSlider(
                        label: '水平位置 X',
                        value: value.x,
                        min: 0,
                        max: 768,
                        suffix: ' px',
                        onChanged: (v) => update(value.copyWith(x: v)),
                      ),
                      ValueSlider(
                        label: '垂直位置 Y',
                        value: value.y,
                        min: 0,
                        max: 552,
                        suffix: ' px',
                        onChanged: (v) => update(value.copyWith(y: v)),
                      ),
                      ValueSlider(
                        label: '文字框宽度',
                        value: value.wrap,
                        min: 24,
                        max: 768,
                        suffix: ' px',
                        onChanged: (v) => update(value.copyWith(wrap: v)),
                      ),
                      ValueSlider(
                        label: '描边宽度',
                        value: value.stroke,
                        min: 0,
                        max: 8,
                        suffix: ' px',
                        onChanged: (v) => update(value.copyWith(stroke: v)),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: PaletteSelector(
                          value: value.strokeColor,
                          onChanged: (v) =>
                              update(value.copyWith(strokeColor: v)),
                        ),
                      ),
                      const SizedBox(height: 18),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      if (form.currentState!.validate()) {
                        Navigator.pop(context, value);
                      }
                    },
                    child: Text(initial == null ? '添加到画面' : '应用文字修改'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

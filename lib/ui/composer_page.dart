import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/artwork.dart';
import '../app/controller.dart';
import '../app/models.dart';
import 'components.dart';
import 'composer_settings.dart';
import 'sheets.dart';
import 'source_artwork_canvas.dart';

class ComposerPage extends StatefulWidget {
  const ComposerPage({super.key, required this.c});
  final MoinkController c;
  @override
  State<ComposerPage> createState() => _ComposerPageState();
}

class _ComposerPageState extends State<ComposerPage> {
  MoinkController get c => widget.c;
  String? selectedId;
  bool inkPreview = false;
  ComposerDraft? gestureDraft;
  TextLayer? gestureText;
  Offset? gestureStart;
  void change(ComposerDraft draft) => c.updateDraft(draft);
  TextLayer? get selected =>
      c.draft.textLayers.where((e) => e.id == selectedId).firstOrNull;
  void setLayers(List<TextLayer> layers) => change(
    c.draft.kind == CompositionKind.photo
        ? c.draft.copyWith(photoTexts: layers)
        : c.draft.copyWith(noteTexts: layers),
  );
  void updateLayer(TextLayer value) => setLayers(
    c.draft.textLayers.map((e) => e.id == value.id ? value : e).toList(),
  );
  void removeLayer(String id) {
    setLayers(c.draft.textLayers.where((e) => e.id != id).toList());
    setState(() => selectedId = null);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 820;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '让喜欢的，留在日常。',
            style: wide
                ? Theme.of(context).textTheme.headlineLarge
                : Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 9),
          const Text(
            '一张照片，几句心事。你的墨印，由你来写。',
            style: TextStyle(color: mutedText),
          ),
          const SizedBox(height: 25),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 6, child: _preview(context)),
                const SizedBox(width: 24),
                Expanded(flex: 4, child: _editor(context)),
              ],
            )
          else ...[
            _preview(context),
            const SizedBox(height: 20),
            _editor(context),
          ],
          const SizedBox(height: 26),
        ],
      );
    },
  );

  Widget _preview(BuildContext context) {
    final emptyPhoto =
        c.draft.kind == CompositionKind.photo && c.draft.photoBytes == null;
    return Column(
      children: [
        SectionCard(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.crop_original_rounded,
                    size: 19,
                    color: mutedText,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '画面预览',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (c.rendering)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const SizedBox(width: 7),
                  const Text(
                    '768 × 552',
                    style: TextStyle(color: mutedText, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  key: const ValueKey('preview-mode'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: false,
                      icon: const Icon(Icons.photo_outlined, size: 17),
                      label: Text(
                        c.draft.kind == CompositionKind.photo ? '原图' : '画面',
                      ),
                    ),
                    const ButtonSegment(
                      value: true,
                      icon: Icon(Icons.grid_on_outlined, size: 17),
                      label: Text('墨水屏效果'),
                    ),
                  ],
                  selected: {inkPreview},
                  onSelectionChanged: (value) {
                    setState(() {
                      inkPreview = value.first;
                      selectedId = null;
                    });
                    c.setInkPreviewActive(inkPreview);
                  },
                ),
              ),
              if (inkPreview) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    key: const ValueKey('open-ink-effect-editor'),
                    onPressed: () => showImageSettingsSheet(context, c),
                    icon: const Icon(Icons.tune_rounded, size: 17),
                    label: const Text('边看效果边调整'),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Container(
                key: const ValueKey('composition-preview-frame'),
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEEDE8),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E1DB)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x10000000),
                      blurRadius: 18,
                      offset: Offset(0, 7),
                    ),
                  ],
                ),
                child: AspectRatio(
                  aspectRatio: 768 / 552,
                  child: emptyPhoto
                      ? Material(
                          color: Colors.white,
                          child: InkWell(
                            onTap: c.pickPhoto,
                            child: LayoutBuilder(
                              builder: (context, box) => Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.add_photo_alternate_outlined,
                                    color: const Color(0xFF8BA7CC),
                                    size: box.maxWidth < 320 ? 35 : 48,
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    '选择一张照片',
                                    style: TextStyle(
                                      color: Color(0xFF46658B),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (box.maxWidth > 340) ...[
                                    const SizedBox(height: 6),
                                    const Text(
                                      '把生活里的喜欢，放到墨水屏上',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: mutedText,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        )
                      : _interactiveCanvas(),
                ),
              ),
              const SizedBox(height: 21),
              Row(
                children: [
                  const InkDots(size: 10, spacing: 6),
                  const SizedBox(width: 3),
                  const Expanded(
                    child: Text(
                      '黑 · 白 · 黄 · 红',
                      style: TextStyle(fontSize: 11, color: mutedText),
                    ),
                  ),
                  Text(
                    c.draft.kind == CompositionKind.photo ? '拍立得' : '便签',
                    style: const TextStyle(fontSize: 11, color: mutedText),
                  ),
                ],
              ),
              if (!emptyPhoto && c.draft.kind == CompositionKind.photo)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey('open-photo-crop'),
                    onPressed: () => showPhotoGeometrySheet(context, c),
                    icon: const Icon(Icons.crop_rotate_rounded, size: 17),
                    label: const Text('全屏裁切与旋转'),
                  ),
                ),
              if (!emptyPhoto && inkPreview && !c.previewReady) ...[
                const SizedBox(height: 10),
                Text(
                  c.rendering
                      ? !c.hasInkPreview
                            ? '正在生成效果，当前仍显示原图'
                            : '正在自动更新效果'
                      : '参数已调整，效果将自动更新',
                  style: const TextStyle(fontSize: 11, color: mutedText),
                ),
              ],
              if (!emptyPhoto) ...[
                const SizedBox(height: 13),
                Text(
                  selected != null
                      ? '已选文字 · 拖动可调整位置'
                      : c.draft.kind == CompositionKind.photo
                      ? inkPreview && c.previewReady
                            ? '墨水屏效果预览 · 裁切请切回原图'
                            : '轻点照片，全屏调整大小与旋转'
                      : '点选画面中的文字，拖动调整位置',
                  style: const TextStyle(fontSize: 11, color: mutedText),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 17),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: (c.busy && !c.galleryReading) || emptyPhoto
                ? null
                : () => showSendSheet(context, c),
            icon: Icon(
              c.connected || c.demo
                  ? Icons.send_rounded
                  : Icons.bluetooth_rounded,
              size: 18,
            ),
            label: Text(
              c.demo
                  ? '演示发送'
                  : c.connected
                  ? '发送到墨水屏'
                  : '连接设备并发送',
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '实屏效果随屏幕与环境光略有不同。',
          style: TextStyle(fontSize: 11, color: mutedText),
        ),
      ],
    );
  }

  TextLayer? hit(Offset logical) {
    if (!c.draft.textEnabled) return null;
    for (final layer in c.draft.textLayers.reversed) {
      final delta = logical - Offset(layer.x, layer.y);
      final angle = -layer.rotation * math.pi / 180;
      final local = Offset(
        delta.dx * math.cos(angle) - delta.dy * math.sin(angle),
        delta.dx * math.sin(angle) + delta.dy * math.cos(angle),
      );
      if (textLayerBounds(layer).inflate(12).contains(local)) return layer;
    }
    return null;
  }

  Widget _interactiveCanvas() => LayoutBuilder(
    builder: (context, box) {
      final scale = box.maxWidth / 768;
      final showingDevice = inkPreview && c.hasInkPreview;
      final editTextGesture = selected != null && !showingDevice;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: showingDevice
            ? null
            : (e) {
                final layer = hit(e.localPosition / scale);
                final hadSelection = selected != null;
                setState(() => selectedId = layer?.id);
                if (layer == null &&
                    !hadSelection &&
                    c.draft.kind == CompositionKind.photo) {
                  unawaited(showPhotoGeometrySheet(context, c));
                }
              },
        onDoubleTap: selected == null || showingDevice
            ? null
            : () => _editText(selected),
        onScaleStart: !editTextGesture
            ? null
            : (e) {
                gestureDraft = c.draft;
                gestureStart = e.localFocalPoint / scale;
                gestureText = hit(gestureStart!);
                setState(() => selectedId = gestureText?.id);
              },
        onScaleUpdate: !editTextGesture
            ? null
            : (e) {
                final start = gestureDraft;
                final origin = gestureStart;
                if (start == null || origin == null) return;
                final delta = e.localFocalPoint / scale - origin;
                if (gestureText != null) {
                  final t = gestureText!;
                  updateLayer(
                    t.copyWith(
                      x: (t.x + delta.dx).clamp(0, 768),
                      y: (t.y + delta.dy).clamp(0, 552),
                      size: (t.size * e.scale).clamp(16, 220),
                      rotation: (t.rotation + e.rotation * 180 / math.pi).clamp(
                        -180,
                        180,
                      ),
                    ),
                  );
                }
              },
        onScaleEnd: !editTextGesture
            ? null
            : (_) {
                gestureDraft = null;
                gestureText = null;
                gestureStart = null;
              },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showingDevice)
              Image.memory(
                c.previewPng!,
                key: const ValueKey('device-preview-image'),
                fit: BoxFit.fill,
                gaplessPlayback: true,
              )
            else
              SourceArtworkCanvas(draft: c.draft, onReselect: c.pickPhoto),
            if (selected != null && c.draft.textEnabled && !showingDevice)
              IgnorePointer(
                child: CustomPaint(painter: _SelectionPainter(selected!)),
              ),
          ],
        ),
      );
    },
  );

  Widget _editor(BuildContext context) => SectionCard(
    color: sectionFill,
    padding: const EdgeInsets.all(22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('开始创作', subtitle: '照片和文字，都可以自由摆放'),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<CompositionKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: CompositionKind.photo,
                icon: Icon(Icons.photo_camera_outlined, size: 18),
                label: Text('拍立得'),
              ),
              ButtonSegment(
                value: CompositionKind.note,
                icon: Icon(Icons.sticky_note_2_outlined, size: 18),
                label: Text('便签'),
              ),
            ],
            selected: {c.draft.kind},
            onSelectionChanged: (v) {
              setState(() => selectedId = null);
              change(c.draft.copyWith(kind: v.first, textEnabled: true));
            },
          ),
        ),
        const SizedBox(height: 22),
        if (c.draft.kind == CompositionKind.photo)
          ..._photoControls(context)
        else ...[
          const SectionTitle('便签底色'),
          const SizedBox(height: 12),
          PaletteSelector(
            value: c.draft.background,
            onChanged: (v) => change(c.draft.copyWith(background: v)),
          ),
          const SizedBox(height: 20),
        ],
        const Divider(),
        const SizedBox(height: 10),
        _textControls(context),
      ],
    ),
  );

  List<Widget> _photoControls(BuildContext context) => [
    SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: c.pickPhoto,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: Text(c.draft.photoBytes == null ? '从相册选择照片' : '更换照片'),
      ),
    ),
    const SizedBox(height: 18),
    const SectionTitle('照片风格', subtitle: '只影响照片，不改变叠加文字'),
    const SizedBox(height: 10),
    Wrap(
      spacing: 7,
      runSpacing: 5,
      children: ImageStyle.values
          .map(
            (style) => ChoiceChip(
              label: Text(
                styleLabels[style]!,
                style: const TextStyle(fontSize: 12),
              ),
              selected: c.draft.adjustments.style == style,
              onSelected: (_) => change(
                c.draft.copyWith(
                  adjustments: c.draft.adjustments.copyWith(style: style),
                ),
              ),
            ),
          )
          .toList(),
    ),
    if (c.draft.adjustments.style == ImageStyle.natural ||
        c.draft.adjustments.style == ImageStyle.adaptive)
      ValueSlider(
        label: c.draft.adjustments.style == ImageStyle.natural
            ? '色彩强度'
            : '暖色浓度',
        value: c.draft.adjustments.style == ImageStyle.natural
            ? c.draft.adjustments.warmBoost
            : c.draft.adjustments.warmCast,
        min: 0,
        max: 1,
        percentage: true,
        onChanged: (v) => change(
          c.draft.copyWith(
            adjustments: c.draft.adjustments.style == ImageStyle.natural
                ? c.draft.adjustments.copyWith(warmBoost: v)
                : c.draft.adjustments.copyWith(warmCast: v),
          ),
        ),
      ),
    const SizedBox(height: 5),
    _editRow(
      Icons.crop_rotate_rounded,
      '裁剪与位置',
      '全屏原图 · 双指缩放、旋转、裁切',
      () => showPhotoGeometrySheet(context, c),
    ),
    _editRow(
      Icons.tune_rounded,
      '图像调整',
      '固定预览 · 自动更新效果',
      () => showImageSettingsSheet(context, c),
    ),
    _editRow(
      Icons.border_outer_rounded,
      '照片留白',
      c.draft.paddingEnabled ? '已开启 · 四边独立调整' : '为文字留一点空间',
      () => showPaddingSheet(context, c),
    ),
    const SizedBox(height: 12),
  ];

  Widget _editRow(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback tap,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: const Color(0xFF57759C), size: 22),
    title: Text(
      title,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
    ),
    subtitle: Text(
      subtitle,
      style: const TextStyle(fontSize: 11, color: mutedText),
    ),
    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
    onTap: tap,
  );

  Widget _textControls(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionTitle(
        '画面上的文字',
        subtitle: '${c.draft.textLayers.length} 个文字对象',
        trailing: IconButton.filledTonal(
          tooltip: '添加文字',
          onPressed: () => _editText(null),
          icon: const Icon(Icons.add_rounded, size: 20),
        ),
      ),
      if (c.draft.kind == CompositionKind.photo &&
          c.draft.textLayers.isNotEmpty)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('显示叠加文字', style: TextStyle(fontSize: 12)),
          value: c.draft.textEnabled,
          onChanged: (v) => change(c.draft.copyWith(textEnabled: v)),
        ),
      if (c.draft.textLayers.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Text(
            c.draft.kind == CompositionKind.note
                ? '从一句想写下的话开始。'
                : '给照片加上一句文字，或一个日期。',
            style: const TextStyle(fontSize: 12, color: mutedText),
          ),
        ),
      ...c.draft.textLayers.map(
        (t) => Padding(
          padding: const EdgeInsets.only(top: 9),
          child: Material(
            color: t.id == selectedId ? const Color(0xFFDFEAFE) : Colors.white,
            borderRadius: BorderRadius.circular(15),
            child: ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 13, right: 4),
              leading: Icon(
                Icons.text_fields_rounded,
                size: 20,
                color: t.id == selectedId ? const Color(0xFF1967D2) : mutedText,
              ),
              title: Text(
                t.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                '${fontLabels[t.font]} · ${t.size.round()} px',
                style: const TextStyle(fontSize: 10, color: mutedText),
              ),
              onTap: () => setState(() => selectedId = t.id),
              trailing: IconButton(
                tooltip: '编辑文字',
                onPressed: () => _editText(t),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
            ),
          ),
        ),
      ),
      if (selected != null)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => removeLayer(selectedId!),
            icon: const Icon(Icons.delete_outline_rounded, size: 17),
            label: const Text('删除选中文字', style: TextStyle(fontSize: 11)),
          ),
        ),
    ],
  );

  Future<void> _editText(TextLayer? old) async {
    final result = await showTextEditorSheet(context, old);
    if (result == null || !mounted) return;
    if (old == null) {
      setLayers([...c.draft.textLayers, result]);
    } else {
      updateLayer(result);
    }
    if (!c.draft.textEnabled) change(c.draft.copyWith(textEnabled: true));
    setState(() => selectedId = result.id);
  }
}

class _SelectionPainter extends CustomPainter {
  const _SelectionPainter(this.layer);
  final TextLayer layer;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 768, size.height / 552);
    canvas.translate(layer.x, layer.y);
    canvas.rotate(layer.rotation * math.pi / 180);
    final rect = textLayerBounds(layer).inflate(4);
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFF1967D2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (final p in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawCircle(p, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
        p,
        5,
        Paint()
          ..color = const Color(0xFF1967D2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => old.layer != layer;
}

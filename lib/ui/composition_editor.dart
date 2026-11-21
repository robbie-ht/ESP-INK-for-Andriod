import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/artwork.dart';
import '../app/controller.dart';
import '../app/models.dart';
import 'components.dart';
import 'composer_settings.dart';
import 'ink_effect_editor.dart';
import 'source_artwork_canvas.dart';

Future<void> showCompositionEditor(
  BuildContext context,
  EspInkController controller,
) async {
  controller.setInkPreviewActive(true);
  try {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _CompositionEditor(
          key: const ValueKey('composition-editor'),
          controller: controller,
        ),
      ),
    );
  } finally {
    controller.setInkPreviewActive(false);
  }
}

class _CompositionEditor extends StatefulWidget {
  const _CompositionEditor({super.key, required this.controller});
  final EspInkController controller;

  @override
  State<_CompositionEditor> createState() => _CompositionEditorState();
}

class _CompositionEditorState extends State<_CompositionEditor> {
  EspInkController get c => widget.controller;
  String? _selectedId;
  bool _inkPreview = true;
  bool _picking = false;
  ComposerDraft? _gestureDraft;
  TextLayer? _gestureText;
  Offset? _gestureStart;

  TextLayer? get _selected =>
      c.draft.textLayers.where((text) => text.id == _selectedId).firstOrNull;
  bool get _emptyPhoto =>
      c.draft.kind == CompositionKind.photo && c.draft.photoBytes == null;

  void _change(ComposerDraft value) => c.updateDraft(value);

  void _setMode(bool inkPreview) {
    setState(() {
      _inkPreview = inkPreview;
      if (inkPreview) _selectedId = null;
    });
    c.setInkPreviewActive(inkPreview);
  }

  void _setLayers(List<TextLayer> layers) => _change(
    c.draft.kind == CompositionKind.photo
        ? c.draft.copyWith(photoTexts: layers)
        : c.draft.copyWith(noteTexts: layers),
  );

  void _updateLayer(TextLayer layer) => _setLayers([
    for (final text in c.draft.textLayers) text.id == layer.id ? layer : text,
  ]);

  void _selectText(TextLayer layer) {
    setState(() {
      _selectedId = layer.id;
      _inkPreview = false;
    });
    c.setInkPreviewActive(false);
  }

  Future<void> _pickPhoto() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picked = await c.pickPhoto();
      if (!mounted || !picked) return;
      setState(() => _selectedId = null);
      c.setInkPreviewActive(_inkPreview);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _editText(TextLayer? old) async {
    final result = await showTextEditorSheet(context, old);
    if (!mounted || result == null) return;
    if (old == null) {
      _setLayers([...c.draft.textLayers, result]);
    } else {
      _updateLayer(result);
    }
    if (!c.draft.textEnabled) {
      _change(c.draft.copyWith(textEnabled: true));
    }
    _selectText(result);
  }

  @override
  Widget build(BuildContext context) => InkEffectEditor(
    controller: c,
    title: '调整图片',
    canExit: !_picking,
    previewBuilder: _preview,
    controlsBuilder: _controls,
  );

  Widget _preview(BuildContext context) => Padding(
    key: const ValueKey('ink-effect-fixed-preview'),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
    child: Column(
      children: [
        SegmentedButton<bool>(
          key: const ValueKey('preview-mode'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: false,
              icon: const Icon(Icons.photo_outlined, size: 17),
              label: Text(c.draft.kind == CompositionKind.photo ? '原图' : '画面'),
            ),
            const ButtonSegment(
              value: true,
              icon: Icon(Icons.grid_on_outlined, size: 17),
              label: Text('墨水屏效果'),
            ),
          ],
          selected: {_inkPreview},
          onSelectionChanged: (value) => _setMode(value.first),
        ),
        const SizedBox(height: 9),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 768 / 552,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFDCE2EA)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _emptyPhoto
                      ? Center(
                          child: TextButton.icon(
                            onPressed: _picking ? null : _pickPhoto,
                            icon: const Icon(
                              Icons.add_photo_alternate_outlined,
                            ),
                            label: Text(_picking ? '正在选择照片' : '选择照片'),
                          ),
                        )
                      : _interactiveCanvas(),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!_emptyPhoto && _inkPreview && !c.previewReady)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                _inkPreview
                    ? Icons.check_circle_outline
                    : Icons.touch_app_outlined,
                size: 14,
                color: mutedText,
              ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                _emptyPhoto
                    ? '选择照片后开始调整'
                    : !_inkPreview
                    ? _selected != null
                          ? '拖动、双指缩放旋转文字 · 双击编辑'
                          : '原图实时预览 · 轻点文字可选中'
                    : c.previewReady
                    ? '效果已更新 · 调整后自动刷新'
                    : c.rendering
                    ? '正在自动更新效果'
                    : '正在准备最新效果',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: mutedText, fontSize: 11),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  TextLayer? _hit(Offset logical) {
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
      final showingDevice = _inkPreview && c.hasInkPreview;
      final editTextGesture = _selected != null && !_inkPreview;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (event) {
          final layer = _hit(event.localPosition / scale);
          if (layer != null) {
            _selectText(layer);
            return;
          }
          final hadSelection = _selected != null;
          setState(() => _selectedId = null);
          if (!_inkPreview &&
              !hadSelection &&
              c.draft.kind == CompositionKind.photo) {
            unawaited(showPhotoGeometrySheet(context, c));
          }
        },
        onDoubleTap: _selected == null || _inkPreview
            ? null
            : () => _editText(_selected),
        onScaleStart: !editTextGesture
            ? null
            : (event) {
                _gestureDraft = c.draft;
                _gestureStart = event.localFocalPoint / scale;
                _gestureText = _hit(_gestureStart!);
                setState(() => _selectedId = _gestureText?.id);
              },
        onScaleUpdate: !editTextGesture
            ? null
            : (event) {
                final start = _gestureDraft;
                final origin = _gestureStart;
                final text = _gestureText;
                if (start == null || origin == null || text == null) return;
                final delta = event.localFocalPoint / scale - origin;
                _updateLayer(
                  text.copyWith(
                    x: (text.x + delta.dx).clamp(0, 768),
                    y: (text.y + delta.dy).clamp(0, 552),
                    size: (text.size * event.scale).clamp(16, 220),
                    rotation: (text.rotation + event.rotation * 180 / math.pi)
                        .clamp(-180, 180),
                  ),
                );
              },
        onScaleEnd: !editTextGesture
            ? null
            : (_) {
                _gestureDraft = null;
                _gestureText = null;
                _gestureStart = null;
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
              SourceArtworkCanvas(draft: c.draft, onReselect: _pickPhoto),
            if (_selected != null && c.draft.textEnabled && !_inkPreview)
              IgnorePointer(
                child: CustomPaint(painter: _SelectionPainter(_selected!)),
              ),
          ],
        ),
      );
    },
  );

  Widget _controls(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SegmentedButton<CompositionKind>(
        key: const ValueKey('composition-kind'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: CompositionKind.photo,
            icon: Icon(Icons.photo_camera_outlined, size: 17),
            label: Text('拍立得'),
          ),
          ButtonSegment(
            value: CompositionKind.note,
            icon: Icon(Icons.sticky_note_2_outlined, size: 17),
            label: Text('便签'),
          ),
        ],
        selected: {c.draft.kind},
        onSelectionChanged: (value) {
          setState(() => _selectedId = null);
          _change(c.draft.copyWith(kind: value.first, textEnabled: true));
        },
      ),
      const SizedBox(height: 18),
      if (c.draft.kind == CompositionKind.photo) ...[
        OutlinedButton.icon(
          key: const ValueKey('composition-pick-photo'),
          onPressed: _picking ? null : _pickPhoto,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: Text(
            _picking
                ? '正在选择照片'
                : _emptyPhoto
                ? '从相册选择照片'
                : '更换照片',
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('open-photo-crop'),
          onPressed: _emptyPhoto
              ? null
              : () => showPhotoGeometrySheet(context, c),
          icon: const Icon(Icons.crop_rotate_rounded),
          label: const Text('裁切与旋转'),
        ),
        _paddingControls(),
      ] else ...[
        const SectionTitle('便签底色'),
        const SizedBox(height: 12),
        PaletteSelector(
          value: c.draft.background,
          onChanged: (value) => _change(c.draft.copyWith(background: value)),
        ),
        const SizedBox(height: 16),
      ],
      const Divider(),
      const SizedBox(height: 10),
      _textControls(),
      if (c.draft.kind == CompositionKind.photo) ...[
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 15),
        const SectionTitle('图像调整', subtitle: '只改变照片，叠加文字保持纯四色'),
        const SizedBox(height: 12),
        ImageAdjustmentControls(controller: c),
      ],
    ],
  );

  Widget _paddingControls() => ExpansionTile(
    key: const PageStorageKey('composition-padding'),
    tilePadding: EdgeInsets.zero,
    shape: const Border(),
    title: const Text('照片留白', style: TextStyle(fontSize: 14)),
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('开启白色边框', style: TextStyle(fontSize: 13)),
        value: c.draft.paddingEnabled,
        onChanged: (value) => _change(c.draft.copyWith(paddingEnabled: value)),
      ),
      if (c.draft.paddingEnabled) ...[
        ValueSlider(
          label: '上边',
          value: c.draft.padTop,
          min: 0,
          max: 246,
          suffix: ' px',
          onChanged: (value) => _change(c.draft.copyWith(padTop: value)),
        ),
        ValueSlider(
          label: '下边',
          value: c.draft.padBottom,
          min: 0,
          max: 246,
          suffix: ' px',
          onChanged: (value) => _change(c.draft.copyWith(padBottom: value)),
        ),
        ValueSlider(
          label: '左边',
          value: c.draft.padLeft,
          min: 0,
          max: 300,
          suffix: ' px',
          onChanged: (value) => _change(c.draft.copyWith(padLeft: value)),
        ),
        ValueSlider(
          label: '右边',
          value: c.draft.padRight,
          min: 0,
          max: 300,
          suffix: ' px',
          onChanged: (value) => _change(c.draft.copyWith(padRight: value)),
        ),
        TextButton(
          onPressed: () => _change(
            c.draft.copyWith(
              padTop: 32,
              padBottom: 64,
              padLeft: 32,
              padRight: 32,
            ),
          ),
          child: const Text('恢复拍立得留白'),
        ),
      ],
    ],
  );

  Widget _textControls() => Column(
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
          onChanged: (value) => _change(c.draft.copyWith(textEnabled: value)),
        ),
      if (c.draft.textLayers.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            c.draft.kind == CompositionKind.note
                ? '从一句想写下的话开始。'
                : '给照片加上一句文字，或一个日期。',
            style: const TextStyle(fontSize: 12, color: mutedText),
          ),
        ),
      for (final text in c.draft.textLayers)
        Padding(
          padding: const EdgeInsets.only(top: 9),
          child: Material(
            color: text.id == _selectedId
                ? const Color(0xFFDFEAFE)
                : Colors.white,
            borderRadius: BorderRadius.circular(15),
            child: ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 13, right: 4),
              leading: const Icon(Icons.text_fields_rounded, size: 20),
              title: Text(
                text.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                '${fontLabels[text.font]} · ${text.size.round()} px',
                style: const TextStyle(fontSize: 10, color: mutedText),
              ),
              onTap: () => _selectText(text),
              trailing: IconButton(
                tooltip: '编辑文字',
                onPressed: () => _editText(text),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
            ),
          ),
        ),
      if (_selected != null)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () {
              _setLayers(
                c.draft.textLayers
                    .where((text) => text.id != _selectedId)
                    .toList(),
              );
              setState(() => _selectedId = null);
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 17),
            label: const Text('删除选中文字', style: TextStyle(fontSize: 11)),
          ),
        ),
    ],
  );
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
    for (final point in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawCircle(point, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
        point,
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

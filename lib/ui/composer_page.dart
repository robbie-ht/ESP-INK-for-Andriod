import 'dart:async';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/models.dart';
import 'components.dart';
import 'composition_editor.dart';
import 'sheets.dart';
import 'source_artwork_canvas.dart';

/// Page A: one selection/result area, then adjust and send. The system picker
/// is page B; all composition editing lives in the full-screen page C.
class ComposerPage extends StatefulWidget {
  const ComposerPage({super.key, required this.c});
  final EspInkController c;

  @override
  State<ComposerPage> createState() => _ComposerPageState();
}

class _ComposerPageState extends State<ComposerPage> {
  EspInkController get c => widget.c;
  bool _photoFlowActive = false;
  bool _recoveryScheduled = false;
  bool get _operationBlocked => c.busy && !c.galleryReading;
  bool get _emptyPhoto =>
      c.draft.kind == CompositionKind.photo && c.draft.photoBytes == null;

  @override
  void initState() {
    super.initState();
    c.addListener(_controllerChanged);
    _scheduleRecoveredPhoto();
  }

  @override
  void didUpdateWidget(ComposerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.c != c) {
      oldWidget.c.removeListener(_controllerChanged);
      c.addListener(_controllerChanged);
    }
    _scheduleRecoveredPhoto();
  }

  @override
  void dispose() {
    c.removeListener(_controllerChanged);
    super.dispose();
  }

  void _controllerChanged() => _scheduleRecoveredPhoto();

  void _scheduleRecoveredPhoto() {
    if (!mounted ||
        _recoveryScheduled ||
        _photoFlowActive ||
        c.tabIndex != 0 ||
        !c.recoveredPhotoNeedsAdjustment) {
      return;
    }
    _recoveryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recoveryScheduled = false;
      if (!mounted ||
          _photoFlowActive ||
          c.tabIndex != 0 ||
          ModalRoute.of(context)?.isCurrent == false ||
          !c.recoveredPhotoNeedsAdjustment) {
        return;
      }
      unawaited(_adjustPhoto(recovered: true));
    });
  }

  bool _canContinue(EspInkController controller) =>
      mounted &&
      identical(controller, c) &&
      c.tabIndex == 0 &&
      ModalRoute.of(context)?.isCurrent != false;

  Future<void> _selectPhoto() async {
    if (_photoFlowActive || _operationBlocked) return;
    final controller = c;
    setState(() => _photoFlowActive = true);
    try {
      final selected = await controller.pickPhoto();
      if (!selected ||
          !_canContinue(controller) ||
          controller.draft.kind != CompositionKind.photo ||
          controller.draft.photoBytes == null) {
        return;
      }
      await _showEditor(controller);
    } finally {
      if (mounted) setState(() => _photoFlowActive = false);
      _scheduleRecoveredPhoto();
    }
  }

  Future<void> _adjustPhoto({bool recovered = false}) async {
    if (_photoFlowActive || _operationBlocked) return;
    final controller = c;
    setState(() => _photoFlowActive = true);
    try {
      if (recovered && !controller.consumeRecoveredPhotoAdjustment()) return;
      await _showEditor(controller);
    } finally {
      if (mounted) setState(() => _photoFlowActive = false);
      _scheduleRecoveredPhoto();
    }
  }

  Future<void> _showEditor(EspInkController controller) async {
    await showCompositionEditor(context, controller);
    if (!_canContinue(controller)) return;
    // Complete the last edit even if Done was tapped inside the debounce
    // window. This is one explicit result, not a hidden live subscription.
    if (controller.draft.kind == CompositionKind.note ||
        controller.draft.photoBytes != null) {
      unawaited(controller.renderPreview());
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _photoFlowActive || _operationBlocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('让喜欢的，留在日常。', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 9),
        const Text('选择照片，调整好后发送到墨水屏。', style: TextStyle(color: mutedText)),
        const SizedBox(height: 25),
        SectionCard(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.crop_original_rounded, size: 19, color: mutedText),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '画面预览',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '768 × 552',
                    style: TextStyle(color: mutedText, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Semantics(
                button: true,
                label: _emptyPhoto ? '选择照片' : '选择或更换照片',
                child: InkWell(
                  key: const ValueKey('select-photo'),
                  onTap: locked ? null : _selectPhoto,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    key: const ValueKey('composition-preview-frame'),
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEEEDE8),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E1DB)),
                    ),
                    child: AspectRatio(
                      aspectRatio: 768 / 552,
                      child: _emptyPhoto
                          ? _emptySelection()
                          : c.hasInkPreview
                          ? Image.memory(
                              c.previewPng!,
                              key: const ValueKey('composition-result-image'),
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            )
                          : IgnorePointer(
                              child: SourceArtworkCanvas(
                                draft: c.draft,
                                onReselect: _selectPhoto,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Row(
                children: [
                  InkDots(size: 10, spacing: 6),
                  SizedBox(width: 3),
                  Expanded(
                    child: Text(
                      '黑 · 白 · 黄 · 红',
                      style: TextStyle(fontSize: 11, color: mutedText),
                    ),
                  ),
                ],
              ),
              if (!_emptyPhoto) ...[
                const SizedBox(height: 10),
                Text(
                  c.rendering
                      ? '正在完成效果…'
                      : c.hasInkPreview && !c.previewReady
                      ? '效果尚未更新，点调整图片检查'
                      : c.draft.kind == CompositionKind.note
                      ? '便签画面 · 点调整图片继续编辑'
                      : '轻点画面可重新选择照片',
                  style: const TextStyle(fontSize: 11, color: mutedText),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('adjust-photo'),
                onPressed: locked ? null : _adjustPhoto,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('调整图片'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('send-photo'),
                onPressed: locked || _emptyPhoto
                    ? null
                    : () => showSendSheet(context, c),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: Text(c.demo ? '演示发送' : '发送图片'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          '实屏效果随屏幕与环境光略有不同。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: mutedText),
        ),
        const SizedBox(height: 26),
      ],
    );
  }

  Widget _emptySelection() => ColoredBox(
    color: Colors.white,
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
          Text(
            _photoFlowActive ? '正在打开相册…' : '选择一张照片',
            style: const TextStyle(
              color: Color(0xFF46658B),
              fontWeight: FontWeight.w500,
            ),
          ),
          if (box.maxWidth > 340) ...[
            const SizedBox(height: 6),
            const Text(
              '把生活里的喜欢，放到墨水屏上',
              style: TextStyle(fontSize: 11, color: mutedText),
            ),
          ],
        ],
      ),
    ),
  );
}

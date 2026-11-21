import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/models.dart';
import 'components.dart';
import 'source_artwork_canvas.dart';

Future<void> showInkEffectEditor(
  BuildContext context,
  MoinkController controller, {
  required WidgetBuilder controlsBuilder,
}) async {
  final previous = controller.inkPreviewActive;
  controller.setInkPreviewActive(true);
  try {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _InkEffectEditor(
          controller: controller,
          controlsBuilder: controlsBuilder,
        ),
      ),
    );
  } finally {
    controller.setInkPreviewActive(previous && controller.tabIndex == 0);
  }
}

class _InkEffectEditor extends StatelessWidget {
  const _InkEffectEditor({
    required this.controller,
    required this.controlsBuilder,
  });

  final MoinkController controller;
  final WidgetBuilder controlsBuilder;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('墨水屏效果'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => LayoutBuilder(
          builder: (context, box) {
            final controls = SingleChildScrollView(
              key: const PageStorageKey('ink-effect-controls'),
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 32),
              child: controlsBuilder(context),
            );
            if (box.maxWidth >= 720) {
              return Row(
                key: const ValueKey('ink-effect-side-layout'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _preview(context)),
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: math.min(420, box.maxWidth * .46),
                    child: controls,
                  ),
                ],
              );
            }
            return Column(
              key: const ValueKey('ink-effect-stacked-layout'),
              children: [
                SizedBox(
                  height: math.min(330, box.maxHeight * .42),
                  child: _preview(context),
                ),
                const Divider(height: 1),
                Expanded(child: controls),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _preview(BuildContext context) {
    final c = controller;
    final empty =
        c.draft.kind == CompositionKind.photo && c.draft.photoBytes == null;
    return Padding(
      key: const ValueKey('ink-effect-fixed-preview'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        children: [
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
                    child: empty
                        ? Center(
                            child: TextButton.icon(
                              onPressed: c.pickPhoto,
                              icon: const Icon(
                                Icons.add_photo_alternate_outlined,
                              ),
                              label: const Text('选择照片'),
                            ),
                          )
                        : c.hasInkPreview
                        ? Image.memory(
                            c.previewPng!,
                            key: const ValueKey('ink-effect-image'),
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          )
                        : SourceArtworkCanvas(draft: c.draft),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!empty && !c.previewReady)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  empty ? Icons.photo_outlined : Icons.check_circle_outline,
                  size: 15,
                  color: mutedText,
                ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  empty
                      ? '选好照片后即可查看效果'
                      : c.previewReady
                      ? '效果已更新 · 调整后自动刷新'
                      : c.rendering
                      ? '正在更新效果'
                      : '调整已保存，正在准备效果',
                  style: const TextStyle(color: mutedText, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

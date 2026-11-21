import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app/artwork.dart';
import '../app/models.dart';
import '../app/photo_decode.dart';

/// The live composition is always painted from the decoded source photograph.
/// A completed device PNG is deliberately never consumed by this widget.
class SourceArtworkCanvas extends StatefulWidget {
  const SourceArtworkCanvas({super.key, required this.draft, this.onReselect});
  final ComposerDraft draft;
  final VoidCallback? onReselect;

  @override
  State<SourceArtworkCanvas> createState() => _SourceArtworkCanvasState();
}

class _SourceArtworkCanvasState extends State<SourceArtworkCanvas> {
  ui.Image? _photo;
  bool _loading = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(SourceArtworkCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.draft.photoBytes, widget.draft.photoBytes)) {
      _decode();
    }
  }

  Future<void> _decode() async {
    final generation = ++_generation;
    final bytes = widget.draft.photoBytes;
    _photo?.dispose();
    _photo = null;
    _error = null;
    _loading = bytes != null;
    if (bytes == null) return;
    try {
      final image = await decodePhoto(bytes);
      if (!mounted || generation != _generation) {
        image.dispose();
        return;
      }
      setState(() {
        _photo = image;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '无法读取这张照片，请重新选择';
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _photo?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.draft.kind == CompositionKind.photo) {
      if (_loading) {
        return const ColoredBox(
          color: Color(0xFFF0F3F8),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(height: 12),
                Text('正在打开原图', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        );
      }
      if (_error != null) {
        return ColoredBox(
          color: const Color(0xFFF0F3F8),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.broken_image_outlined, size: 30),
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (widget.onReselect != null)
                    TextButton(
                      onPressed: widget.onReselect,
                      child: const Text('重新选图'),
                    ),
                ],
              ),
            ),
          ),
        );
      }
    }
    return RepaintBoundary(
      child: CustomPaint(
        key: const ValueKey('live-source-paint'),
        painter: PaperArtPainter(widget.draft, photo: _photo),
      ),
    );
  }
}

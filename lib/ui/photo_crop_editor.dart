import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app/artwork.dart';
import '../app/controller.dart';
import '../app/models.dart';
import '../app/photo_decode.dart';
import '../app/photo_geometry.dart';

/// The editor keeps a private draft. No color conversion runs while composing.
Future<void> showPhotoCropEditor(
  BuildContext context,
  MoinkController controller,
) async {
  final result = await Navigator.of(context).push<ComposerDraft>(
    MaterialPageRoute<ComposerDraft>(
      fullscreenDialog: true,
      builder: (_) => PhotoCropEditor(draft: controller.draft),
    ),
  );
  if (result != null) controller.updateDraft(result);
}

class PhotoCropEditor extends StatefulWidget {
  const PhotoCropEditor({super.key, required this.draft});

  final ComposerDraft draft;

  @override
  State<PhotoCropEditor> createState() => _PhotoCropEditorState();
}

class _PhotoCropEditorState extends State<PhotoCropEditor> {
  late ComposerDraft _draft;
  ui.Image? _image;
  String? _error;
  bool _loading = false;
  int _decodeGeneration = 0;
  Rect? _cropRect;
  Rect _targetRect = Rect.zero;
  Size _stageSize = Size.zero;
  ComposerDraft? _gestureDraft;
  Rect? _gestureRect;
  Offset? _gestureAnchor;
  int? _handle;
  bool _interacting = false;

  Size get _imageSize =>
      Size(_image?.width.toDouble() ?? 1, _image?.height.toDouble() ?? 1);
  Rect get _activeRect => _cropRect ?? _targetRect;

  @override
  void initState() {
    super.initState();
    _draft = _canonical(widget.draft);
    _decode();
  }

  Future<void> _decode() async {
    final bytes = widget.draft.photoBytes;
    if (bytes == null) return;
    final generation = ++_decodeGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    ui.Image? decoded;
    try {
      decoded = await decodePhoto(bytes);
      if (!mounted || generation != _decodeGeneration) {
        decoded.dispose();
        return;
      }
      _image?.dispose();
      setState(() {
        _image = decoded;
        _loading = false;
        if (!_targetRect.isEmpty) _draft = _normalize(_draft);
      });
    } catch (_) {
      decoded?.dispose();
      if (!mounted || generation != _decodeGeneration) return;
      setState(() {
        _loading = false;
        _error = '这张照片暂时无法打开，请返回后重新选择。';
      });
    }
  }

  @override
  void dispose() {
    _decodeGeneration++;
    _image?.dispose();
    super.dispose();
  }

  ComposerDraft _canonical(ComposerDraft d) {
    var turns = d.quarterTurns % 4;
    var rotation = d.rotation.isFinite ? d.rotation % 360 : 0.0;
    while (rotation > 45) {
      rotation -= 90;
      turns++;
    }
    while (rotation < -45) {
      rotation += 90;
      turns--;
    }
    return d.copyWith(
      quarterTurns: ((turns % 4) + 4) % 4,
      rotation: rotation,
      zoom: d.zoom.isFinite ? d.zoom.clamp(photoMinZoom, photoMaxZoom) : 1,
    );
  }

  ComposerDraft _normalize(ComposerDraft d) => _canonical(
    normalizePhotoDraft(
      draft: d,
      imageSize: _imageSize,
      targetRect: _activeRect,
    ),
  );

  void _setDraft(ComposerDraft d) {
    if (_image == null || _activeRect.isEmpty) return;
    setState(() => _draft = _normalize(d));
  }

  void _zoom(double value) => _setDraft(
    transformPhotoDraft(
      draft: _draft,
      imageSize: _imageSize,
      targetRect: _activeRect,
      anchor: _activeRect.center,
      focalPoint: _activeRect.center,
      scaleFactor: value / _draft.zoom,
    ),
  );

  void _rotation(double value) => _setDraft(
    transformPhotoDraft(
      draft: _draft,
      imageSize: _imageSize,
      targetRect: _activeRect,
      anchor: _activeRect.center,
      focalPoint: _activeRect.center,
      rotationDelta: (value - _draft.rotation) * math.pi / 180,
    ),
  );

  void _reset() => _setDraft(
    _draft.copyWith(
      fit: ImageFitMode.cover,
      quarterTurns: 0,
      rotation: 0,
      mirror: false,
      zoom: 1,
      offsetX: 0,
      offsetY: 0,
    ),
  );

  List<Offset> _corners(Rect r) => [
    r.topLeft,
    r.topRight,
    r.bottomRight,
    r.bottomLeft,
  ];

  void _start(ScaleStartDetails details) {
    if (_image == null) return;
    final corners = _corners(_activeRect);
    int? selected;
    for (var i = 0; i < corners.length; i++) {
      if ((corners[i] - details.localFocalPoint).distance < 30) {
        selected = i;
        break;
      }
    }
    setState(() {
      _gestureDraft = _draft;
      _gestureRect = _activeRect;
      _gestureAnchor = details.localFocalPoint;
      _handle = selected;
      _interacting = true;
    });
  }

  void _update(ScaleUpdateDetails details) {
    final start = _gestureDraft;
    final rect = _gestureRect;
    final anchor = _gestureAnchor;
    if (start == null || rect == null || anchor == null) return;
    if (_handle != null && details.pointerCount == 1) {
      final index = _handle!;
      final points = _corners(rect);
      final fixed = points[(index + 2) % 4];
      final moving = points[index] + details.localFocalPoint - anchor;
      final xSign = index == 0 || index == 3 ? -1.0 : 1.0;
      final ySign = index < 2 ? -1.0 : 1.0;
      final aspect = rect.width / rect.height;
      final dx = (moving.dx - fixed.dx) * xSign;
      final dy = (moving.dy - fixed.dy) * ySign;
      final wantedHeight = (dx * aspect + dy) / (aspect * aspect + 1);
      final roomX = xSign < 0
          ? fixed.dx - 18
          : _stageSize.width - 18 - fixed.dx;
      final roomY = ySign < 0
          ? fixed.dy - 18
          : _stageSize.height - 18 - fixed.dy;
      final maxHeight = math.max(30.0, math.min(roomY, roomX / aspect));
      final minHeight = math.min(
        maxHeight,
        math.max(
          math.max(72.0, 72 / aspect),
          rect.height * start.zoom / photoMaxZoom,
        ),
      );
      final height = wantedHeight.clamp(minHeight, maxHeight);
      final next = Rect.fromPoints(
        fixed,
        fixed + Offset(xSign * height * aspect, ySign * height),
      );
      setState(() {
        _draft = _canonical(
          resizePhotoCrop(
            draft: start,
            imageSize: _imageSize,
            oldRect: rect,
            newRect: next,
          ),
        );
        _cropRect = next;
      });
      return;
    }
    setState(() {
      _draft = _canonical(
        transformPhotoDraft(
          draft: start,
          imageSize: _imageSize,
          targetRect: rect,
          anchor: anchor,
          focalPoint: details.localFocalPoint,
          scaleFactor: details.scale,
          rotationDelta: details.rotation,
        ),
      );
    });
  }

  void _end(ScaleEndDetails _) => setState(() {
    _cropRect = null;
    _gestureDraft = null;
    _gestureRect = null;
    _gestureAnchor = null;
    _handle = null;
    _interacting = false;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canEdit = _image != null;
    return Theme(
      data: theme.copyWith(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFA8C7FA),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF111418),
        textTheme: theme.textTheme.apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
        primaryTextTheme: theme.primaryTextTheme.apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF111418),
          foregroundColor: Colors.white,
          leading: IconButton(
            tooltip: '取消裁剪',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
          title: const Text('裁剪照片', style: TextStyle(fontSize: 19)),
          actions: [
            TextButton(
              onPressed: canEdit ? _reset : null,
              child: const Text('重置'),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                key: const Key('crop-apply'),
                onPressed: canEdit
                    ? () => Navigator.pop(context, _normalize(_draft))
                    : null,
                child: const Text('应用'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >= 850 ||
                  constraints.maxWidth > constraints.maxHeight * 1.35;
              final controls = _controls(canEdit);
              if (wide) {
                return Row(
                  children: [
                    Expanded(child: _workspace()),
                    SizedBox(
                      width: math.min(340, constraints.maxWidth * .42),
                      child: ColoredBox(
                        color: const Color(0xFF1C2026),
                        child: SingleChildScrollView(child: controls),
                      ),
                    ),
                  ],
                );
              }
              final controlHeight = math.min(
                304.0,
                constraints.maxHeight * .45,
              );
              return Column(
                children: [
                  Expanded(child: _workspace()),
                  SizedBox(
                    height: controlHeight,
                    width: double.infinity,
                    child: ColoredBox(
                      color: const Color(0xFF1C2026),
                      child: SingleChildScrollView(child: controls),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _workspace() => LayoutBuilder(
    builder: (context, constraints) {
      _stageSize = constraints.biggest;
      final sourceRect = photoContentRect(_draft);
      final scale = math.min(
        math.max(1, constraints.maxWidth - 48) / sourceRect.width,
        math.max(1, constraints.maxHeight - 76) / sourceRect.height,
      );
      _targetRect = Rect.fromCenter(
        center: Offset(constraints.maxWidth / 2, constraints.maxHeight / 2),
        width: sourceRect.width * scale,
        height: sourceRect.height * scale,
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          if (_image != null)
            GestureDetector(
              key: const Key('crop-workspace'),
              behavior: HitTestBehavior.opaque,
              onScaleStart: _start,
              onScaleUpdate: _update,
              onScaleEnd: _end,
              onDoubleTap: _reset,
              child: CustomPaint(
                painter: _CropPainter(
                  image: _image!,
                  draft: _draft,
                  cropRect: _activeRect,
                  interacting: _interacting,
                ),
              ),
            )
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_loading)
                      const CircularProgressIndicator()
                    else
                      Icon(
                        _error != null
                            ? Icons.broken_image_outlined
                            : Icons.add_photo_alternate_outlined,
                        color: const Color(0xFFBBC5D3),
                        size: 42,
                      ),
                    const SizedBox(height: 16),
                    Text(
                      _loading ? '正在打开原图…' : _error ?? '请返回并选择一张照片，再调整裁剪。',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFCFD5DF)),
                    ),
                    if (_error != null)
                      TextButton(onPressed: _decode, child: const Text('重试')),
                  ],
                ),
              ),
            ),
          if (_image != null)
            Positioned(
              top: 10,
              left: 16,
              right: 16,
              child: IgnorePointer(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '原图 · 实时调整',
                      style: TextStyle(fontSize: 11, color: Color(0xFFB9C2D0)),
                    ),
                    Text(
                      '${sourceRect.width.round()} × ${sourceRect.height.round()}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFB9C2D0),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _controls(bool enabled) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 15),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '拖动照片 · 双指缩放旋转 · 拖动四角裁剪',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: Color(0xFFBDC6D4)),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _tool(
                '左转 90°',
                Icons.rotate_left_rounded,
                enabled
                    ? () => _setDraft(
                        _draft.copyWith(quarterTurns: _draft.quarterTurns - 1),
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: _tool(
                '右转 90°',
                Icons.rotate_right_rounded,
                enabled
                    ? () => _setDraft(
                        _draft.copyWith(quarterTurns: _draft.quarterTurns + 1),
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: _tool(
                '镜像',
                Icons.flip_rounded,
                enabled
                    ? () => _setDraft(_draft.copyWith(mirror: !_draft.mirror))
                    : null,
                selected: _draft.mirror,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedButton<ImageFitMode>(
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStatePropertyAll(
              TextStyle(fontFamily: 'NotoSansSC', fontSize: 12),
            ),
          ),
          segments: const [
            ButtonSegment(
              value: ImageFitMode.cover,
              icon: Icon(Icons.crop_rounded, size: 18),
              label: Text('铺满画面'),
            ),
            ButtonSegment(
              value: ImageFitMode.contain,
              icon: Icon(Icons.fit_screen_rounded, size: 18),
              label: Text('完整照片'),
            ),
          ],
          selected: {_draft.fit},
          onSelectionChanged: enabled
              ? (selection) => _setDraft(
                  _draft.copyWith(
                    fit: selection.first,
                    zoom: 1,
                    offsetX: 0,
                    offsetY: 0,
                  ),
                )
              : null,
        ),
        const SizedBox(height: 14),
        _slider(
          label: '精细校正',
          display: '${_draft.rotation.toStringAsFixed(1)}°',
          value: _draft.rotation.clamp(-45, 45),
          min: -45,
          max: 45,
          enabled: enabled,
          onChanged: _rotation,
          key: const Key('crop-rotation'),
        ),
        const SizedBox(height: 2),
        _slider(
          label: '缩放',
          display: '${_draft.zoom.toStringAsFixed(2)}×',
          value: _draft.zoom.clamp(1, 8),
          min: 1,
          max: 8,
          enabled: enabled,
          onChanged: _zoom,
          key: const Key('crop-zoom'),
        ),
      ],
    ),
  );

  Widget _tool(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    bool selected = false,
  }) => FilledButton.tonal(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: selected ? const Color(0xFF304A6E) : null,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 19),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    ),
  );

  Widget _slider({
    required String label,
    required String display,
    required double value,
    required double min,
    required double max,
    required bool enabled,
    required ValueChanged<double> onChanged,
    required Key key,
  }) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
          Text(
            display,
            style: const TextStyle(fontSize: 12, color: Color(0xFFA8C7FA)),
          ),
        ],
      ),
      SizedBox(
        height: 38,
        child: Slider(
          key: key,
          value: value,
          min: min,
          max: max,
          onChanged: enabled ? onChanged : null,
          semanticFormatterCallback: (_) => '$label $display',
        ),
      ),
    ],
  );
}

class _CropPainter extends CustomPainter {
  const _CropPainter({
    required this.image,
    required this.draft,
    required this.cropRect,
    required this.interacting,
  });

  final ui.Image image;
  final ComposerDraft draft;
  final Rect cropRect;
  final bool interacting;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawColor(const Color(0xFF111418), BlendMode.src);
    canvas.drawRect(cropRect, Paint()..color = Colors.white);
    paintPhotoGeometry(
      canvas,
      image,
      resolvePhotoGeometry(
        draft: draft,
        imageSize: Size(image.width.toDouble(), image.height.toDouble()),
        targetRect: cropRect,
      ),
      clip: false,
    );
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(cropRect);
    canvas.drawPath(mask, Paint()..color = const Color(0xB8000000));
    final line = Paint()
      ..color = Colors.white.withValues(alpha: interacting ? .7 : .38)
      ..strokeWidth = .7;
    for (var i = 1; i < 3; i++) {
      final x = cropRect.left + cropRect.width * i / 3;
      final y = cropRect.top + cropRect.height * i / 3;
      canvas.drawLine(
        Offset(x, cropRect.top),
        Offset(x, cropRect.bottom),
        line,
      );
      canvas.drawLine(
        Offset(cropRect.left, y),
        Offset(cropRect.right, y),
        line,
      );
    }
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRect(cropRect, border);
    final handle = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square;
    for (final corner in [
      cropRect.topLeft,
      cropRect.topRight,
      cropRect.bottomRight,
      cropRect.bottomLeft,
    ]) {
      final sx = corner.dx == cropRect.left ? 1.0 : -1.0;
      final sy = corner.dy == cropRect.top ? 1.0 : -1.0;
      canvas.drawLine(corner, corner + Offset(sx * 18, 0), handle);
      canvas.drawLine(corner, corner + Offset(0, sy * 18), handle);
    }
    if (interacting) {
      final center = cropRect.center;
      final cross = Paint()
        ..color = const Color(0xFFE2EDFF)
        ..strokeWidth = 1;
      canvas.drawLine(
        center - const Offset(9, 0),
        center + const Offset(9, 0),
        cross,
      );
      canvas.drawLine(
        center - const Offset(0, 9),
        center + const Offset(0, 9),
        cross,
      );
    }
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.draft != draft ||
      oldDelegate.cropRect != cropRect ||
      oldDelegate.interacting != interacting;
}

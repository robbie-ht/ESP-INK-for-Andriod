import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/models.dart';
import '../core/image_export.dart';
import 'components.dart';
import 'sheets.dart';

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key, required this.c});
  final MoinkController c;

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  MoinkController get c => widget.c;
  bool get available => c.connected || c.demo;
  bool get blocked => c.busy && !c.galleryReading;
  String? _preloadedIdentity;

  @override
  void initState() {
    super.initState();
    c.addListener(_controllerChanged);
    _schedulePreload();
  }

  @override
  void didUpdateWidget(GalleryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.c != c) {
      oldWidget.c.removeListener(_controllerChanged);
      c.addListener(_controllerChanged);
      _preloadedIdentity = null;
    }
    _schedulePreload();
  }

  void _controllerChanged() {
    if (!mounted) return;
    setState(() {});
    _schedulePreload();
  }

  void _schedulePreload() {
    if (!available || !c.gallerySupported || c.demo || c.gallery.isEmpty) {
      return;
    }
    final identity = c.gallery
        .map((g) => c.galleryItemIdentity(g.slot))
        .join('|');
    if (_preloadedIdentity == identity) return;
    _preloadedIdentity = identity;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && available && !c.demo) {
        unawaited(c.preloadGalleryPreviews());
      }
    });
  }

  Future<void> _refresh() async {
    await c.refreshGallery();
    if (!mounted) return;
    _preloadedIdentity = null;
    _schedulePreload();
  }

  @override
  void dispose() {
    c.removeListener(_controllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '喜欢的，都在这里。',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  '留在设备里的小小收藏，随时换一种心情。',
                  style: TextStyle(color: mutedText),
                ),
              ],
            ),
          ),
          IconButton.outlined(
            tooltip: '刷新图库',
            onPressed: !available || blocked ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      const SizedBox(height: 25),
      if (!available)
        SectionCard(
          child: EmptyState(
            icon: Icons.photo_library_outlined,
            title: '连接后，看看你的收藏',
            description: '设备图库可以存下 8 张画面。\n连接墨印后，照片和便签就会出现在这里。',
            action: FilledButton.icon(
              onPressed: () => showConnectionSheet(context, c),
              icon: const Icon(Icons.bluetooth_rounded),
              label: const Text('连接设备'),
            ),
          ),
        )
      else if (!c.gallerySupported)
        const SectionCard(
          child: EmptyState(
            icon: Icons.collections_outlined,
            title: '这台设备暂不支持图库',
            description: '你仍然可以从创作页发送画面。\n支持图库的固件连接后，此功能会自动开启。',
          ),
        )
      else ...[
        SectionCard(
          color: const Color(0xFFEAF1FD),
          padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 18),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 18,
            runSpacing: 14,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.collections_bookmark_outlined,
                    color: Color(0xFF1967D2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${c.gallery.length} / ${c.galleryCapacity} 张',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 13),
                  Text(
                    c.demo ? '本地演示图库' : '储存在墨印设备',
                    style: const TextStyle(fontSize: 12, color: mutedText),
                  ),
                ],
              ),
              FilledButton.tonalIcon(
                onPressed: blocked || c.gallery.isEmpty ? null : c.nextGallery,
                icon: const Icon(Icons.skip_next_rounded, size: 19),
                label: const Text('显示下一张'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 23),
        if (c.gallery.isEmpty)
          SectionCard(
            child: EmptyState(
              icon: Icons.add_photo_alternate_outlined,
              title: '让第一张画面住进来',
              description: '在创作页完成画面后，选择“存入图库并显示”。',
              action: TextButton.icon(
                onPressed: () => c.setTab(0),
                icon: const Icon(Icons.add_rounded),
                label: const Text('去创作'),
              ),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final count = constraints.maxWidth >= 960
                  ? 3
                  : constraints.maxWidth >= 560
                  ? 2
                  : 1;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: count,
                  crossAxisSpacing: 20,
                  mainAxisSpacing: 20,
                  childAspectRatio: 1.08,
                ),
                itemCount: c.gallery.length,
                itemBuilder: (context, i) => _item(context, c.gallery[i]),
              );
            },
          ),
        if (c.gallery.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: blocked
                    ? null
                    : () async {
                        if (await confirmAction(
                          context,
                          title: '清空设备图库？',
                          message:
                              '图库中的 ${c.gallery.length} 张图片都会删除。屏幕当前画面和最近缓存会保留。',
                          confirm: '清空图库',
                          danger: true,
                        )) {
                          await c.clearGallery();
                        }
                      },
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('清空图库'),
              ),
            ),
          ),
      ],
      const SizedBox(height: 26),
    ],
  );

  Widget _item(BuildContext context, GalleryItemView item) {
    final status = c.galleryPreviewStatus(item.slot);
    return SectionCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(17),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: const Color(0xFFF3F2EC),
                    child: item.png != null
                        ? Image.memory(
                            item.png!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) =>
                                const _UnreadPreview(label: '预览未能打开 · 点按重新读取'),
                          )
                        : _UnreadPreview(
                            label: status.loading
                                ? '正在读取设备预览…'
                                : status.error != null
                                ? '读取失败 · 点按重试'
                                : '点按读取设备预览',
                            loading: status.loading,
                            progress: status.progress,
                          ),
                  ),
                  if (item.current)
                    const Positioned(
                      left: 10,
                      top: 10,
                      child: TonalLabel(
                        '正在显示',
                        icon: Icons.check_rounded,
                        color: Color(0xFFE7F1E8),
                        foreground: Color(0xFF36724D),
                      ),
                    ),
                  if (item.png != null && status.loading)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(value: status.progress),
                    ),
                  Positioned.fill(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => showGalleryPreview(context, c, item.slot),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '画面 ${item.slot + 1}',
                      style: const TextStyle(fontSize: 11, color: mutedText),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '下载完整图片',
                onPressed: () => showGalleryPreview(
                  context,
                  c,
                  item.slot,
                  downloadOnOpen: true,
                ),
                icon: const Icon(Icons.download_rounded, size: 21),
              ),
              IconButton(
                tooltip: '在墨印上显示',
                onPressed: blocked ? null : () => c.showGallery(item.slot),
                icon: const Icon(Icons.slideshow_rounded, size: 22),
              ),
              PopupMenuButton<String>(
                tooltip: '图片操作',
                enabled: true,
                onSelected: (value) async {
                  if (value == 'preview') {
                    await showGalleryPreview(context, c, item.slot);
                  }
                  if (value == 'download') {
                    if (!context.mounted) return;
                    await showGalleryPreview(
                      context,
                      c,
                      item.slot,
                      downloadOnOpen: true,
                    );
                  }
                  if (value == 'delete' &&
                      context.mounted &&
                      await confirmAction(
                        context,
                        title: '删除这张画面？',
                        message: '会从设备图库删除“${item.title}”。当前屏幕上的画面不会改变。',
                        confirm: '删除',
                        danger: true,
                      )) {
                    await c.deleteGallery(item.slot);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'preview', child: Text('查看与读取画面')),
                  const PopupMenuItem(value: 'download', child: Text('下载完整图片')),
                  PopupMenuItem(
                    value: 'delete',
                    enabled: !blocked,
                    child: const Text('从图库删除'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UnreadPreview extends StatelessWidget {
  const _UnreadPreview({
    required this.label,
    this.loading = false,
    this.progress,
  });
  final String label;
  final bool loading;
  final double? progress;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_outlined, size: 38, color: Color(0xFF8A99AD)),
          const SizedBox(height: 9),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: mutedText),
          ),
          if (loading) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(value: progress),
            ),
          ],
        ],
      ),
    ),
  );
}

Future<void> showGalleryPreview(
  BuildContext context,
  MoinkController controller,
  int slot, {
  bool downloadOnOpen = false,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => GalleryImageViewer(
      c: controller,
      slot: slot,
      downloadOnOpen: downloadOnOpen,
    ),
  ),
);

typedef GalleryImageSaver = Future<String> Function(
  Uint8List png, {
  required String fileName,
});

class GalleryImageViewer extends StatefulWidget {
  const GalleryImageViewer({
    super.key,
    required this.c,
    required this.slot,
    this.downloadOnOpen = false,
    this.saveImage = saveGalleryImage,
  });
  final MoinkController c;
  final int slot;
  final bool downloadOnOpen;
  final GalleryImageSaver saveImage;

  @override
  State<GalleryImageViewer> createState() => _GalleryImageViewerState();
}

class _GalleryImageViewerState extends State<GalleryImageViewer> {
  final _transform = TransformationController();
  Uint8List? _png;
  String? _identity, _error, _saveMessage, _saveError;
  bool _loading = false,
      _loadingFull = false,
      _fullFrame = false,
      _changed = false;
  bool _saving = false;
  int _request = 0;
  Offset? _doubleTapPosition;
  Size _imageArea = Size.zero;
  GalleryItemView? get _item {
    final matches = widget.c.gallery.where((item) => item.slot == widget.slot);
    return matches.isEmpty ? null : matches.first;
  }

  @override
  void initState() {
    super.initState();
    _identity = widget.c.galleryItemIdentity(widget.slot);
    _png = _item?.png;
    _fullFrame = widget.c.galleryPreviewStatus(widget.slot).fullFrame;
    _changed = _identity == null || _item == null;
    widget.c.addListener(_controllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_changed) {
        if (widget.downloadOnOpen) {
          _download();
        } else {
          _read();
        }
      }
    });
  }

  void _controllerChanged() {
    if (!mounted) return;
    if (widget.c.galleryItemIdentity(widget.slot) != _identity) {
      _request++;
      setState(() {
        _changed = true;
        _png = null;
        _loading = false;
        _error = null;
        _saving = false;
        _saveMessage = null;
        _saveError = null;
      });
    } else {
      setState(() {
        // An idle background read may upgrade an already-open thumbnail.
        // Keep the user's zoom/pan and never downgrade a complete image.
        final cached = _item?.png;
        final full = widget.c.galleryPreviewStatus(widget.slot).fullFrame;
        if (!_loading && !_saving && cached != null && (!_fullFrame || full)) {
          _png = cached;
          _fullFrame = full;
          _error = null;
        }
      });
    }
  }

  Future<void> _read({bool fullFrame = false, bool forceReload = false}) async {
    if (_changed || _loading || _saving) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _loadingFull = fullFrame;
      _error = null;
    });
    GalleryPreviewResult result;
    try {
      result = await widget.c.readGalleryPreview(
        widget.slot,
        fullFrame: fullFrame,
        forceReload: forceReload,
      );
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
      return;
    }
    if (!mounted || request != _request) return;
    setState(() {
      _loading = false;
      if (result.changed ||
          widget.c.galleryItemIdentity(widget.slot) != _identity ||
          (result.identity != null && result.identity != _identity)) {
        _changed = true;
        _png = null;
      } else if (result.error != null) {
        _error = result.error;
      } else if (result.png == null) {
        _error = '设备没有可用的预览，请尝试读取完整画面。';
      } else {
        _png = result.png;
        _fullFrame = result.fullFrame;
        _transform.value = Matrix4.identity();
      }
    });
  }

  Future<void> _download() async {
    if (_changed || _saving) return;
    final request = ++_request;
    setState(() {
      _saving = true;
      _loading = true;
      _loadingFull = true;
      _error = null;
      _saveError = null;
      _saveMessage = null;
    });
    try {
      final result = await widget.c.readGalleryPreview(
        widget.slot,
        fullFrame: true,
      );
      if (!mounted || request != _request) return;
      if (result.changed ||
          widget.c.galleryItemIdentity(widget.slot) != _identity ||
          (result.identity != null && result.identity != _identity)) {
        setState(() {
          _changed = true;
          _png = null;
        });
        return;
      }
      if (!result.ok || !result.fullFrame || result.png == null) {
        setState(() {
          _saveError = result.error ?? '完整画面尚未读取，未保存缩略图。请重试下载。';
        });
        return;
      }
      setState(() {
        _loading = false;
        _png = result.png;
        _fullFrame = true;
        _transform.value = Matrix4.identity();
      });
      final message = await widget.saveImage(
        result.png!,
        fileName:
            'MoInk-画面-${widget.slot + 1}-${DateTime.now().millisecondsSinceEpoch}.png',
      );
      if (!mounted || request != _request) return;
      setState(() => _saveMessage = message);
    } on ImageExportException catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        if (e.code == 'cancelled') {
          _saveMessage = '已取消保存';
        } else {
          _saveError = e.message;
        }
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _saveError = e.toString());
    } finally {
      if (mounted && request == _request) {
        setState(() {
          _saving = false;
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _request++;
    widget.c.removeListener(_controllerChanged);
    _transform.dispose();
    super.dispose();
  }

  void _resetZoom() => _transform.value = Matrix4.identity();

  void _zoomTo(double wanted, Offset focalPoint) {
    final current = _transform.value.getMaxScaleOnAxis();
    final next = wanted.clamp(1.0, 8.0);
    final ratio = next / current;
    final translation = _transform.value.getTranslation();
    _transform.value = Matrix4.diagonal3Values(next, next, 1)
      ..setTranslationRaw(
        focalPoint.dx - (focalPoint.dx - translation.x) * ratio,
        focalPoint.dy - (focalPoint.dy - translation.y) * ratio,
        0,
      );
  }

  void _doubleTap() {
    if (_transform.value.getMaxScaleOnAxis() > 1.05) {
      _resetZoom();
    } else {
      _zoomTo(2.5, _doubleTapPosition ?? _imageArea.center(Offset.zero));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF7F9FC),
    appBar: AppBar(
      leading: IconButton(
        tooltip: '关闭预览',
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close_rounded),
      ),
      title: Text(
        _item?.title ?? '图库画面',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          tooltip: '适应画面',
          onPressed: _png == null ? null : _resetZoom,
          icon: const Icon(Icons.fit_screen_rounded),
        ),
        IconButton(
          tooltip: '重新读取预览',
          onPressed: _changed || _loading || _saving
              ? null
              : () => _read(fullFrame: _fullFrame, forceReload: true),
          icon: const Icon(Icons.refresh_rounded),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >= 850 ||
              constraints.maxWidth > constraints.maxHeight * 1.35;
          if (wide) {
            return Row(
              children: [
                Expanded(child: _stage()),
                SizedBox(
                  width: 300,
                  child: SingleChildScrollView(child: _controls()),
                ),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: _stage()),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * .47,
                ),
                child: SingleChildScrollView(child: _controls()),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _stage() => ColoredBox(
    color: const Color(0xFF171C24),
    child: LayoutBuilder(
      builder: (context, constraints) {
        _imageArea = constraints.biggest;
        if (_changed) {
          return _stageMessage(
            Icons.collections_outlined,
            '这张画面已发生变化',
            '设备已断开、图片已被替换或删除。\n返回图库同步后，再打开要查看的画面。',
            action: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回图库'),
            ),
          );
        }
        if (_png == null) {
          if (_loading) {
            return _stageMessage(
              null,
              _waitingLabel,
              '读取完成后，画面会自动显示在这里。',
              loading: true,
            );
          }
          return _stageMessage(
            Icons.broken_image_outlined,
            '还没有可用的画面',
            _error ?? '可先读取预览，也可以直接读取完整画面。',
            action: TextButton.icon(
              onPressed: () =>
                  _read(fullFrame: _loadingFull, forceReload: true),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试读取'),
            ),
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onDoubleTapDown: (details) =>
                  _doubleTapPosition = details.localPosition,
              onDoubleTap: _doubleTap,
              child: InteractiveViewer(
                key: const Key('gallery-image-viewer'),
                transformationController: _transform,
                minScale: 1,
                maxScale: 8,
                boundaryMargin: const EdgeInsets.all(48),
                child: Center(
                  child: Image.memory(
                    _png!,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, _, _) => _stageMessage(
                      Icons.broken_image_outlined,
                      '预览数据无法打开',
                      '请重新读取，或尝试读取完整画面。',
                      action: TextButton.icon(
                        onPressed: _loading
                            ? null
                            : () => _read(
                                fullFrame: _loadingFull,
                                forceReload: true,
                              ),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('重试读取'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_loading)
              Positioned(
                top: 16,
                left: 20,
                right: 20,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xE62D3643),
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Text(
                        _waitingLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );

  String get _waitingLabel => widget.c.busy && !widget.c.phase.contains('读取')
      ? '设备正忙，正在等待空闲…'
      : _loadingFull
      ? '正在读取完整画面…'
      : '正在读取设备预览…';

  Widget _stageMessage(
    IconData? icon,
    String title,
    String description, {
    Widget? action,
    bool loading = false,
  }) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const CircularProgressIndicator(color: Color(0xFFA8C7FA))
          else if (icon != null)
            Icon(icon, size: 42, color: const Color(0xFFB8C6D9)),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 17),
          ),
          const SizedBox(height: 9),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFBBC6D6), fontSize: 12),
          ),
          if (action != null) ...[
            const SizedBox(height: 12),
            TextButtonTheme(
              data: TextButtonThemeData(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFA8C7FA),
                ),
              ),
              child: action,
            ),
          ],
        ],
      ),
    ),
  );

  Widget _controls() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _changed
                    ? '图库已变化'
                    : widget.c.demo
                    ? '本地演示画面'
                    : _fullFrame
                    ? '完整画面 · 768 × 552'
                    : '设备缩略预览',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (_png != null && !_changed)
              ValueListenableBuilder<Matrix4>(
                valueListenable: _transform,
                builder: (_, value, _) => Text(
                  '${value.getMaxScaleOnAxis().toStringAsFixed(1)}×',
                  style: const TextStyle(fontSize: 12, color: mutedText),
                ),
              ),
          ],
        ),
        const SizedBox(height: 7),
        const Text(
          '双指缩放和平移 · 双击放大，再次双击还原',
          style: TextStyle(fontSize: 11, color: mutedText),
        ),
        if (_loading) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: widget.c.phase.contains('读取') ? widget.c.progress : null,
          ),
          const SizedBox(height: 7),
          Text(
            _waitingLabel,
            style: const TextStyle(fontSize: 11, color: mutedText),
          ),
        ],
        if (_error != null && !_changed && _png != null) ...[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: const TextStyle(fontSize: 12, color: Color(0xFFB3261E)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _loading
                  ? null
                  : () => _read(fullFrame: _loadingFull, forceReload: true),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('重试读取'),
            ),
          ),
        ],
        if (_saveMessage != null && !_changed) ...[
          const SizedBox(height: 12),
          Text(
            _saveMessage!,
            key: const Key('gallery-save-result'),
            style: const TextStyle(fontSize: 12, color: Color(0xFF2E6B41)),
          ),
        ],
        if (_saveError != null && !_changed) ...[
          const SizedBox(height: 12),
          Text(
            _saveError!,
            key: const Key('gallery-save-error'),
            style: const TextStyle(fontSize: 12, color: Color(0xFFB3261E)),
          ),
        ],
        const SizedBox(height: 15),
        if (!_changed) ...[
          if (!widget.c.demo)
            OutlinedButton.icon(
              key: const Key('gallery-read-full'),
              onPressed: _loading || _saving || _fullFrame
                  ? null
                  : () => _read(fullFrame: true),
              icon: Icon(
                _fullFrame ? Icons.check_rounded : Icons.hd_outlined,
                size: 20,
              ),
              label: Text(_fullFrame ? '已读取完整画面' : '读取完整画面 · 查看细节'),
            ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const Key('gallery-download'),
            onPressed: _saving ? null : _download,
            icon: Icon(
              _saving ? Icons.hourglass_top_rounded : Icons.download_rounded,
              size: 20,
            ),
            label: Text(
              _saving
                  ? '正在下载完整图片…'
                  : _saveError != null
                  ? '重试下载图片'
                  : '下载图片',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: (widget.c.busy && !widget.c.galleryReading) || _saving
                ? null
                : () {
                    Navigator.pop(context);
                    widget.c.showGallery(widget.slot);
                  },
            icon: const Icon(Icons.slideshow_rounded, size: 19),
            label: Text(widget.c.demo ? '演示切换' : '在墨印上显示'),
          ),
        ] else
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回图库'),
          ),
      ],
    ),
  );
}

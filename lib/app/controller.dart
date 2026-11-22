import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/native_ble.dart';
import '../core/protocol.dart';
import 'image_processor.dart';
import 'models.dart';

typedef ArtworkProcessor = Future<ProcessedArtwork> Function(
  ComposerDraft draft,
);

class GalleryPreviewResult {
  const GalleryPreviewResult({
    this.png,
    this.fullFrame = false,
    this.error,
    this.changed = false,
    this.identity,
  });

  final Uint8List? png;
  final bool fullFrame, changed;
  final String? error, identity;
  bool get ok => png != null && error == null && !changed;
}

class GalleryPreviewStatus {
  const GalleryPreviewStatus({
    this.loading = false,
    this.progress,
    this.error,
    this.fullFrame = false,
  });

  final bool loading, fullFrame;
  final double? progress;
  final String? error;
}

class _GalleryAppendProof {
  const _GalleryAppendProof(this.client, this.generation, this.before);
  final EspInkClient client;
  final int generation;
  final List<Map<String, dynamic>> before;
}

/// A firmware-advertised successful append before the physical display window.
/// This is provisional evidence; STORE_DONE still decides the final outcome.
class _GalleryWindowAppendProof {
  _GalleryWindowAppendProof(
    this.client,
    this.generation,
    this.before,
    this.revision,
    this.jobToken,
  );
  final EspInkClient client;
  final int generation, revision;
  final List<Map<String, dynamic>> before;
  final Object jobToken;
  bool queued = false, attempted = false, syncing = false, migrated = false;
  Future<void>? sync;
}

class _GalleryDeleteProof {
  const _GalleryDeleteProof(
    this.client,
    this.generation,
    this.before,
    this.slot,
    this.current,
  );
  final EspInkClient client;
  final int generation, slot;
  final int? current;
  final List<Map<String, dynamic>> before;
}

class _GalleryReadDeferred implements Exception {}

class EspInkController extends ChangeNotifier with WidgetsBindingObserver {
  EspInkController({NativeBle? nativeBle, ArtworkProcessor? artworkProcessor})
    : _ble = nativeBle ?? NativeBle(),
      _processArtwork = artworkProcessor ?? processArtwork;
  final NativeBle _ble;
  final ArtworkProcessor _processArtwork;
  EspInkClient? _client;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  StreamSubscription<dynamic>? _deviceEvents;
  StreamSubscription<void>? _galleryReadiness;
  SharedPreferences? _preferences;
  TransferCancellation? _cancellation;
  int _renderRevision = 0;
  Future<void>? _activeRender;
  Future<void>? _artworkTail;
  Timer? _previewDebounce;
  bool _inkPreviewActive = false;
  bool get inkPreviewActive => _inkPreviewActive;
  int? _requestedPreviewRevision, _activeRenderRevision;
  int _previewRevision = -1;
  final Map<int, Future<ProcessedArtwork>> _processing = {};
  bool _disposed = false;
  bool _pickingPhoto = false;
  bool _pickingOta = false;
  int _connectionGeneration = 0;
  bool get pickingOta => _pickingOta;
  int _photoSelectionGeneration = 0;
  bool _recoveredPhotoNeedsAdjustment = false;
  bool get pickingPhoto => _pickingPhoto;
  bool get recoveredPhotoNeedsAdjustment => _recoveredPhotoNeedsAdjustment;

  bool consumeRecoveredPhotoAdjustment() {
    if (!_recoveredPhotoNeedsAdjustment) return false;
    _recoveredPhotoNeedsAdjustment = false;
    return true;
  }

  /// An explicit note choice supersedes any still-pending photo recovery.
  void selectNoteComposition() {
    if (_disposed) return;
    _photoSelectionGeneration++;
    _recoveredPhotoNeedsAdjustment = false;
    updateDraft(draft.copyWith(kind: CompositionKind.note, textEnabled: true));
  }

  bool _queued = false;
  bool _intentionalDisconnect = false;
  bool _otaSubmitted = false;
  int tabIndex = 0;
  ComposerDraft draft = const ComposerDraft();
  Uint8List? previewPng;
  Uint8List? _packed;
  bool rendering = false, demo = false, connecting = false, scanning = false;
  bool busy = false, gallerySupported = false, rebootRequired = false;
  String deviceName = '尚未连接', firmware = '—', message = '', phase = '';
  String deviceState = '未连接';
  int? batteryMv;
  bool batteryReadingStale = false;
  DateTime? batteryLastUpdatedAt;
  Timer? _statusPollTimer;
  bool _statusPolling = false;
  double? progress;
  int mtu = 23;
  List<DeviceView> devices = [];
  List<GalleryItemView> gallery = [];
  int galleryCapacity = 8;
  SettingsView settings = const SettingsView();
  final List<String> logs = [];
  List<Map<String, dynamic>> _galleryMetadata = [];
  int? _galleryRevision;
  _GalleryWindowAppendProof? _galleryWindowAppend;
  Object? _initialGallerySyncToken;
  int _galleryGeneration = 0;
  Future<void> _galleryReadTail = Future.value();
  Future<void>? _galleryPreload;
  Timer? _galleryBackgroundTimer;
  TransferCancellation? _galleryBackgroundCancellation;
  final Set<String> _galleryFullAttempts = {};
  final Set<String> _galleryThumbnailAttempts = {};
  int _galleryBackgroundEpoch = 0;
  bool _activeGalleryReadBackground = false;
  bool _activeGalleryReadOwnsBusy = false;
  bool _galleryReadBlocked = false;
  int _galleryDeviceUpdateRevision = 0;
  bool _lastGalleryWindowReady = false;
  bool _galleryMetadataNeedsRefresh = false;
  Object? _foregroundJobToken;
  bool _displayReadJobActive = false;
  bool _displayJobQueued = false;
  bool _appActive = true;
  bool _deviceIdle = false;
  final Map<String, Future<GalleryPreviewResult>> _galleryReads = {};
  final Map<int, String> _galleryFullFrames = {};
  final Map<int, GalleryPreviewStatus> _galleryStatuses = {};
  final Map<int, Object> _galleryStatusOwners = {};
  final Set<Completer<void>> _galleryIdleWaiters = {};
  Object? _activeGalleryReadToken;
  int _pendingGalleryMutations = 0;
  bool get galleryReading =>
      _activeGalleryReadToken != null &&
      _foregroundJobToken == null &&
      _pendingGalleryMutations == 0;

  GalleryPreviewStatus galleryPreviewStatus(int slot) =>
      _galleryStatuses[slot] ??
      GalleryPreviewStatus(fullFrame: demo && _galleryItem(slot)?.png != null);

  GalleryItemView? _galleryItem(int slot) =>
      gallery.where((item) => item.slot == slot).firstOrNull;

  String? galleryItemIdentity(int slot) {
    final item = _galleryItem(slot);
    if (item == null) return null;
    if (demo) {
      return '$_galleryGeneration:demo:$slot:${identityHashCode(item.png ?? item.title)}';
    }
    final metadata = _galleryMetadata
        .where((item) => item['slot'] == slot)
        .firstOrNull;
    if (metadata == null) return null;
    return '$_galleryGeneration:${jsonEncode(metadata)}';
  }

  void _resetGallerySession() {
    _stopGalleryBackground();
    _statusPollTimer?.cancel();
    _statusPollTimer = null;
    _galleryGeneration++;
    _galleryReadBlocked = false;
    _lastGalleryWindowReady = false;
    _galleryMetadataNeedsRefresh = false;
    _galleryWindowAppend = null;
    _initialGallerySyncToken = null;
    _galleryRevision = null;
    if (_activeGalleryReadToken != null) {
      _activeGalleryReadToken = null;
      _activeGalleryReadBackground = false;
      _galleryBackgroundCancellation = null;
      if (_activeGalleryReadOwnsBusy) {
        busy = false;
        phase = '';
        progress = null;
      }
      _activeGalleryReadOwnsBusy = false;
    }
    _galleryReadTail = Future.value();
    gallery = [];
    _galleryMetadata = [];
    _galleryFullFrames.clear();
    _galleryFullAttempts.clear();
    _galleryThumbnailAttempts.clear();
    _galleryStatuses.clear();
    _galleryStatusOwners.clear();
    _galleryReads.clear();
    _galleryPreload = null;
    for (final waiter in _galleryIdleWaiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  bool get previewReady =>
      _packed != null &&
      previewPng != null &&
      _previewRevision == _renderRevision;
  bool get hasInkPreview => previewPng != null && _previewRevision >= 0;
  bool get connected => !demo && _ble.isConnected && _client != null;
  bool get canCancel => busy && _cancellation != null && !_queued;
  bool get bluetoothSupported => _ble.supported;
  String get connectionLabel => demo
      ? '本地演示'
      : connecting
      ? '正在连接'
      : connected
      ? '已连接'
      : '未连接设备';

  Future<void> init({bool demoMode = false}) async {
    WidgetsBinding.instance.addObserver(this);
    _subscriptions.add(
      _ble.scanStateChanges.listen((value) {
        scanning = value;
        _notify();
      }),
    );
    _subscriptions.add(
      _ble.scanResults.listen((items) {
        devices = items.map((d) => DeviceView(d.id, d.name, d.rssi)).toList();
        _notify();
      }),
    );
    _subscriptions.add(
      _ble.errors.listen((error) {
        _log(error);
        _say(error);
        scanning = false;
        _notify();
      }),
    );
    _subscriptions.add(
      _ble.connectionChanges.listen((isConnected) {
        if (!isConnected && !demo) {
          _resetGallerySession();
          gallerySupported = false;
          _clearBattery();
          _deviceIdle = false;
          deviceState = '未连接';
          if (!_intentionalDisconnect) {
            _say(
              _otaSubmitted
                  ? '设备已断开。请按键唤醒后重新连接，核对新版本并等待启动确认。'
                  : busy
                  ? '连接已断开，当前作业结果待确认。重连后请先查询设备，勿重复追加图片。'
                  : '设备已断开。请靠近设备，按一下设备按键后重连。',
            );
          }
          _log('BLE 连接断开');
          _notify();
        }
      }),
    );
    try {
      _preferences = await SharedPreferences.getInstance();
      final stored = _preferences?.getString('composer.v2');
      if (stored != null) {
        final map = jsonDecode(stored) as Map<String, dynamic>;
        draft = ComposerDraft.fromJson(map);
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final recoveryGeneration = _photoSelectionGeneration;
        final lost = await ImagePicker().retrieveLostData();
        if (!lost.isEmpty && lost.files?.isNotEmpty == true) {
          final bytes = await lost.files!.first.readAsBytes();
          if (!_disposed && recoveryGeneration == _photoSelectionGeneration) {
            _acceptPhotoBytes(bytes);
            _recoveredPhotoNeedsAdjustment = true;
            _say('已恢复刚才选择的照片');
          }
        }
      }
    } catch (e) {
      _log('读取本地草稿：$e');
    }
    if (demoMode) await enterDemo();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _say(String value) {
    message = value;
    _notify();
  }

  void clearMessage() {
    message = '';
  }

  void _log(String value) {
    final now = DateTime.now();
    logs.insert(
      0,
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}  $value',
    );
    if (logs.length > 200) logs.removeLast();
  }

  void setTab(int index) {
    final previous = tabIndex;
    tabIndex = index;
    if (index != 0) setInkPreviewActive(false);
    if (index == 1) {
      if (previous != 1) {
        _galleryFullAttempts.clear();
        _galleryThumbnailAttempts.clear();
      }
      _scheduleGalleryBackground();
    } else {
      _stopGalleryBackground();
    }
    _notify();
  }

  /// Source-photo editing stays immediate; only the visible ink effect converts.
  void setInkPreviewActive(bool active) {
    if (_disposed || _inkPreviewActive == active) return;
    _inkPreviewActive = active;
    _previewDebounce?.cancel();
    _previewDebounce = null;
    if (active) {
      unawaited(renderPreview());
    } else {
      _requestedPreviewRevision = null;
    }
    _notify();
  }

  void _scheduleInkPreview() {
    _previewDebounce?.cancel();
    if (!_inkPreviewActive || !_appActive || tabIndex != 0) return;
    _previewDebounce = Timer(const Duration(milliseconds: 240), () {
      _previewDebounce = null;
      if (!_disposed && _inkPreviewActive && _appActive && tabIndex == 0) {
        unawaited(renderPreview());
      }
    });
  }

  void updateDraft(ComposerDraft value) {
    if (draft.kind != value.kind ||
        !identical(draft.photoBytes, value.photoBytes)) {
      previewPng = null;
    }
    draft = value;
    _renderRevision++;
    _packed = null;
    // Keep the last ink image visible while the latest edit is debounced.
    // Original-photo mode still never queues expensive conversion on gestures.
    _scheduleInkPreview();
    _notify();
    unawaited(_saveDraft(value));
  }

  Future<void> _saveDraft(ComposerDraft value) async {
    try {
      await _preferences?.setString('composer.v2', jsonEncode(value.toJson()));
    } catch (e) {
      _log('保存本地草稿失败：$e');
    }
  }

  Future<ProcessedArtwork> _artworkFor(ComposerDraft snapshot, int revision) {
    if (previewReady && revision == _previewRevision) {
      return Future.value(ProcessedArtwork(_packed!, previewPng!));
    }
    final existing = _processing[revision];
    if (existing != null) return existing;
    final previous = _artworkTail;
    final processing = previous == null
        ? Future<ProcessedArtwork>.sync(() => _processArtwork(snapshot))
        : previous.then((_) => _processArtwork(snapshot));
    final task = processing.then((result) {
      if (!_disposed && revision == _renderRevision) {
        _packed = result.packed;
        previewPng = result.png;
        _previewRevision = revision;
      }
      return result;
    });
    _processing[revision] = task;
    final tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _artworkTail = tail;
    unawaited(
      tail.then((_) {
        if (identical(_artworkTail, tail)) _artworkTail = null;
      }),
    );
    unawaited(
      task.then<void>(
        (_) {
          _processing.remove(revision);
        },
        onError: (Object _, StackTrace _) {
          _processing.remove(revision);
        },
      ),
    );
    return task;
  }

  Future<void> renderPreview() {
    if (_disposed || previewReady) return Future.value();
    if (_activeRender != null) {
      if (_activeRenderRevision != _renderRevision) {
        _requestedPreviewRevision = _renderRevision;
      }
      return _activeRender!;
    }
    _requestedPreviewRevision = _renderRevision;
    final done = Completer<void>();
    _activeRender = done.future;
    unawaited(
      _drainRender().whenComplete(() {
        _activeRender = null;
        _activeRenderRevision = null;
        done.complete();
      }),
    );
    return done.future;
  }

  Future<void> _drainRender() async {
    rendering = true;
    _notify();
    try {
      while (!_disposed) {
        final revision = _requestedPreviewRevision;
        _requestedPreviewRevision = null;
        // At most the active snapshot and one latest requested revision survive.
        if (revision == null || revision != _renderRevision || previewReady) {
          break;
        }
        _activeRenderRevision = revision;
        final snapshot = draft;
        try {
          await _artworkFor(snapshot, revision);
        } catch (e) {
          if (!_disposed && revision == _renderRevision) {
            _log('图像处理失败：$e');
            _say('图片处理失败，请换一张图片重试。');
          }
        }
      }
    } finally {
      rendering = false;
      _notify();
    }
  }

  void _acceptPhotoBytes(Uint8List bytes) {
    if (bytes.isEmpty) throw const FormatException('图片文件为空');
    if (bytes.length > 24 * 1024 * 1024) {
      throw ArgumentError('图片过大，请选择小于24 MB的照片');
    }
    // A normal selection supersedes any unconsumed recovery request.
    // The recovery path explicitly sets this again after accepting its photo.
    _recoveredPhotoNeedsAdjustment = false;
    updateDraft(
      draft.copyWith(
        kind: CompositionKind.photo,
        photoBytes: bytes,
        zoom: 1,
        rotation: 0,
        quarterTurns: 0,
        mirror: false,
        offsetX: 0,
        offsetY: 0,
      ),
    );
  }

  /// True only after the system picker returned a photo that was read and
  /// accepted. Cancellation/failure preserves the previous draft.
  Future<bool> pickPhoto() async {
    if (_disposed || _pickingPhoto) return false;
    final generation = ++_photoSelectionGeneration;
    _pickingPhoto = true;
    _notify();
    try {
      final file = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
          ? await openFile(
              acceptedTypeGroups: const [
                XTypeGroup(
                  label: '照片',
                  extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
                ),
              ],
              confirmButtonText: '选择照片',
            )
          : await ImagePicker().pickImage(
              source: ImageSource.gallery,
              maxWidth: 2048,
              maxHeight: 2048,
              imageQuality: 95,
            );
      if (file == null ||
          _disposed ||
          generation != _photoSelectionGeneration) {
        return false;
      }
      if (await file.length() > 24 * 1024 * 1024) {
        throw ArgumentError('图片过大，请选择小于24 MB的照片');
      }
      final bytes = await file.readAsBytes();
      if (_disposed || generation != _photoSelectionGeneration) return false;
      _acceptPhotoBytes(bytes);
      return true;
    } catch (e) {
      if (_disposed || generation != _photoSelectionGeneration) return false;
      _log('$e');
      _say('无法打开这张照片：$e');
      return false;
    } finally {
      _pickingPhoto = false;
      _notify();
    }
  }

  Future<void> scan() async {
    if (demo) await leaveDemo();
    if (busy || connecting) return;
    if (!_ble.supported) {
      _say('蓝牙连接请使用 Android 或 Windows 版；当前预览可体验本地创作。');
      return;
    }
    scanning = true;
    devices = [];
    _notify();
    try {
      await _ble.startScan();
      _log('按 ESP-INK 服务 UUID 扫描');
      await Future<void>.delayed(const Duration(seconds: 10));
    } catch (e) {
      _say(_readable(e));
    } finally {
      await _ble.stopScan();
      scanning = false;
      _notify();
      if (devices.isEmpty && !connected) _say('暂未发现设备。请打开蓝牙，按一下设备按键后重试。');
    }
  }

  Future<void> connect(String id) async {
    if (connecting || busy) return;
    _connectionGeneration++;
    connecting = true;
    _notify();
    try {
      await _ble.stopScan();
      scanning = false;
      await _deviceEvents?.cancel();
      await _galleryReadiness?.cancel();
      unawaited(_client?.dispose());
      _client = null;
      _resetGallerySession();
      gallerySupported = false;
      _clearBattery();
      demo = false;
      _intentionalDisconnect = false;
      _otaSubmitted = false;
      await _ble.connect(id);
      _client = EspInkClient(_ble);
      final client = _client!;
      _galleryReadiness = client.galleryReadinessChanges.listen((_) {
        if (!_disposed && client == _client) _galleryAvailabilityChanged();
      });
      _deviceEvents = _client!.events.listen((event) {
        _log('设备事件 0x${event.id.toRadixString(16)} · ${event.arg}');
        if (event.id == 3) {
          if (event.payload.length >= 2) {
            final value = ByteData.sublistView(event.payload)
                .getInt16(0, Endian.little);
            if (value > 0) _acceptBattery(value);
          }
          _say('设备电量较低，请充电后再刷新屏幕。');
        }
        if (event.id == EventId.state || event.id == EventId.displayDone) {
          // DISPLAY_DONE is published after the firmware releases its job.
          // It need not be accompanied by a separate STATE(idle) event.
          _acceptDeviceState(event.id == EventId.displayDone ? 0 : event.arg);
          _galleryAvailabilityChanged(deviceUpdate: true);
        }
        _notify();
      });
      final ping = await _client!.ping();
      if (ping['api'] != 1) throw StateError('当前设备协议不受支持');
      firmware = ping['version'] as String;
      deviceName =
          devices.where((d) => d.id == id).firstOrNull?.name ?? 'ESP-INK';
      _log('已连接 $deviceName，固件 $firmware，MTU ${_ble.mtu}');
      await _refreshInternal();
      _say('已连接 $deviceName');
    } catch (e) {
      _say(_readable(e));
      _intentionalDisconnect = true;
      await _ble.disconnect();
      unawaited(_client?.dispose());
      _client = null;
    } finally {
      connecting = false;
      _notify();
      _scheduleStatusPoll();
      _galleryAvailabilityChanged();
    }
  }

  Future<void> disconnect() async {
    if (busy) {
      _say('请等待当前作业完成，或在传输阶段取消。');
      return;
    }
    if (demo) {
      await leaveDemo();
      return;
    }
    _intentionalDisconnect = true;
    await _ble.disconnect();
    await _galleryReadiness?.cancel();
    _galleryReadiness = null;
    unawaited(_client?.dispose());
    _client = null;
    _resetGallerySession();
    gallerySupported = false;
    _clearBattery();
    deviceName = '尚未连接';
    firmware = '—';
    deviceState = '未连接';
    _notify();
  }

  Future<void> openBluetoothSettings() async {
    try {
      await _ble.openBluetoothSettings();
    } catch (e) {
      _say(_readable(e));
    }
  }

  Future<void> enterDemo() async {
    if (busy) return;
    _intentionalDisconnect = true;
    await _ble.disconnect();
    await _galleryReadiness?.cancel();
    _galleryReadiness = null;
    unawaited(_client?.dispose());
    _client = null;
    demo = true;
    deviceName = 'ESP-INK · 体验设备';
    firmware = '本地演示';
    _clearBattery();
    mtu = 517;
    deviceState = '演示';
    gallerySupported = true;
    settings = const SettingsView();
    rebootRequired = false;
    _resetGallerySession();
    for (var i = 0; i < 3; i++) {
      final rendered = await _processArtwork(
        ComposerDraft(
          kind: CompositionKind.note,
          background: [1, 2, 0][i],
          noteTexts: [
            TextLayer(
              id: 'demo-$i',
              text: [
                '今天想记住的事\n\n散步，看云，\n把生活调成喜欢的频率。',
                '今天的清单\n\n□ 喝一杯水\n□ 出门走一走\n□ 早点休息',
                '给自己留一点空白。',
              ][i],
              color: i == 2 ? 1 : 0,
              size: 36,
            ),
          ],
        ),
      );
      if (_disposed || !demo) return;
      gallery.add(
        GalleryItemView(
          slot: i,
          title: ['今日便签', '待办清单', '留一点空白'][i],
          current: i == 0,
          png: rendered.png,
        ),
      );
    }
    _log('进入本地演示，不连接真实设备');
    _notify();
  }

  Future<void> leaveDemo() async {
    demo = false;
    _resetGallerySession();
    gallerySupported = false;
    deviceName = '尚未连接';
    deviceState = '未连接';
    firmware = '—';
    _clearBattery();
    mtu = 23;
    _notify();
  }

  Future<void> _refreshInternal({_GalleryAppendProof? append}) async {
    final client = _client!;
    final status = await client.getStatus();
    final s = await client.getSettings();
    _acceptDeviceStatus(status);
    if ((s['name'] as String? ?? '').isNotEmpty) {
      deviceName = s['name'] as String;
    }
    settings = SettingsView(
      name: s['name'] as String? ?? '',
      panel: s['panel'] as int? ?? 0,
      sleepSeconds: s['sleepS'] as int? ?? 180,
      wakeSeconds: s['autoWakeS'] as int? ?? 0,
      timeoutAction: s['timeoutAction'] as int? ?? 0,
      gpioPreset: s['gpioPreset'] as int? ?? 0,
      pins: List<int>.from(s['pins'] as List),
      cache: s['cacheOn'] as bool? ?? true,
      wakeShow: s['wakeShow'] as bool? ?? false,
    );
    if (_deviceIdle) {
      await _loadGallery(append: append);
    } else if (client.galleryReadAvailable && _foregroundJobToken == null) {
      try {
        await _loadGallery(onlyWithoutForeground: true);
      } on EspInkException catch (error) {
        if (error.status != StatusCode.busy &&
            error.status != StatusCode.stale) {
          rethrow;
        }
        _galleryMetadataNeedsRefresh = true;
      }
    } else if (_galleryMetadata.isEmpty) {
      _galleryMetadataNeedsRefresh = true;
    }
  }

  void _clearBattery() {
    batteryMv = null;
    batteryReadingStale = false;
    batteryLastUpdatedAt = null;
  }

  void _acceptBattery(int? value) {
    if (value != null && value > 0) {
      batteryMv = value;
      batteryReadingStale = false;
      batteryLastUpdatedAt = DateTime.now();
    } else {
      batteryReadingStale = batteryMv != null;
    }
  }

  void _acceptDeviceStatus(Map<String, dynamic> status) {
    _acceptBattery(status['batteryMv'] as int?);
    mtu = status['mtu'] as int? ?? _ble.mtu;
    firmware = status['version'] as String? ?? firmware;
    final state = status['stateCode'] as int? ?? 0;
    _acceptDeviceState(state);
    _galleryAvailabilityChanged(deviceUpdate: true);
  }

  void _acceptDeviceState(int state) {
    _deviceIdle = state == 0;
    deviceState =
        {
          0: '就绪',
          1: '接收图片',
          2: '接收固件',
          3: '屏幕 / 图库作业中',
          4: '清理残影',
          6: '即将休眠或重启',
        }[state] ??
        '状态 $state';
  }

  bool get _galleryDeviceReadable =>
      !_galleryReadBlocked &&
      _galleryWindowAppend?.syncing != true &&
      ((_deviceIdle && _foregroundJobToken == null) ||
          (_client?.galleryReadAvailable == true &&
              (_foregroundJobToken == null || _displayReadJobActive)));

  bool get _galleryReadCanStart =>
      !_pickingOta &&
      !connecting &&
      _pendingGalleryMutations == 0 &&
      _activeGalleryReadToken == null &&
      ((demo && !busy) ||
          (!demo &&
              _galleryDeviceReadable &&
              (!busy ||
                  (_foregroundJobToken != null &&
                      _displayReadJobActive &&
                      _client?.galleryReadAvailable == true))));

  void _galleryAvailabilityChanged({bool deviceUpdate = false}) {
    final ready = _client?.galleryReadAvailable == true;
    if (deviceUpdate || (ready && !_lastGalleryWindowReady)) {
      _galleryDeviceUpdateRevision++;
    }
    if ((deviceUpdate && (_deviceIdle || ready)) ||
        (ready && !_lastGalleryWindowReady)) {
      _galleryReadBlocked = false;
    }
    _lastGalleryWindowReady = ready;
    _synchronizeWindowAppend();
    _synchronizeInitialGallery();
    if (!_galleryDeviceReadable) {
      _stopGalleryBackground();
    } else {
      _scheduleGalleryBackground();
    }
    _notify();
  }

  void _synchronizeInitialGallery() {
    if (_disposed ||
        !connected ||
        connecting ||
        _pickingOta ||
        busy ||
        _foregroundJobToken != null ||
        !_galleryDeviceReadable ||
        !_galleryMetadataNeedsRefresh ||
        _galleryMetadata.isNotEmpty ||
        _initialGallerySyncToken != null) {
      return;
    }
    final token = Object();
    final client = _client;
    final generation = _galleryGeneration;
    _initialGallerySyncToken = token;
    unawaited(() async {
      try {
        await _loadGallery(onlyWithoutForeground: true);
      } catch (error) {
        if (!_disposed &&
            client == _client &&
            generation == _galleryGeneration) {
          if (error is EspInkException && error.status == StatusCode.busy) {
            _galleryReadBlocked = true;
          } else {
            _log('等待设备图库就绪：$error');
          }
        }
      } finally {
        if (identical(_initialGallerySyncToken, token)) {
          _initialGallerySyncToken = null;
          _scheduleGalleryBackground();
        }
      }
    }());
  }

  bool _windowAppendAvailable(_GalleryWindowAppendProof proof) =>
      !_disposed &&
      identical(_galleryWindowAppend, proof) &&
      identical(_foregroundJobToken, proof.jobToken) &&
      proof.client == _client &&
      proof.generation == _galleryGeneration &&
      proof.queued &&
      _displayReadJobActive &&
      _displayJobQueued &&
      proof.client.galleryAppendCommitted;

  void _synchronizeWindowAppend() {
    final proof = _galleryWindowAppend;
    if (proof == null || proof.attempted || !_windowAppendAvailable(proof)) {
      return;
    }
    proof.attempted = true;
    proof.syncing = true;
    proof.sync = () async {
      try {
        await _loadGallery(windowAppend: proof);
      } catch (error) {
        // A short display window may close between INFO and LIST. Keep the old
        // cache and let the ordinary final receipt synchronize it afterwards.
        if (error is! EspInkException ||
            (error.status != StatusCode.busy &&
                error.status != StatusCode.stale)) {
          _log('刷屏窗口同步图库：$error');
        }
      } finally {
        proof.syncing = false;
        if (identical(_galleryWindowAppend, proof)) {
          _galleryAvailabilityChanged();
        }
      }
    }();
    unawaited(proof.sync);
  }

  bool _storeConfirmsAppend(Map<String, dynamic>? result, int previousCount) {
    final stored = result?['store'];
    return result?['stored'] == true &&
        stored is Map &&
        stored['status'] == 0 &&
        stored['slot'] == previousCount &&
        stored['count'] == previousCount + 1;
  }

  Future<bool> _completeWindowAppend(
    _GalleryWindowAppendProof? proof,
    Map<String, dynamic>? result,
  ) async {
    if (proof == null) return false;
    await proof.sync;
    if (!identical(_galleryWindowAppend, proof)) return false;
    _galleryWindowAppend = null;
    if (proof.migrated &&
        !_storeConfirmsAppend(result, proof.before.length) &&
        proof.client == _client &&
        proof.generation == _galleryGeneration) {
      // The provisional firmware evidence and the final receipt disagree (or
      // the receipt is unknown). Do not retain any provisionally trusted PNG.
      _resetGallerySession();
      _scheduleStatusPoll();
      return true;
    }
    _galleryAvailabilityChanged();
    return false;
  }

  Future<T> _waitForDisplayJob<T>(
    Future<T> operation, {
    bool frame = false,
  }) async {
    _displayReadJobActive = true;
    _displayJobQueued = !frame;
    _galleryAvailabilityChanged();
    try {
      return await operation;
    } finally {
      _displayReadJobActive = false;
      _displayJobQueued = false;
      _galleryAvailabilityChanged();
    }
  }

  void _scheduleStatusPoll() {
    _statusPollTimer?.cancel();
    _statusPollTimer = null;
    if (_disposed || !_appActive || !connected || _pickingOta) return;
    _statusPollTimer = Timer(const Duration(seconds: 15), () async {
      _statusPollTimer = null;
      final client = _client;
      final generation = _galleryGeneration;
      if (!_disposed &&
          _appActive &&
          connected &&
          !_pickingOta &&
          (!busy || (_displayReadJobActive && _displayJobQueued)) &&
          !connecting &&
          !_statusPolling &&
          _pendingGalleryMutations == 0) {
        _statusPolling = true;
        try {
          final status = await client!.getStatus();
          if (!_disposed &&
              client == _client &&
              generation == _galleryGeneration) {
            _acceptDeviceStatus(status);
            if ((_deviceIdle || client.galleryReadAvailable) &&
                !busy &&
                _initialGallerySyncToken == null &&
                _galleryMetadataNeedsRefresh) {
              await _loadGallery(onlyWithoutForeground: true);
            }
            _notify();
            _scheduleGalleryBackground();
          }
        } catch (e) {
          if (!_disposed && client == _client) {
            batteryReadingStale = batteryMv != null;
            _log('空闲状态更新：$e');
            _notify();
          }
        } finally {
          _statusPolling = false;
        }
      }
      _scheduleStatusPoll();
    });
  }

  Future<void> refresh() => _job('正在读取设备', () async {
    _galleryFullAttempts.clear();
    _galleryThumbnailAttempts.clear();
    if (!demo) await _refreshInternal();
  });
  bool _sameGalleryContent(Map<String, dynamic> a, Map<String, dynamic> b) {
    final first = Map<String, dynamic>.of(a)..remove('revision');
    final second = Map<String, dynamic>.of(b)..remove('revision');
    return mapEquals(first, second);
  }

  bool _verifiedAppend(
    _GalleryAppendProof? proof,
    List<Map<String, dynamic>> items,
  ) {
    if (proof == null ||
        proof.client != _client ||
        proof.generation != _galleryGeneration ||
        proof.before.isEmpty ||
        items.length != proof.before.length + 1 ||
        _galleryMetadata.length != proof.before.length) {
      return false;
    }
    final revision = proof.before.first['revision'] as int;
    final nextRevision = revision == 0xffffffff ? 1 : revision + 1;
    for (var i = 0; i < proof.before.length; i++) {
      if (!mapEquals(_galleryMetadata[i], proof.before[i]) ||
          proof.before[i]['revision'] != revision ||
          items[i]['revision'] != nextRevision ||
          !_sameGalleryContent(proof.before[i], items[i])) {
        return false;
      }
    }
    return items.last['revision'] == nextRevision &&
        items.last['slot'] == proof.before.length;
  }

  bool _verifiedWindowAppend(
    _GalleryWindowAppendProof proof,
    Map<String, dynamic> info,
    List<Map<String, dynamic>> items,
  ) {
    if (!_windowAppendAvailable(proof) ||
        _galleryRevision != proof.revision ||
        _galleryMetadata.length != proof.before.length ||
        items.length != proof.before.length + 1 ||
        info['count'] != items.length) {
      return false;
    }
    final revision = proof.revision == 0xffffffff ? 1 : proof.revision + 1;
    if (info['revision'] != revision) return false;
    for (var i = 0; i < proof.before.length; i++) {
      if (proof.before[i]['slot'] != i ||
          proof.before[i]['revision'] != proof.revision ||
          !mapEquals(_galleryMetadata[i], proof.before[i]) ||
          items[i]['revision'] != revision ||
          !_sameGalleryContent(proof.before[i], items[i])) {
        return false;
      }
    }
    return items.last['slot'] == proof.before.length &&
        items.last['revision'] == revision;
  }

  bool _verifiedDelete(
    _GalleryDeleteProof? proof,
    Map<String, dynamic> info,
    List<Map<String, dynamic>> items,
  ) {
    if (proof == null ||
        proof.client != _client ||
        proof.generation != _galleryGeneration ||
        proof.before.isEmpty ||
        proof.slot < 0 ||
        proof.slot >= proof.before.length ||
        items.length != proof.before.length - 1 ||
        _galleryMetadata.length != proof.before.length ||
        info['count'] != items.length ||
        info['current'] != proof.current) {
      return false;
    }
    final revision = proof.before.first['revision'] as int;
    final nextRevision = revision == 0xffffffff ? 1 : revision + 1;
    if (info['revision'] != nextRevision) return false;
    for (var i = 0; i < proof.before.length; i++) {
      if (proof.before[i]['slot'] != i ||
          proof.before[i]['revision'] != revision ||
          !mapEquals(_galleryMetadata[i], proof.before[i])) {
        return false;
      }
    }
    for (var slot = 0; slot < items.length; slot++) {
      final oldSlot = slot < proof.slot ? slot : slot + 1;
      final fresh = Map<String, dynamic>.of(items[slot])
        ..remove('revision')
        ..remove('slot');
      final previous = Map<String, dynamic>.of(proof.before[oldSlot])
        ..remove('revision')
        ..remove('slot');
      if (items[slot]['slot'] != slot ||
          items[slot]['revision'] != nextRevision ||
          !mapEquals(previous, fresh)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _loadGallery({
    _GalleryAppendProof? append,
    _GalleryDeleteProof? delete,
    _GalleryWindowAppendProof? windowAppend,
    bool onlyWithoutForeground = false,
  }) async {
    final client = _client;
    final generation = _galleryGeneration;
    if (client == null) return;
    bool foregroundAcquired() =>
        onlyWithoutForeground && (_foregroundJobToken != null || _pickingOta);
    try {
      if (foregroundAcquired()) return;
      if (windowAppend != null && !_windowAppendAvailable(windowAppend)) {
        return;
      }
      final info = await client.galleryInfo();
      if (foregroundAcquired()) return;
      if (windowAppend != null && !_windowAppendAvailable(windowAppend)) {
        return;
      }
      final items = await client.galleryList();
      if (_disposed || generation != _galleryGeneration || client != _client) {
        return;
      }
      if (foregroundAcquired()) return;
      final preserveWindow =
          windowAppend != null &&
          _verifiedWindowAppend(windowAppend, info, items);
      // A failed provisional proof must not replace even one old identity.
      if (windowAppend != null && !preserveWindow) return;
      gallerySupported = true;
      galleryCapacity = info['slots'] as int? ?? 8;
      final old = {for (final item in gallery) item.slot: item};
      final previousMetadata = {
        for (final item in _galleryMetadata) item['slot']: item,
      };
      final preserveAppend = preserveWindow || _verifiedAppend(append, items);
      final preserveDelete = _verifiedDelete(delete, info, items);
      final previousFullFrames = Map<int, String>.of(_galleryFullFrames);
      final previousFullAttempts = Set<String>.of(_galleryFullAttempts);
      final previousThumbnailAttempts = Set<String>.of(
        _galleryThumbnailAttempts,
      );
      final previousStatuses = Map<int, GalleryPreviewStatus>.of(
        _galleryStatuses,
      );
      final previousIdentities = {
        for (final item in gallery) item.slot: galleryItemIdentity(item.slot),
      };
      int previousSlot(int slot) =>
          preserveDelete && slot >= delete!.slot ? slot + 1 : slot;
      _galleryMetadata = items;
      _galleryRevision =
          info['count'] == items.length &&
              items.every((item) => item['revision'] == info['revision'])
          ? info['revision'] as int?
          : null;
      _galleryMetadataNeedsRefresh = false;
      if (preserveWindow) windowAppend.migrated = true;
      gallery = items
          .map(
            (m) => GalleryItemView(
              slot: m['slot'] as int,
              title: '画面 ${(m['slot'] as int) + 1}',
              current: m['slot'] == info['current'],
              png:
                  preserveDelete ||
                      mapEquals(previousMetadata[m['slot']], m) ||
                      (preserveAppend &&
                          previousMetadata.containsKey(m['slot']))
                  ? old[previousSlot(m['slot'] as int)]?.png
                  : null,
            ),
          )
          .toList();
      if (preserveAppend) {
        for (final entry in previousFullFrames.entries) {
          if (entry.value == previousIdentities[entry.key] &&
              _galleryItem(entry.key)?.png != null) {
            _galleryFullFrames[entry.key] = galleryItemIdentity(entry.key)!;
          }
        }
      }
      if (preserveDelete) {
        _galleryFullFrames.clear();
        _galleryFullAttempts.clear();
        _galleryThumbnailAttempts.clear();
        _galleryStatuses.clear();
        _galleryStatusOwners.clear();
        for (final item in gallery) {
          final oldSlot = previousSlot(item.slot);
          final oldIdentity = previousIdentities[oldSlot];
          final identity = galleryItemIdentity(item.slot)!;
          final status = previousStatuses[oldSlot];
          final full =
              oldIdentity != null &&
              previousFullFrames[oldSlot] == oldIdentity &&
              item.png != null;
          if (full) _galleryFullFrames[item.slot] = identity;
          if (status?.loading != true) {
            if (previousFullAttempts.contains(oldIdentity)) {
              _galleryFullAttempts.add(identity);
            }
            if (previousThumbnailAttempts.contains(oldIdentity)) {
              _galleryThumbnailAttempts.add(identity);
            }
          }
          if (status != null || full) {
            _galleryStatuses[item.slot] = GalleryPreviewStatus(
              fullFrame: full,
              error: status?.loading == true ? null : status?.error,
            );
          }
        }
      }
      _galleryFullFrames.removeWhere(
        (slot, identity) =>
            galleryItemIdentity(slot) != identity ||
            _galleryItem(slot)?.png == null,
      );
      _galleryFullAttempts.removeWhere(
        (identity) =>
            !gallery.any((item) => galleryItemIdentity(item.slot) == identity),
      );
      _galleryThumbnailAttempts.removeWhere(
        (identity) =>
            !gallery.any((item) => galleryItemIdentity(item.slot) == identity),
      );
      _galleryStatuses.removeWhere((slot, _) {
        final fresh = items.where((item) => item['slot'] == slot).firstOrNull;
        return fresh == null ||
            (!preserveAppend &&
                !preserveDelete &&
                !mapEquals(previousMetadata[slot], fresh));
      });
      if (preserveAppend) {
        for (final item in gallery) {
          if (old.containsKey(item.slot)) {
            _galleryStatuses[item.slot] = GalleryPreviewStatus(
              fullFrame:
                  _galleryFullFrames[item.slot] ==
                  galleryItemIdentity(item.slot),
            );
          }
        }
      }
    } on EspInkException catch (e) {
      if (windowAppend != null) rethrow;
      if (e.status == 1) {
        gallerySupported = false;
        _resetGallerySession();
      } else {
        rethrow;
      }
    }
    _notify();
    _scheduleGalleryBackground();
  }

  Future<void> refreshGallery() => _job('正在同步图库', () async {
    _galleryFullAttempts.clear();
    _galleryThumbnailAttempts.clear();
    if (!demo) await _loadGallery();
  });

  /// Read one preview at a time. Explicit reads can enter between background
  /// thumbnails, while other device jobs keep their existing exclusive access.
  Future<GalleryPreviewResult> readGalleryPreview(
    int slot, {
    bool fullFrame = false,
    bool forceReload = false,
  }) {
    _stopGalleryBackground();
    return _queueGalleryPreview(
      slot,
      fullFrame: fullFrame,
      forceReload: forceReload,
    ).whenComplete(_scheduleGalleryBackground);
  }

  Future<GalleryPreviewResult> _queueGalleryPreview(
    int slot, {
    bool fullFrame = false,
    bool forceReload = false,
    bool background = false,
  }) {
    final identity = galleryItemIdentity(slot);
    if (_disposed || identity == null) {
      return Future.value(
        const GalleryPreviewResult(changed: true, error: '这张画面已不在当前图库，请返回并刷新'),
      );
    }
    final item = _galleryItem(slot)!;
    final cachedFull = demo || _galleryFullFrames[slot] == identity;
    if (forceReload && cachedFull) fullFrame = true;
    if (!background) _galleryFullAttempts.remove(identity);
    if ((!forceReload || demo) &&
        item.png != null &&
        (!fullFrame || cachedFull)) {
      return Future.value(
        GalleryPreviewResult(
          png: item.png,
          fullFrame: cachedFull,
          identity: identity,
        ),
      );
    }
    final suffix = background ? ':background' : '';
    final key = '$identity:${fullFrame ? 'full' : 'thumb'}$suffix';
    final pending =
        _galleryReads[key] ??
        (!fullFrame ? _galleryReads['$identity:full$suffix'] : null);
    if (pending != null) return pending;
    final generation = _galleryGeneration;
    final backgroundEpoch = _galleryBackgroundEpoch;
    final statusOwner = Object();
    _galleryStatusOwners[slot] = statusOwner;
    _galleryStatuses[slot] = GalleryPreviewStatus(
      loading: true,
      fullFrame: cachedFull,
    );
    _notify();
    final task = _galleryReadTail.then(
      (_) => _readGalleryPreview(
        slot,
        identity,
        generation,
        fullFrame,
        forceReload,
        background,
        backgroundEpoch,
        statusOwner,
      ),
    );
    _galleryReads[key] = task;
    _galleryReadTail = task.then<void>((_) {});
    unawaited(task.then<void>((_) => _galleryReads.remove(key)));
    return task;
  }

  Future<bool> _waitForGalleryIdle(
    int generation, {
    bool forRead = true,
  }) async {
    bool available() => forRead
        ? _galleryReadCanStart
        : !busy && !connecting && _activeGalleryReadToken == null;
    while (!_disposed && generation == _galleryGeneration && !available()) {
      final ready = Completer<void>();
      _galleryIdleWaiters.add(ready);
      void listener() {
        if ((_disposed || generation != _galleryGeneration || available()) &&
            !ready.isCompleted) {
          ready.complete();
        }
      }

      addListener(listener);
      listener();
      try {
        await ready.future;
      } finally {
        removeListener(listener);
        _galleryIdleWaiters.remove(ready);
      }
    }
    return !_disposed && generation == _galleryGeneration;
  }

  Future<GalleryPreviewResult> _readGalleryPreview(
    int slot,
    String identity,
    int generation,
    bool fullFrame,
    bool forceReload,
    bool background,
    int backgroundEpoch,
    Object statusOwner,
  ) async {
    for (;;) {
      try {
        return await _readGalleryPreviewAttempt(
          slot,
          identity,
          generation,
          fullFrame,
          forceReload,
          background,
          backgroundEpoch,
          statusOwner,
        );
      } on _GalleryReadDeferred {
        // The attempt released its token and, when appropriate, its own busy
        // state. Wait for a fresh device-ready signal before retrying from zero.
        if (_disposed ||
            generation != _galleryGeneration ||
            galleryItemIdentity(slot) != identity) {
          return const GalleryPreviewResult(changed: true);
        }
        if (background) {
          return GalleryPreviewResult(
            png: _galleryItem(slot)?.png,
            fullFrame: _galleryFullFrames[slot] == identity,
            identity: identity,
          );
        }
        if (identical(_galleryStatusOwners[slot], statusOwner)) {
          _galleryStatuses[slot] = GalleryPreviewStatus(
            loading: true,
            fullFrame: _galleryFullFrames[slot] == identity,
          );
          _notify();
        }
      }
    }
  }

  Future<GalleryPreviewResult> _readGalleryPreviewAttempt(
    int slot,
    String identity,
    int generation,
    bool fullFrame,
    bool forceReload,
    bool background,
    int backgroundEpoch,
    Object statusOwner,
  ) async {
    const changed = GalleryPreviewResult(
      changed: true,
      error: '图库或设备已变化，请返回图库重新打开',
    );
    void abandonQueuedRead() {
      if (_disposed ||
          generation != _galleryGeneration ||
          galleryItemIdentity(slot) != identity ||
          !identical(_galleryStatusOwners[slot], statusOwner)) {
        return;
      }
      if (background) {
        if (fullFrame) {
          _galleryFullAttempts.remove(identity);
        } else {
          _galleryThumbnailAttempts.remove(identity);
        }
      }
      _galleryStatuses[slot] = GalleryPreviewStatus(
        fullFrame: _galleryFullFrames[slot] == identity,
      );
      _notify();
    }

    while (true) {
      if ((background &&
              !_canStartGalleryBackground(generation, backgroundEpoch)) ||
          !await _waitForGalleryIdle(generation) ||
          galleryItemIdentity(slot) != identity) {
        abandonQueuedRead();
        return changed;
      }
      // Even an already-idle async wait yields a microtask. A user operation may
      // acquire the device in that gap, before this read has a cancel token.
      if (background &&
          !_canStartGalleryBackground(generation, backgroundEpoch)) {
        abandonQueuedRead();
        return changed;
      }
      if (!_galleryReadCanStart) continue;
      // There is no await between this final idle check and taking the token.
      break;
    }
    final cached = _galleryItem(slot)?.png;
    final cachedFull = demo || _galleryFullFrames[slot] == identity;
    if ((!forceReload || demo) &&
        cached != null &&
        (!fullFrame || cachedFull)) {
      _galleryStatuses[slot] = GalleryPreviewStatus(fullFrame: cachedFull);
      _notify();
      return GalleryPreviewResult(
        png: cached,
        fullFrame: cachedFull,
        identity: identity,
      );
    }
    if (demo || !connected) {
      final error = demo ? '这张演示画面暂不可用，请重新进入演示' : '设备已断开，请重新连接后重试';
      _galleryStatuses[slot] = GalleryPreviewStatus(error: error);
      _notify();
      return GalleryPreviewResult(error: error, identity: identity);
    }
    final client = _client!;
    final parallelDisplayRead = client.galleryReadAvailable;
    final deviceUpdateRevision = _galleryDeviceUpdateRevision;
    var retryAfterNewState = false;
    final listed = _galleryMetadata
        .where((item) => item['slot'] == slot)
        .firstOrNull;
    final int? expectedRevision = parallelDisplayRead
        ? (listed?['revision'] as int?)
        : null;
    final token = Object();
    final cancellation = background ? TransferCancellation() : null;
    if (background) _galleryBackgroundCancellation = cancellation;
    _activeGalleryReadBackground = background;
    final ownsBusy = !busy;
    _activeGalleryReadOwnsBusy = ownsBusy;
    _activeGalleryReadToken = token;
    if (ownsBusy) {
      busy = true;
      phase = fullFrame ? '正在读取完整画面' : '正在读取缩略图';
      progress = null;
    }
    _notify();
    try {
      Map<String, dynamic>? downloadedMetadata;
      final bytes = await client.galleryDownload(
        slot,
        thumbnail: !fullFrame,
        expectedRevision: expectedRevision,
        cancellation: cancellation,
        onMetadata: (metadata) => downloadedMetadata = metadata,
        onProgress: (value) {
          if (_disposed || generation != _galleryGeneration) return;
          if (ownsBusy) progress = value;
          _galleryStatuses[slot] = GalleryPreviewStatus(
            loading: true,
            progress: value,
            fullFrame: cachedFull,
          );
          _notify();
        },
      );
      if (_disposed || generation != _galleryGeneration || client != _client) {
        return changed;
      }
      final metadata = downloadedMetadata;
      if (metadata == null) throw StateError('图片元数据缺失，请重新同步图库');
      final current = _galleryMetadata
          .where((item) => item['slot'] == slot)
          .firstOrNull;
      if (!mapEquals(current, metadata)) {
        if (parallelDisplayRead) {
          _markGalleryReadStale(slot, identity, fullFrame, statusOwner);
          return changed;
        }
        await _loadGallery();
      }
      if (_disposed || generation != _galleryGeneration || client != _client) {
        return changed;
      }
      final fresh = _galleryMetadata
          .where((item) => item['slot'] == slot)
          .firstOrNull;
      final currentIdentity = galleryItemIdentity(slot);
      if (!mapEquals(fresh, metadata) || currentIdentity == null) {
        return changed;
      }
      Uint8List png;
      if (fullFrame) {
        if (metadata['w'] != 768 ||
            metadata['h'] != 552 ||
            metadata['len'] != 105984) {
          throw StateError('完整画面的尺寸或长度不受支持，请重新同步图库');
        }
        png = packedToPng(bytes, 768, 552);
      } else {
        final format = metadata['thumbnailFormat'];
        final width = metadata['thumbnailW'] as int;
        final height = metadata['thumbnailH'] as int;
        if (format == 1) {
          if (width < 1 || width > 200 || height < 1 || height > 150) {
            throw StateError('缩略图尺寸无效，请重新同步图库');
          }
          png = packedToPng(bytes, width, height);
        } else if (format == 2) {
          // Format 2 is the firmware's encoded JPEG. Validate the complete image
          // before exposing bytes to Image.memory, which detects encoded formats.
          final decoded = img.decodeImage(bytes);
          if (decoded == null ||
              decoded.width != width ||
              decoded.height != height) {
            throw StateError('缩略图无法解码或尺寸不符，请重试或读取完整画面');
          }
          png = bytes;
        } else {
          throw StateError('不支持的缩略图格式，请尝试读取完整画面');
        }
      }
      // Never replace a validated full-resolution frame with a later thumbnail.
      final retainedFull = _galleryFullFrames[slot] == currentIdentity;
      if (!fullFrame && retainedFull && _galleryItem(slot)?.png != null) {
        png = _galleryItem(slot)!.png!;
      }
      final isFull = fullFrame || retainedFull;
      if (isFull) _galleryFullFrames[slot] = currentIdentity;
      gallery = gallery
          .map(
            (item) => item.slot == slot
                ? GalleryItemView(
                    slot: slot,
                    title: item.title,
                    current: item.current,
                    png: png,
                  )
                : item,
          )
          .toList();
      _galleryStatuses[slot] = GalleryPreviewStatus(fullFrame: isFull);
      return GalleryPreviewResult(
        png: png,
        fullFrame: isFull,
        identity: currentIdentity,
        changed: currentIdentity != identity,
      );
    } on EspInkCancelled {
      if (fullFrame) {
        _galleryFullAttempts.remove(identity);
      } else {
        _galleryThumbnailAttempts.remove(identity);
      }
      if (!_disposed &&
          generation == _galleryGeneration &&
          galleryItemIdentity(slot) == identity &&
          identical(_galleryStatusOwners[slot], statusOwner)) {
        _galleryStatuses[slot] = GalleryPreviewStatus(fullFrame: cachedFull);
      }
      return GalleryPreviewResult(
        png: cached,
        fullFrame: cachedFull,
        identity: identity,
      );
    } catch (error) {
      if (_disposed || generation != _galleryGeneration || client != _client) {
        return changed;
      }
      if (error is EspInkException && error.status == StatusCode.busy) {
        // A late BUSY from a closed window must not overwrite a newer idle or
        // reopened-window signal. Permit one retry per new device update.
        retryAfterNewState =
            deviceUpdateRevision != _galleryDeviceUpdateRevision &&
            (_deviceIdle || client.galleryReadAvailable);
        _galleryReadBlocked = !retryAfterNewState;
        _stopGalleryBackground();
        if (fullFrame) {
          _galleryFullAttempts.remove(identity);
        } else {
          _galleryThumbnailAttempts.remove(identity);
        }
        if (parallelDisplayRead || _displayReadJobActive || !_deviceIdle) {
          if (identical(_galleryStatusOwners[slot], statusOwner)) {
            _galleryStatuses[slot] = GalleryPreviewStatus(
              loading: !background,
              fullFrame: cachedFull,
            );
          }
          // A known display window changing admission is not a failed image.
          // Foreground waits for a fresh status/window signal; background stops.
          throw _GalleryReadDeferred();
        }
      }
      if (parallelDisplayRead &&
          error is EspInkException &&
          error.status == StatusCode.stale) {
        _markGalleryReadStale(slot, identity, fullFrame, statusOwner);
        return changed;
      }
      final text = _readable(error);
      _log('读取图库 $slot：$text');
      _galleryStatuses[slot] = GalleryPreviewStatus(
        error: text,
        fullFrame: cachedFull,
      );
      return GalleryPreviewResult(error: text, identity: identity);
    } finally {
      if (identical(_activeGalleryReadToken, token)) {
        _activeGalleryReadToken = null;
        _activeGalleryReadBackground = false;
        _activeGalleryReadOwnsBusy = false;
        if (identical(_galleryBackgroundCancellation, cancellation)) {
          _galleryBackgroundCancellation = null;
        }
        if (ownsBusy && _foregroundJobToken == null) {
          busy = false;
          phase = '';
          progress = null;
        }
      }
      _notify();
      if (!background || retryAfterNewState) _scheduleGalleryBackground();
    }
  }

  void _markGalleryReadStale(
    int slot,
    String identity,
    bool fullFrame,
    Object statusOwner,
  ) {
    _galleryMetadataNeedsRefresh = true;
    if (fullFrame) {
      _galleryFullAttempts.add(identity);
    } else {
      _galleryThumbnailAttempts.add(identity);
    }
    if (identical(_galleryStatusOwners[slot], statusOwner)) {
      _galleryStatuses[slot] = GalleryPreviewStatus(
        fullFrame: _galleryFullFrames[slot] == identity,
      );
    }
    _notify();
  }

  void _stopGalleryBackground() {
    _galleryBackgroundEpoch++;
    _galleryBackgroundTimer?.cancel();
    _galleryBackgroundTimer = null;
    if (_activeGalleryReadBackground) _galleryBackgroundCancellation?.cancel();
  }

  bool _canStartGalleryBackground(int generation, int epoch) =>
      !_disposed &&
      !_pickingOta &&
      _appActive &&
      generation == _galleryGeneration &&
      epoch == _galleryBackgroundEpoch &&
      tabIndex == 1 &&
      connected &&
      _galleryReadCanStart &&
      !_statusPolling;

  void _scheduleGalleryBackground() {
    _galleryBackgroundTimer?.cancel();
    if (_disposed ||
        _pickingOta ||
        !_appActive ||
        tabIndex != 1 ||
        !connected ||
        !_galleryDeviceReadable ||
        _pendingGalleryMutations > 0) {
      return;
    }
    if (!gallery.any((item) {
      final identity = galleryItemIdentity(item.slot);
      return identity != null &&
          ((item.png == null &&
                  !_galleryThumbnailAttempts.contains(identity)) ||
              (_galleryFullFrames[item.slot] != identity &&
                  !_galleryFullAttempts.contains(identity)));
    })) {
      return;
    }
    final generation = _galleryGeneration;
    final epoch = _galleryBackgroundEpoch;
    _galleryBackgroundTimer = Timer(
      const Duration(milliseconds: 600),
      () async {
        _galleryBackgroundTimer = null;
        if (!_canStartGalleryBackground(generation, epoch)) return;
        await preloadGalleryPreviews();
        for (final item in gallery.toList()) {
          if (!_canStartGalleryBackground(generation, epoch)) break;
          final identity = galleryItemIdentity(item.slot);
          if (identity == null ||
              _galleryFullFrames[item.slot] == identity ||
              !_galleryFullAttempts.add(identity)) {
            continue;
          }
          await _queueGalleryPreview(
            item.slot,
            fullFrame: true,
            background: true,
          );
        }
      },
    );
  }

  Future<void> preloadGalleryPreviews() {
    if (_galleryPreload != null) return _galleryPreload!;
    final generation = _galleryGeneration;
    final epoch = _galleryBackgroundEpoch;
    final slots = {
      for (final item in gallery) item.slot: galleryItemIdentity(item.slot),
    };
    final task = () async {
      for (final entry in slots.entries) {
        if (_disposed ||
            generation != _galleryGeneration ||
            epoch != _galleryBackgroundEpoch ||
            tabIndex != 1 ||
            galleryItemIdentity(entry.key) != entry.value ||
            (!connected && !demo)) {
          break;
        }
        if (!demo && !_canStartGalleryBackground(generation, epoch)) break;
        if (_galleryItem(entry.key)?.png != null ||
            !_galleryThumbnailAttempts.add(entry.value!)) {
          continue;
        }
        await _queueGalleryPreview(entry.key, background: true);
      }
    }();
    _galleryPreload = task;
    unawaited(
      task.whenComplete(() {
        if (generation == _galleryGeneration) {
          _galleryPreload = null;
          _scheduleGalleryBackground();
        }
      }),
    );
    return task;
  }

  Future<void> loadGalleryPreview(int slot) async {
    final result = await readGalleryPreview(slot);
    if (result.error != null) _say(result.error!);
  }

  Future<void> loadGalleryFullFrame(int slot) async {
    final result = await readGalleryPreview(slot, fullFrame: true);
    if (result.error != null) {
      _say(result.error!);
    } else if (result.ok) {
      _say('已读取完整画面，数据校验通过');
    }
  }

  Future<void> send({bool saveGallery = false, bool storeOnly = false}) async {
    if (!_ready()) return;
    if (busy && !galleryReading) {
      _say('已有操作正在执行或等待，请完成后再发送');
      return;
    }
    if (saveGallery && !gallerySupported) {
      _say('当前固件不支持设备图库。');
      return;
    }
    if (saveGallery && gallery.length >= galleryCapacity) {
      _say('设备图库已满，请先删除不需要的画面。');
      return;
    }
    if (draft.kind == CompositionKind.photo && draft.photoBytes == null) {
      _say('请先选择一张照片');
      return;
    }
    final snapshot = draft;
    final revision = _renderRevision;
    await _job('准备画面', () async {
      final artwork = await _artworkFor(snapshot, revision);
      final frame = artwork.packed;
      _cancellation = TransferCancellation();
      _queued = false;
      if (demo) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (_cancellation!.isCancelled) throw EspInkCancelled();
        if (saveGallery) {
          gallery = [
            ...gallery.map(
              (g) => GalleryItemView(
                slot: g.slot,
                title: g.title,
                png: g.png,
                current: storeOnly && g.current,
              ),
            ),
            GalleryItemView(
              slot: gallery.length,
              title: snapshot.kind == CompositionKind.photo ? '我的照片' : '我的便签',
              png: artwork.png,
              current: !storeOnly,
            ),
          ];
        }
        _say('本地演示完成，画面未发送到设备');
        return;
      }
      final client = _client!;
      final generation = _galleryGeneration;
      final before = [
        for (final item in _galleryMetadata) Map<String, dynamic>.of(item),
      ];
      _GalleryAppendProof? proof(Map<String, dynamic>? result) {
        if (!saveGallery || !_storeConfirmsAppend(result, before.length)) {
          return null;
        }
        return _GalleryAppendProof(client, generation, before);
      }

      final windowProof =
          saveGallery &&
              !storeOnly &&
              _galleryRevision != null &&
              _foregroundJobToken != null
          ? _GalleryWindowAppendProof(
              client,
              generation,
              before,
              _galleryRevision!,
              _foregroundJobToken!,
            )
          : null;
      _galleryWindowAppend = windowProof;
      Map<String, dynamic> result;
      var invalidatedWindow = false;
      try {
        final sending = client.sendFrame(
          frame,
          saveGallery: saveGallery,
          storeOnly: storeOnly,
          cancellation: _cancellation,
          onProgress: (v) {
            progress = v;
            _notify();
          },
          onPhase: _transferPhase,
        );
        result = storeOnly
            ? await sending
            : await _waitForDisplayJob(sending, frame: true);
        invalidatedWindow = await _completeWindowAppend(windowProof, result);
      } catch (error) {
        final outcome = error is EspInkException ? error.outcome : null;
        invalidatedWindow = await _completeWindowAppend(windowProof, outcome);
        if ((outcome?['stored'] == true || invalidatedWindow) &&
            client == _client &&
            (generation == _galleryGeneration || invalidatedWindow)) {
          await _refreshInternal(
            append: invalidatedWindow ? null : proof(outcome),
          );
        }
        rethrow;
      }
      _log('作业完成：$result');
      _say(
        storeOnly
            ? '已保存到设备图库'
            : saveGallery
            ? '已保存，屏幕刷新完成'
            : '屏幕刷新完成',
      );
      await _refreshInternal(append: invalidatedWindow ? null : proof(result));
    });
  }

  void _transferPhase(TransferPhase value) {
    if (_displayReadJobActive && value == TransferPhase.queued) {
      _displayJobQueued = true;
      _galleryWindowAppend?.queued = true;
    }
    _queued = value != TransferPhase.receiving;
    phase = switch (value) {
      TransferPhase.receiving => '正在传输',
      TransferPhase.queued => '设备处理中，请耐心等待',
      TransferPhase.completed => '已完成',
      TransferPhase.finalizing => '正在校验，等待设备受理',
    };
    _notify();
    if (_displayReadJobActive) _galleryAvailabilityChanged();
  }

  void cancelTransfer() {
    if (canCancel) {
      _cancellation?.cancel();
      phase = '正在取消传输';
      _notify();
    }
  }

  Future<void> showGallery(int slot) => _job('正在刷新屏幕', () async {
    if (!demo) await _waitForDisplayJob(_client!.galleryShow(slot));
    gallery = gallery
        .map(
          (g) => GalleryItemView(
            slot: g.slot,
            title: g.title,
            png: g.png,
            current: g.slot == slot,
          ),
        )
        .toList();
    _say(demo ? '本地演示已切换画面' : '设备画面已更新');
  });
  Future<void> nextGallery() => _job('正在切换画面', () async {
    if (demo) {
      if (gallery.isEmpty) throw StateError('请先添加一张画面');
      final index = (gallery.indexWhere((g) => g.current) + 1) % gallery.length;
      gallery = [
        for (var i = 0; i < gallery.length; i++)
          GalleryItemView(
            slot: gallery[i].slot,
            title: gallery[i].title,
            png: gallery[i].png,
            current: i == index,
          ),
      ];
    } else {
      await _waitForDisplayJob(_client!.galleryNext());
      await _refreshInternal();
    }
  });
  Future<void> deleteGallery(int slot) => _job('正在删除画面', () async {
    if (demo) {
      final kept = gallery.where((g) => g.slot != slot).toList();
      _galleryGeneration++;
      _galleryStatuses.clear();
      _galleryFullFrames.clear();
      gallery = [
        for (var i = 0; i < kept.length; i++)
          GalleryItemView(
            slot: i,
            title: kept[i].title,
            png: kept[i].png,
            current: kept[i].current,
          ),
      ];
    } else {
      final client = _client!;
      final generation = _galleryGeneration;
      final before = [
        for (final item in _galleryMetadata) Map<String, dynamic>.of(item),
      ];
      final result = await client.galleryDelete(slot);
      if (_disposed || generation != _galleryGeneration || client != _client) {
        return;
      }
      final count = before.length - 1;
      final current = result['current'];
      final validCurrent =
          current == null ||
          (current is int && current >= 0 && current < count);
      final confirmed =
          result['status'] == 0 &&
          result['slot'] == slot &&
          result['count'] == count &&
          validCurrent;
      await _loadGallery(
        delete: confirmed
            ? _GalleryDeleteProof(
                client,
                generation,
                before,
                slot,
                current as int?,
              )
            : null,
      );
    }
    _say(demo ? '已从本地演示移除' : '画面已删除');
  });
  Future<void> clearGallery() => _job('正在清空图库', () async {
    if (demo) {
      _resetGallerySession();
    } else {
      await _client!.galleryClear();
      await _loadGallery();
    }
    _say(demo ? '已清空本地演示图库' : '设备图库已清空');
  });
  Future<void> showCache() => _job('正在重刷最近画面', () async {
    if (!demo) {
      await _waitForDisplayJob(_client!.cacheShow());
      await _refreshInternal();
    } else {
      _clearGalleryCurrent();
    }
    _say(demo ? '本地演示完成' : '最近画面刷新完成');
  });
  Future<void> clearGhost({int cycles = 2}) => _job('正在清理残影', () async {
    if (!demo) {
      await _waitForDisplayJob(_client!.ghostClear(cycles: cycles));
      await _refreshInternal();
    } else {
      _clearGalleryCurrent();
    }
    _say(demo ? '本地演示完成' : '残影清理完成');
  });

  void _clearGalleryCurrent() {
    gallery = gallery
        .map((g) => GalleryItemView(slot: g.slot, title: g.title, png: g.png))
        .toList();
  }

  Future<void> saveSettings(SettingsView value) => _job('正在保存设置', () async {
    final fields = <String, dynamic>{};
    if (value.name != settings.name) fields['name'] = value.name;
    if (value.panel != settings.panel) fields['panel'] = value.panel;
    if (value.sleepSeconds != settings.sleepSeconds) {
      fields['sleepS'] = value.sleepSeconds;
    }
    if (value.wakeSeconds != settings.wakeSeconds) {
      fields['autoWakeS'] = value.wakeSeconds;
    }
    if (value.timeoutAction != settings.timeoutAction) {
      fields['timeoutAction'] = value.timeoutAction;
    }
    if (value.cache != settings.cache) fields['cacheOn'] = value.cache;
    if (value.wakeShow != settings.wakeShow) {
      fields['wakeShow'] = value.wakeShow;
    }
    if (value.gpioPreset != settings.gpioPreset ||
        !listEquals(value.pins, settings.pins)) {
      fields['gpioPreset'] = value.gpioPreset;
      if (value.gpioPreset == 3) fields['pins'] = value.pins;
    }
    if (fields.isEmpty) return;
    if (demo) {
      settings = value;
      _say('已更新本地演示设置');
      return;
    }
    final result = await _client!.setSettings(fields);
    rebootRequired =
        ((result['flags'] as int? ?? 0) & 1) != 0 || rebootRequired;
    await _refreshInternal();
    _say(rebootRequired ? '设置已保存，请重启设备使引脚设置生效' : '设置已保存');
  });
  Future<void> reboot() => _job('正在重启设备', () async {
    if (demo) {
      _say('本地演示：重启');
      return;
    }
    _intentionalDisconnect = true;
    await _client!.reboot();
    rebootRequired = false;
    _say('已请求重启，请稍后重新连接');
  });
  Future<void> sleep() => _job('正在请求休眠', () async {
    if (demo) {
      _say('本地演示：休眠');
      return;
    }
    _intentionalDisconnect = true;
    await _client!.sleepNow();
    _say('已请求休眠，下次连接前请按设备按键');
  });
  Future<void> factoryReset() => _job('正在恢复设备设置', () async {
    if (demo) {
      settings = const SettingsView();
      _say('已恢复本地演示设置');
      return;
    }
    _intentionalDisconnect = true;
    await _client!.factoryReset();
    _say('已受理恢复设置，设备将重启；图库与最近画面保留。重连后读取确认。');
  });

  Future<void> pickAndUpgrade() async {
    if (_disposed || _pickingOta || !_ready()) return;
    if (demo) {
      _say('固件升级需要连接真实设备，本地演示不会传送固件。');
      return;
    }
    if (_foregroundJobToken != null || (busy && !galleryReading)) {
      _say('固件升级尚未开始，请等待当前操作完成后重试。');
      return;
    }
    if (_otaSubmitted) {
      _say('固件升级已受理，请等待设备重启后重连核对版本，暂勿重复升级。');
      return;
    }
    final client = _client!;
    if (client.resultUncertain) {
      _say('上一设备操作结果待确认。请先重新连接核对设备状态与固件版本，暂勿重复升级。');
      return;
    }
    final generation = _connectionGeneration;
    bool sameConnection() =>
        !_disposed &&
        !demo &&
        client == _client &&
        generation == _connectionGeneration;
    bool connectedSession() => sameConnection() && connected && !connecting;
    _pickingOta = true;
    _stopGalleryBackground();
    _scheduleStatusPoll();
    _notify();
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'ESP32 应用固件', extensions: ['bin']),
        ],
      );
      if (file == null || !connectedSession()) return;
      final length = await file.length();
      if (!connectedSession()) return;
      if (length < 1024 || length > 0x160000) {
        throw ArgumentError('请选择1024至1441792字节的ESP32-C3应用镜像，不要选择合并全量固件。');
      }
      final bytes = await file.readAsBytes();
      if (!connectedSession()) return;
      var started = false;
      await _job('准备升级固件', () async {
        // _job may have waited for an in-flight gallery response to drain.
        if (!connectedSession()) return;
        started = true;
        _cancellation = TransferCancellation();
        _queued = false;
        TransferPhase? otaPhase;
        try {
          await client.ota(
            bytes,
            cancellation: _cancellation,
            onProgress: (v) {
              if (!connectedSession()) return;
              progress = v;
              _notify();
            },
            onPhase: (value) {
              if (!sameConnection()) return;
              otaPhase = value;
              _queued = value != TransferPhase.receiving;
              phase = switch (value) {
                TransferPhase.receiving => '正在传输固件',
                TransferPhase.finalizing => '正在校验固件，等待设备受理',
                TransferPhase.queued => '固件已受理，等待设备重启',
                TransferPhase.completed => '固件传输已完成',
              };
              // The protocol emits queued only after a valid OTA_END RSP.
              if (value == TransferPhase.queued) _otaSubmitted = true;
              _notify();
            },
          );
          if (sameConnection()) {
            _say('固件校验已通过，设备即将重启。请重连核对版本，新固件运行约45秒后确认；期间请保持供电。');
          }
        } catch (error) {
          if (!sameConnection()) return;
          _log('固件升级：$error');
          _say(_otaError(error, otaPhase));
        }
      }, forOta: true);
      if (!started && sameConnection() && !connected) {
        _say('设备已断开，固件升级尚未开始。重新连接后再选择应用固件。');
      }
    } catch (e) {
      if (sameConnection()) {
        _log('选择固件：$e');
        _say('无法读取应用固件：${_otaError(e, null)}');
      }
    } finally {
      _pickingOta = false;
      _notify();
      _scheduleStatusPoll();
      _scheduleGalleryBackground();
    }
  }

  String _otaError(Object error, TransferPhase? phase) {
    if (error is EspInkCancelled) {
      return '固件传输已取消，设备接收会话已结束；尚未提交启动切换。';
    }
    if (error is EspInkException) {
      if (error.resultUnknown) {
        if (error.operation == '作业') {
          return '上一设备操作结果待确认。请先重新连接核对设备状态与固件版本，暂勿重复升级。';
        }
        if (phase == TransferPhase.finalizing ||
            phase == TransferPhase.queued) {
          return '固件升级提交结果待确认。请重连核对固件版本并保持供电，暂勿重复升级。';
        }
        return phase == TransferPhase.receiving
            ? '固件接收会话结束回执待确认，尚未发送启动切换提交。请重新连接后再操作。'
            : '固件升级开始回执待确认，尚未发送启动切换提交。请重新连接确认接收会话已结束后再操作。';
      }
      return switch (error.status) {
        StatusCode.busy => '设备正忙，固件升级未受理。请等待当前设备作业结束后再试。',
        StatusCode.otaVerify => '固件镜像校验失败。请核对应用 .bin、设备型号与当前分区布局。',
        StatusCode.crc => '固件传输校验失败，升级未受理。请核对应用文件并重新连接。',
        StatusCode.flashError => '固件写入失败。请保持供电并重新连接核对设备状态。',
        StatusCode.lengthMismatch => '固件长度不符，升级未受理。请重新选择完整的应用 .bin。',
        StatusCode.unsupported => '当前设备或连接不支持此固件升级操作，请核对固件版本与 MTU。',
        StatusCode.noMem => '设备资源不足，固件升级未完成。请重新连接核对设备状态。',
        _ =>
          phase == TransferPhase.finalizing
              ? '固件提交未获确认。请重新连接核对固件版本，暂勿重复升级。'
              : '固件传输中断，尚未确认升级受理。请重新连接后核对设备状态。',
      };
    }
    if (phase == TransferPhase.finalizing) {
      return '固件提交结果待确认。请重新连接核对固件版本，暂勿重复升级。';
    }
    return error
        .toString()
        .replaceFirst('Invalid argument(s): ', '')
        .replaceFirst('Exception: ', '');
  }

  bool _ready() {
    if (connected || demo) return true;
    _say('请先连接设备，也可以先体验本地创作。');
    return false;
  }

  Future<void> _job(
    String label,
    Future<void> Function() body, {
    bool forOta = false,
  }) async {
    if (_pickingOta && !forOta) {
      _say('正在选择、读取或传送固件，请先完成或取消当前升级流程。');
      return;
    }
    if (_foregroundJobToken != null) {
      _say('设备正在处理其他操作，请稍后重试');
      return;
    }
    _stopGalleryBackground();
    if (_activeGalleryReadToken != null) {
      if (_pendingGalleryMutations > 0) {
        _say('已有操作在等待当前读图完成，请稍后重试');
        return;
      }
      final generation = _galleryGeneration;
      _pendingGalleryMutations++;
      _notify();
      try {
        if (!await _waitForGalleryIdle(generation, forRead: false)) return;
      } finally {
        _pendingGalleryMutations--;
        _notify();
      }
    }
    if (busy) {
      _say('设备正在处理其他操作，请稍后重试');
      return;
    }
    if (!_ready()) return;
    final jobToken = Object();
    _foregroundJobToken = jobToken;
    busy = true;
    phase = label;
    progress = null;
    _queued = false;
    _notify();
    try {
      await body();
    } on EspInkCancelled {
      _say('传输已取消，设备接收会话已结束。');
    } catch (e) {
      _log('$label：$e');
      _say(_readable(e));
    } finally {
      if (identical(_foregroundJobToken, jobToken)) {
        _foregroundJobToken = null;
        busy = false;
        phase = '';
        progress = null;
        _cancellation = null;
        _queued = false;
        _galleryAvailabilityChanged(deviceUpdate: _deviceIdle);
      }
    }
  }

  String _readable(Object e) {
    if (e is EspInkException) {
      if (e.outcome != null) {
        final outcome = e.outcome!;
        final parts = <String>[];
        if (outcome['stored'] == true) parts.add('图片已保存到图库');
        if (outcome['stored'] == false) parts.add('保存未成功');
        if (outcome['displayed'] == true) parts.add('屏幕已刷新');
        if (outcome['displayed'] == false) parts.add('显示作业未正常完成');
        parts.add(
          e.resultUnknown ? '其余结果待确认，请重新连接并核对，勿重复追加。' : '请读取设备状态与图库核对结果。',
        );
        return parts.join('；');
      }
      if (e.resultUnknown) return '作业结果待确认。请读取设备状态和图库，勿直接重复操作。${e.message}';
      final hint = switch (e.status) {
        4 => '设备正忙，请等待当前作业结束后重试。',
        7 => '图片数据长度不符，请重新生成画面。',
        8 => '数据校验失败，请重新处理图片后再试。',
        11 => '设备存储出错，结果可能已经改变。请重启设备后重新读取确认。',
        12 => '固件校验失败，请核对应用镜像与设备型号。',
        13 => '设备还没有可用的缓存或画面。',
        14 => '当前连接或固件不支持此操作，请重新连接并检查固件版本。',
        15 => '设备图库已满，请先删除不需要的画面。',
        16 => '设备图库已变化，请重新同步后再试。',
        _ => e.message,
      };
      if (e.outcome != null) {
        return '$hint 保存与显示可能有不同结果，请重新读取设备图库。';
      }
      return hint;
    }
    return e
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('Bad state: ', '');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (!_appActive) {
      _stopGalleryBackground();
      _statusPollTimer?.cancel();
      _statusPollTimer = null;
      _previewDebounce?.cancel();
      _previewDebounce = null;
      _requestedPreviewRevision = null;
    } else {
      _scheduleInkPreview();
      _scheduleGalleryBackground();
      _scheduleStatusPoll();
    }
    if (busy && state == AppLifecycleState.paused) {
      _log('APP进入后台，正在执行的蓝牙作业可能被系统暂停');
    }
    if (state == AppLifecycleState.resumed &&
        connected &&
        !busy &&
        !_pickingOta) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _previewDebounce = null;
    _resetGallerySession();
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    unawaited(_deviceEvents?.cancel());
    unawaited(_galleryReadiness?.cancel());
    unawaited(_client?.dispose());
    unawaited(_ble.dispose());
    super.dispose();
  }
}

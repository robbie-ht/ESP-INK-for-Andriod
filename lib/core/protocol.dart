import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'frame_codec.dart';
import 'transport.dart';

const serviceUuid = '6d6f496e-4b00-4000-8000-000000000000';
const ctrlUuid = '6d6f496e-4b00-4000-8000-000000000001';
const dataUuid = '6d6f496e-4b00-4000-8000-000000000002';
const evtUuid = '6d6f496e-4b00-4000-8000-000000000003';

abstract final class Op {
  static const ping = 0x01,
      getStatus = 0x02,
      getSettings = 0x03,
      setSettings = 0x04;
  static const frameBegin = 0x10, frameEnd = 0x12, frameAbort = 0x13;
  static const cacheShow = 0x20,
      cacheInfo = 0x21,
      galleryInfo = 0x22,
      galleryShow = 0x23,
      galleryDelete = 0x24,
      galleryClear = 0x25,
      galleryList = 0x26,
      galleryRead = 0x27,
      ghostClear = 0x30;
  static const otaBegin = 0x40, otaEnd = 0x42, otaAbort = 0x43;
  static const reboot = 0x50, factoryReset = 0x51, sleepNow = 0x52;
}

abstract final class StatusCode {
  static const ok = 0,
      unknownOp = 1,
      badArg = 2,
      badState = 3,
      busy = 4,
      noMem = 5,
      geometry = 6,
      lengthMismatch = 7,
      crc = 8,
      incomplete = 9,
      seqGap = 10,
      flashError = 11,
      otaVerify = 12,
      notReady = 13,
      unsupported = 14,
      full = 15,
      stale = 16;
}

const statusNames = <int, String>{
  0: 'OK',
  1: 'UNKNOWN_OP',
  2: 'BAD_ARG',
  3: 'BAD_STATE',
  4: 'BUSY',
  5: 'NO_MEM',
  6: 'GEOMETRY',
  7: 'LEN_MISMATCH',
  8: 'CRC',
  9: 'INCOMPLETE',
  10: 'SEQ_GAP',
  11: 'FLASH_ERROR',
  12: 'OTA_VERIFY',
  13: 'NOT_READY',
  14: 'UNSUPPORTED',
  15: 'FULL',
  16: 'STALE',
};

abstract final class EventId {
  static const displayDone = 1,
      button = 2,
      lowBattery = 3,
      state = 4,
      transferGap = 5,
      storeDone = 6;
}

class EspInkEvent {
  const EspInkEvent(this.id, this.arg, this.payload);
  final int id, arg;
  final Uint8List payload;
}

enum TransferPhase { receiving, finalizing, queued, completed }

class TransferCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class EspInkException implements Exception {
  EspInkException(
    this.operation,
    this.message, {
    this.status,
    this.resultUnknown = false,
    Uint8List? detail,
    this.outcome,
  }) : detail = detail ?? Uint8List(0);
  final String operation, message;
  final int? status;
  final bool resultUnknown;
  final Uint8List detail;

  /// Independently observed store/display results, when available.
  final Map<String, dynamic>? outcome;
  @override
  String toString() =>
      '$operation: $message${status == null ? '' : ' (${statusNames[status] ?? status})'}';
}

class EspInkCancelled extends EspInkException {
  EspInkCancelled() : super('传输', '接收已中止');
}

class _Reply {
  const _Reply(this.status, this.payload);
  final int status;
  final Uint8List payload;
}

class _Pending {
  _Pending(this.op, this.sideEffect, this.completer, this.timer);
  final String op;
  final bool sideEffect;
  final Completer<_Reply> completer;
  final Timer timer;
}

/// Completion errors are values until awaited: an early disconnect cannot
/// produce an unhandled asynchronous error before the command RSP arrives.
class _EventOutcome {
  _EventOutcome.event(this.event) : error = null;
  _EventOutcome.error(this.error) : event = null;
  final EspInkEvent? event;
  final EspInkException? error;
}

class _Waiter {
  _Waiter(this.id, this.accepted);
  final int id;
  final Set<int>? accepted;
  final done = Completer<_EventOutcome>();
}

/// One client per connected link. Recreate after disconnect or an uncertain
/// modifying operation. No command is automatically resent after a missing RSP.
class EspInkClient {
  EspInkClient(
    this.transport, {
    this.commandTimeout = const Duration(seconds: 15),
    this.completionTimeout = const Duration(seconds: 900),
    this.mutationTimeout = const Duration(seconds: 60),
    this.maxRetries = 8,
  }) {
    _notifications = transport.notifications.listen(
      _onNotification,
      onError: (Object _) => _lostConnection(),
      onDone: _lostConnection,
    );
    _connection = transport.connectionChanges.listen((connected) {
      if (!connected) _lostConnection();
    });
  }

  final EspInkTransport transport;
  final Duration commandTimeout, completionTimeout, mutationTimeout;
  final int maxRetries;
  late final StreamSubscription<Uint8List> _notifications;
  late final StreamSubscription<bool> _connection;
  final _events = StreamController<EspInkEvent>.broadcast();
  final Map<int, _Pending> _pending = {};
  final Set<int> _retiredSequences = {};
  final List<_Waiter> _waiters = [];
  final _disconnected = Completer<void>();
  Future<void> _ctrlTail = Future.value();
  Future<void> _jobTail = Future.value();
  Future<void> _galleryReadTail = Future.value();
  final _galleryReadiness = StreamController<void>.broadcast(sync: true);
  int _pendingJobs = 0;
  bool _requiresGalleryWindow = false;
  bool _localDisplayWait = false;
  bool _firmwareGalleryReadReady = false;
  bool _firmwareGalleryReadSupported = false;
  bool _firmwareGalleryAppendCommitted = false;
  int _windowRevision = 0;
  int? _reportedState;

  /// Only a firmware-advertised physical display window can overlap a job.
  /// Idle gallery reads use their normal lane and do not require this feature.
  bool get galleryReadAvailable =>
      !_closed &&
      _firmwareGalleryReadReady &&
      (_pendingJobs == 0 || (_pendingJobs == 1 && _localDisplayWait));
  bool get galleryAppendCommitted =>
      galleryReadAvailable && _firmwareGalleryAppendCommitted;
  Stream<void> get galleryReadinessChanges => _galleryReadiness.stream;

  void _readinessChanged() {
    if (!_closed) _galleryReadiness.add(null);
  }

  void _acceptGalleryWindow(int state, int flags) {
    _firmwareGalleryReadSupported = (flags & 1) != 0;
    _firmwareGalleryReadReady =
        _firmwareGalleryReadSupported &&
        (flags & 2) != 0 &&
        (state == 3 || state == 4);
    _firmwareGalleryAppendCommitted =
        _firmwareGalleryReadReady && (flags & 4) != 0;
    _readinessChanged();
  }

  void _displayWait(bool waiting) {
    _localDisplayWait = waiting;
    _readinessChanged();
  }

  var _seq = 0;
  var _closed = false;
  var _uncertain = false;
  int? _gapAt;
  bool _receivingData = false;
  Stream<EspInkEvent> get events => _events.stream;
  int get mtu => transport.mtu;
  bool get resultUncertain => _uncertain;
  // Android caps the entire characteristic value at 512 bytes, including the
  // two-byte DATA sequence number. Keep the negotiated MTU truthful.
  int get chunkSize => math.min(mtu - 5, 510);

  void _checkLink() {
    if (_closed || !transport.isConnected) {
      throw EspInkException('连接', '连接已断开，请重新连接');
    }
  }

  void _lostConnection() {
    if (_closed) return;
    _closed = true;
    _disconnected.complete();
    for (final p in _pending.values) {
      p.timer.cancel();
      p.completer.completeError(
        EspInkException(p.op, '连接已断开，结果待确认', resultUnknown: p.sideEffect),
      );
    }
    _pending.clear();
    for (final w in _waiters) {
      if (!w.done.isCompleted) {
        w.done.complete(
          _EventOutcome.error(
            EspInkException('作业', '完成通知缺失，结果待确认', resultUnknown: true),
          ),
        );
      }
    }
  }

  Future<void> dispose() async {
    _lostConnection();
    await _notifications.cancel();
    await _connection.cancel();
    await _events.close();
    await _galleryReadiness.close();
  }

  Future<void> disconnect() async {
    _lostConnection();
    await transport.disconnect();
  }

  void _onNotification(Uint8List bytes) {
    if (_closed || bytes.length < 3) return;
    if (bytes[0] == 1) {
      final pending = _pending.remove(bytes[1]);
      if (pending != null) {
        pending.timer.cancel();
        pending.completer.complete(
          _Reply(bytes[2], Uint8List.fromList(bytes.sublist(3))),
        );
      }
      return;
    }
    if (bytes[0] != 0x81) return;
    final event = EspInkEvent(
      bytes[1],
      bytes[2],
      Uint8List.fromList(bytes.sublist(3)),
    );
    if (_receivingData &&
        event.id == EventId.transferGap &&
        event.payload.length == 2) {
      _gapAt = _u16(event.payload, 0);
    }
    for (final waiter in List<_Waiter>.of(_waiters)) {
      if (!waiter.done.isCompleted &&
          waiter.id == event.id &&
          (waiter.accepted == null || waiter.accepted!.contains(event.arg))) {
        waiter.done.complete(_EventOutcome.event(event));
      }
    }
    if (event.id == EventId.state) {
      _windowRevision++;
      _reportedState = event.arg;
      _acceptGalleryWindow(
        event.arg,
        event.payload.isEmpty ? 0 : event.payload[0],
      );
    } else if (event.id == EventId.displayDone) {
      _windowRevision++;
      _reportedState = 0;
      _firmwareGalleryReadReady = false;
      _readinessChanged();
    }
    _events.add(event);
  }

  Future<T> _exclusive<T>(Future<T> Function() action) {
    // Snapshot only preceding reads. Later reads wait behind this job unless
    // this exact job reaches an advertised display-only window.
    final precedingReads = _galleryReadTail;
    _pendingJobs++;
    final result = _jobTail
        .then((_) async {
          await precedingReads;
          _checkLink();
          // An earlier display window cannot authorize the next mutation job.
          _firmwareGalleryReadReady = false;
          _windowRevision++;
          if (_uncertain) {
            throw EspInkException(
              '作业',
              '上一操作结果待确认，请重新连接并核对设备后再操作',
              resultUnknown: true,
            );
          }
          try {
            return await action();
          } on EspInkException catch (e) {
            if (e.resultUnknown) _uncertain = true;
            rethrow;
          }
        })
        .whenComplete(() {
          _pendingJobs--;
          _readinessChanged();
        });
    _jobTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    // Publish the barrier before a synchronous listener can queue a read.
    _readinessChanged();
    return result;
  }

  Future<T> _galleryRead<T>(Future<T> Function() action) {
    final windowRead = galleryReadAvailable;
    final jobs = windowRead ? Future<void>.value() : _jobTail;
    final precedingReads = _galleryReadTail;
    final result = () async {
      await jobs;
      await precedingReads;
      _checkLink();
      _requiresGalleryWindow = windowRead;
      try {
        return await action();
      } finally {
        _requiresGalleryWindow = false;
      }
    }();
    _galleryReadTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _checkGalleryReadWindow() {
    _checkLink();
    // A close event drains the RSP already in flight before the next block.
    // Mutations stay queued behind the complete read future.
    if (_requiresGalleryWindow && !_firmwareGalleryReadReady) {
      throw EspInkException(
        'CAROUSEL_READ',
        '屏幕作业暂时关闭读图窗口',
        status: StatusCode.busy,
      );
    }
  }

  Future<_Reply> _command(
    int op, [
    List<int> args = const [],
    bool sideEffect = false,
  ]) {
    final result = _ctrlTail.then((_) {
      _checkLink();
      if (args.length + 2 > mtu - 3) {
        throw EspInkException('MTU', '当前MTU不足以发送完整命令，请协商更大MTU');
      }
      int? available;
      for (var attempt = 0; attempt < 256; attempt++) {
        _seq = (_seq + 1) & 255;
        if (!_retiredSequences.contains(_seq)) {
          available = _seq;
          break;
        }
      }
      if (available == null) throw EspInkException('连接', '响应超时过多，请重新连接');
      final seq = available;
      final name = '0x${op.toRadixString(16)}';
      final done = Completer<_Reply>();
      final timer = Timer(commandTimeout, () {
        final pending = _pending.remove(seq);
        if (pending != null) {
          // Retire timed-out sequences so a late RSP cannot match after wraparound.
          _retiredSequences.add(seq);
          if (sideEffect) _uncertain = true;
          done.completeError(
            EspInkException(
              name,
              '响应超时${sideEffect ? '，结果待确认' : ''}',
              resultUnknown: sideEffect,
            ),
          );
        }
      });
      _pending[seq] = _Pending(name, sideEffect, done, timer);
      Future<void>.sync(
        () => transport.writeCtrl(Uint8List.fromList([op, seq, ...args])),
      ).catchError((Object error) {
        final pending = _pending.remove(seq);
        if (pending != null) {
          timer.cancel();
          _retiredSequences.add(seq);
          done.completeError(
            EspInkException(name, '写入失败：$error', resultUnknown: sideEffect),
          );
        }
      });
      return done.future;
    });
    _ctrlTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Uint8List> _call(
    int op, [
    List<int> args = const [],
    bool sideEffect = false,
  ]) async {
    final reply = await _command(op, args, sideEffect);
    if (reply.status != 0) {
      throw EspInkException(
        '0x${op.toRadixString(16)}',
        '设备拒绝操作',
        status: reply.status,
        detail: reply.payload,
      );
    }
    return reply.payload;
  }

  _Waiter _arm(int id, [Set<int>? accepted]) {
    final waiter = _Waiter(id, accepted);
    _waiters.add(waiter);
    return waiter;
  }

  Future<EspInkEvent> _awaitEvent(_Waiter waiter, Duration timeout) async {
    final outcome = await waiter.done.future.timeout(
      timeout,
      onTimeout: () => _EventOutcome.error(
        EspInkException('作业', '完成等待超时，结果待确认', resultUnknown: true),
      ),
    );
    if (outcome.error != null) throw outcome.error!;
    return outcome.event!;
  }

  Future<Map<String, dynamic>> ping() async {
    final p = await _call(Op.ping);
    _need(p, 2, 'PING');
    _need(p, 2 + p[1], 'PING');
    if (p[0] != 1) throw EspInkException('PING', '不支持的协议版本 ${p[0]}');
    return {'api': p[0], 'version': ascii.decode(p.sublist(2, 2 + p[1]))};
  }

  Future<Map<String, dynamic>> getStatus() async {
    final windowRevision = _windowRevision;
    final p = await _call(Op.getStatus);
    _need(p, 27, 'GET_STATUS');
    _need(p, 27 + p[26], 'GET_STATUS');
    final battery = ByteData.sublistView(p).getInt16(3, Endian.little);
    final extension = 27 + p[26];
    if (windowRevision == _windowRevision) {
      _reportedState = p[1];
      _acceptGalleryWindow(p[1], p.length > extension ? p[extension] : 0);
    }
    // A STATE/DISPLAY_DONE received after this request is newer than its RSP.
    final state = _reportedState ?? p[1];
    return {
      'galleryReadSupported': _firmwareGalleryReadSupported,
      'galleryReadReady': _firmwareGalleryReadReady,
      'galleryAppendCommitted':
          _firmwareGalleryAppendCommitted && _firmwareGalleryReadReady,
      'api': p[0],
      'stateCode': state,
      'state':
          const {
            0: 'idle',
            1: 'recv_frame',
            2: 'recv_ota',
            3: 'refreshing',
            4: 'clearing',
            6: 'sleeping',
          }[state] ??
          'unknown',
      'panel': p[2],
      'batteryMv': battery > 0 ? battery : null,
      'uptimeS': _u32(p, 5),
      'heapFree': _u32(p, 9),
      'mtu': _u16(p, 13),
      'wakeReason': p[15],
      'sleepS': _u32(p, 16),
      'timeoutAction': p[20],
      'autoWakeS': _u32(p, 21),
      'cacheValid': p[25] == 1,
      'version': ascii.decode(p.sublist(27, 27 + p[26])),
    };
  }

  Future<Map<String, dynamic>> getSettings() async {
    final p = await _call(Op.getSettings);
    _need(p, 21, 'GET_SETTINGS');
    _need(p, 21 + p[20], 'GET_SETTINGS');
    return {
      'panel': p[0],
      'sleepS': _u32(p, 1),
      'timeoutAction': p[5],
      'autoWakeS': _u32(p, 6),
      'gpioPreset': p[10],
      'pins': p.sublist(11, 19),
      'cacheOn': p[19] == 1,
      'name': utf8.decode(p.sublist(21, 21 + p[20])),
      'wakeShow': p.length > 21 + p[20] && p[21 + p[20]] == 1,
      'wakeShowSupported': p.length > 21 + p[20],
    };
  }

  Future<Map<String, dynamic>> setSettings(Map<String, dynamic> settings) =>
      _exclusive(() async {
        final args = encodeSettings(settings);
        final p = await _call(Op.setSettings, args, true);
        _need(p, 4, 'SET_SETTINGS');
        return {'applied': p[0], 'errId': p[1], 'errCode': p[2], 'flags': p[3]};
      });

  Future<Map<String, dynamic>> cacheInfo() async {
    final p = await _call(Op.cacheInfo);
    _need(p, 11, 'CACHE_INFO');
    return {
      'valid': p[0] == 1,
      'w': _u16(p, 1),
      'h': _u16(p, 3),
      'crc16': _u16(p, 5),
      'len': _u32(p, 7),
    };
  }

  Future<Map<String, dynamic>> galleryInfo() async {
    final p = await _call(Op.galleryInfo);
    _exact(p, 7, 'CAROUSEL_INFO');
    if (p[0] > p[2] || p[2] > 8 || (p[1] != 255 && p[1] >= p[0])) {
      throw EspInkException('CAROUSEL_INFO', '无效的图库元数据');
    }
    return {
      'count': p[0],
      'current': p[1] == 255 ? null : p[1],
      'slots': p[2],
      'revision': _u32(p, 3),
    };
  }

  Future<List<Map<String, dynamic>>> galleryList() =>
      _galleryRead(_galleryList);
  Future<List<Map<String, dynamic>>> _galleryList({
    TransferCancellation? cancellation,
  }) async {
    _checkCancellation(cancellation);
    _checkGalleryReadWindow();
    final info = await galleryInfo();
    _checkCancellation(cancellation);
    final count = info['count'] as int, revision = info['revision'] as int;
    final items = <Map<String, dynamic>>[];
    while (items.length < count) {
      _checkCancellation(cancellation);
      final start = items.length;
      _checkGalleryReadWindow();
      final p = await _call(Op.galleryList, [start, count - start]);
      _checkCancellation(cancellation);
      _need(p, 6, 'CAROUSEL_LIST');
      if (_u32(p, 0) != revision) {
        throw EspInkException(
          'CAROUSEL_LIST',
          '图库版本变化，已丢弃本次列表，请重新加载',
          status: StatusCode.stale,
        );
      }
      final returned = p[5];
      if (p[4] != start ||
          returned == 0 ||
          returned > count - start ||
          p.length != 6 + returned * 22) {
        throw EspInkException('CAROUSEL_LIST', '分页长度或偏移不合法');
      }
      for (var i = 0; i < returned; i++) {
        final o = 6 + i * 22;
        if (p[o] != start + i) {
          throw EspInkException('CAROUSEL_LIST', '图库条目次序不合法');
        }
        items.add({
          'slot': p[o],
          'w': _u16(p, o + 1),
          'h': _u16(p, o + 3),
          'len': _u32(p, o + 5),
          'crc16': _u16(p, o + 9),
          'thumbnailFormat': p[o + 11],
          'thumbnailW': _u16(p, o + 12),
          'thumbnailH': _u16(p, o + 14),
          'thumbnailLen': _u32(p, o + 16),
          'thumbnailCrc16': _u16(p, o + 20),
          'revision': revision,
        });
      }
    }
    return items;
  }

  Future<Uint8List> galleryDownload(
    int slot, {
    bool thumbnail = false,
    int? expectedRevision,
    TransferCancellation? cancellation,
    void Function(double)? onProgress,
    void Function(Map<String, dynamic>)? onMetadata,
  }) => _galleryRead(() async {
    _checkCancellation(cancellation);
    _range(slot, 0, 7, 'slot');
    final items = await _galleryList(cancellation: cancellation);
    _checkCancellation(cancellation);
    final found = items.where((item) => item['slot'] == slot);
    if (found.isEmpty) {
      throw EspInkException(
        'CAROUSEL_READ',
        '图片不存在',
        status: StatusCode.notReady,
      );
    }
    final item = found.first;
    if (expectedRevision != null && item['revision'] != expectedRevision) {
      throw EspInkException(
        'CAROUSEL_READ',
        '图库版本变化，请等待同步完成',
        status: StatusCode.stale,
      );
    }
    final total = item[thumbnail ? 'thumbnailLen' : 'len'] as int;
    final expectedCrc = item[thumbnail ? 'thumbnailCrc16' : 'crc16'] as int;
    final format = thumbnail ? item['thumbnailFormat'] as int : 1;
    if (total <= 0 || total > (thumbnail ? 20000 : frameLength)) {
      throw EspInkException('CAROUSEL_READ', '不合法的载荷长度');
    }
    final data = Uint8List(total);
    var offset = 0;
    while (offset < total) {
      _checkCancellation(cancellation);
      // The EVT value is capped at 512 bytes even when MTU is 517.
      // Reserve 3 bytes for RSP and 13 for gallery metadata; ATT uses 3 more.
      final requested = math.min(
        math.min(mtu - 19, 512 - 3 - 13),
        total - offset,
      );
      if (requested <= 0) throw EspInkException('CAROUSEL_READ', 'MTU不足');
      final args = Uint8List(12);
      final v = ByteData.sublistView(args);
      args[0] = slot;
      args[1] = thumbnail ? 1 : 0;
      v.setUint32(2, offset, Endian.little);
      v.setUint16(6, requested, Endian.little);
      v.setUint32(8, item['revision'] as int, Endian.little);
      _checkGalleryReadWindow();
      final p = await _call(Op.galleryRead, args);
      // Drain any already-sent request before releasing the job queue. A read
      // has no device-side transaction to ABORT, and its reply must not leak
      // into the following foreground command.
      _checkCancellation(cancellation);
      _need(p, 14, 'CAROUSEL_READ');
      final block = p.sublist(13);
      if (p[0] != slot ||
          p[1] != args[1] ||
          _u32(p, 2) != offset ||
          _u32(p, 6) != total ||
          _u16(p, 10) != expectedCrc ||
          p[12] != format ||
          block.length > requested ||
          offset + block.length > total) {
        throw EspInkException('CAROUSEL_READ', '下载身份、偏移或元数据不一致，已丢弃部分数据');
      }
      data.setRange(offset, offset + block.length, block);
      offset += block.length;
      _progress(onProgress, offset / total);
      _checkCancellation(cancellation);
    }
    if (crc16(data) != expectedCrc) {
      throw EspInkException(
        'CAROUSEL_READ',
        '下载CRC不一致',
        status: StatusCode.crc,
      );
    }
    onMetadata?.call(Map<String, dynamic>.unmodifiable(item));
    return data;
  });

  Future<void> _display(int op, List<int> args, int success) =>
      _exclusive(() async {
        final waiter = _arm(EventId.displayDone, {1, success});
        try {
          await _call(op, args, true);
          _displayWait(true);
          final event = await _awaitEvent(waiter, completionTimeout);
          _exact(event.payload, 0, 'DISPLAY_DONE');
          if (event.arg == 1) {
            throw EspInkException(
              '显示',
              '作业未正常完成，屏幕可能已变化',
              status: StatusCode.notReady,
            );
          }
        } finally {
          _displayWait(false);
          _waiters.remove(waiter);
        }
      });
  Future<void> cacheShow() => _display(Op.cacheShow, [], 3);
  Future<void> galleryShow(int slot) {
    if (slot != 255) _range(slot, 0, 7, 'slot');
    return _display(Op.galleryShow, [slot], 4);
  }

  Future<void> galleryNext() => galleryShow(255);
  Future<void> ghostClear({int cycles = 2}) {
    _range(cycles, 1, 4, 'cycles');
    return _display(Op.ghostClear, [cycles], 2);
  }

  Future<Map<String, dynamic>> _store(int op, List<int> args) =>
      _exclusive(() async {
        final waiter = _arm(EventId.storeDone);
        try {
          await _call(op, args, true);
          final event = await _awaitEvent(waiter, mutationTimeout);
          final result = _storeResult(event);
          if (event.arg != 0) {
            throw EspInkException(
              '图库',
              '存储作业失败',
              status: event.arg,
              outcome: result,
            );
          }
          return result;
        } finally {
          _waiters.remove(waiter);
        }
      });
  Future<Map<String, dynamic>> galleryDelete(int slot) {
    _range(slot, 0, 7, 'slot');
    return _store(Op.galleryDelete, [slot]);
  }

  Future<Map<String, dynamic>> galleryClear() => _store(Op.galleryClear, []);

  Future<Map<String, dynamic>> sendFrame(
    Uint8List frame, {
    bool saveCache = true,
    bool saveGallery = false,
    bool storeOnly = false,
    Uint8List? thumbnail,
    int thumbnailFormat = 1,
    int thumbnailW = 192,
    int thumbnailH = 138,
    TransferCancellation? cancellation,
    void Function(double)? onProgress,
    void Function(TransferPhase)? onPhase,
  }) => _exclusive(() async {
    if (frame.length != frameLength) {
      throw ArgumentError('整帧必须是768×552、105984字节');
    }
    if (storeOnly && !saveGallery) throw ArgumentError('只保存必须启用图库');
    final thumb = thumbnail ?? Uint8List(0);
    _validateThumbnail(
      thumb,
      saveGallery,
      thumbnailFormat,
      thumbnailW,
      thumbnailH,
    );
    if (cancellation?.isCancelled ?? false) throw EspInkCancelled();
    final args = Uint8List(thumb.isEmpty ? 13 : 24),
        data = Uint8List(frame.length + thumb.length);
    data.setAll(0, frame);
    data.setAll(frame.length, thumb);
    final v = ByteData.sublistView(args);
    args[0] = (saveCache ? 0 : 1) | (saveGallery ? 2 : 0) | (storeOnly ? 4 : 0);
    v.setUint16(1, frameWidth, Endian.little);
    v.setUint16(3, frameHeight, Endian.little);
    v.setUint32(5, frame.length, Endian.little);
    v.setUint16(9, crc16(frame), Endian.little);
    v.setUint16(11, chunkSize, Endian.little);
    if (thumb.isNotEmpty) {
      args[13] = thumbnailFormat;
      v.setUint16(14, thumbnailW, Endian.little);
      v.setUint16(16, thumbnailH, Endian.little);
      v.setUint32(18, thumb.length, Endian.little);
      v.setUint16(22, crc16(thumb), Endian.little);
    }
    var receiving = false;
    Map<String, dynamic>? observed;
    _Waiter? store, display;
    try {
      final begin = await _call(Op.frameBegin, args, true);
      receiving = true;
      final chunk = _negotiatedChunk(begin, data.length);
      _phase(onPhase, TransferPhase.receiving);
      // Register before END, retain both results even if either is an error.
      store = saveGallery ? _arm(EventId.storeDone) : null;
      display = storeOnly ? null : _arm(EventId.displayDone, {0, 1});
      await _transfer(
        data,
        chunk,
        Op.frameEnd,
        cancellation,
        onProgress,
        beforeEnd: () {
          receiving = false;
          _phase(onPhase, TransferPhase.finalizing);
        },
        resume: () {
          receiving = true;
          _phase(onPhase, TransferPhase.receiving);
        },
      );
      if (!storeOnly) _displayWait(true);
      _phase(onPhase, TransferPhase.queued);
      final result = <String, dynamic>{
        'queued': true,
        'stored': null,
        'displayed': null,
      };
      observed = result;
      final budget = Stopwatch()..start();
      Duration remaining() => completionTimeout - budget.elapsed;
      if (store != null) {
        final e = await _awaitEvent(store, remaining());
        result['store'] = _storeResult(e);
        result['storeStatus'] = e.arg;
        result['stored'] = e.arg == 0;
      }
      if (display != null) {
        // Firmware sends DISPLAY_DONE failure also when storage failed; do not
        // return early and accidentally associate it with the following job.
        final e = await _awaitEvent(display, remaining());
        _exact(e.payload, 0, 'DISPLAY_DONE');
        result['displayResult'] = e.arg;
        result['displayed'] = e.arg == 0;
      }
      if (result['stored'] == false || result['displayed'] == false) {
        throw EspInkException(
          '图片作业',
          '存储与显示结果请分别核对',
          status: result['stored'] == false
              ? result['storeStatus'] as int
              : StatusCode.notReady,
          outcome: result,
        );
      }
      _phase(onPhase, TransferPhase.completed);
      return result;
    } catch (e) {
      if (receiving) await _abortReceiving(Op.frameAbort, e is EspInkCancelled);
      if (observed != null && e is EspInkException && e.outcome == null) {
        throw EspInkException(
          e.operation,
          e.message,
          status: e.status,
          detail: e.detail,
          resultUnknown: true,
          outcome: Map.of(observed),
        );
      }
      rethrow;
    } finally {
      _displayWait(false);
      _receivingData = false;
      if (store != null) _waiters.remove(store);
      if (display != null) _waiters.remove(display);
    }
  });

  /// Checks the B2 size bound and ESP32-C3 application image structure.
  /// Segment bounds, the first segment's app descriptor and the checksum/hash
  /// storage must exist. This does not verify their checksum/hash values,
  /// cryptographic authenticity, hardware settings or partition compatibility.
  static void validateOtaImage(Uint8List image) {
    if (image.length < 1024 || image.length > 0x160000) {
      throw ArgumentError('应用镜像应为1024..1441792字节');
    }
    if (image[0] != 0xe9 || _u16(image, 12) != 5) {
      throw ArgumentError('需要ESP32-C3应用镜像，不能使用合并固件');
    }
    final segmentCount = image[1];
    if (segmentCount < 1 || segmentCount > 16 || image[23] > 1) {
      throw ArgumentError('ESP应用镜像头无效，请选择完整的应用bin');
    }
    var offset = 24; // esp_image_header_t, followed by 8-byte segment headers.
    for (var segment = 0; segment < segmentCount; segment++) {
      if (offset > image.length - 8) {
        throw ArgumentError('应用镜像段头被截断，请重新获取完整文件');
      }
      final length = _u32(image, offset + 4);
      offset += 8;
      if (length > image.length - offset) {
        throw ArgumentError('应用镜像段数据被截断，请重新获取完整文件');
      }
      // IDF puts esp_app_desc_t (256 bytes) at the start of the first segment.
      // Bootloaders share E9/chip_id but do not contain this app descriptor.
      if (segment == 0 && (length < 256 || _u32(image, offset) != 0xabcd5432)) {
        throw ArgumentError('需要ESP32-C3应用bin，不能使用bootloader、分区表或合并固件');
      }
      offset += length;
    }
    // ESP's checksum occupies the final byte of a 16-byte aligned block.
    // A header with hash_appended=1 additionally needs its 32-byte SHA256 field.
    final requiredLength = (offset | 15) + 1 + (image[23] == 1 ? 32 : 0);
    if (requiredLength > image.length) {
      throw ArgumentError('应用镜像校验尾部被截断，请重新获取完整文件');
    }
  }

  Future<void> ota(
    Uint8List image, {
    TransferCancellation? cancellation,
    void Function(double)? onProgress,
    void Function(TransferPhase)? onPhase,
  }) => _exclusive(() async {
    validateOtaImage(image);
    if (cancellation?.isCancelled ?? false) throw EspInkCancelled();
    final args = Uint8List(10), v = ByteData(10);
    v.setUint32(0, image.length, Endian.little);
    v.setUint32(4, crc32(image), Endian.little);
    v.setUint16(8, chunkSize, Endian.little);
    args.setAll(0, v.buffer.asUint8List());
    var receiving = false;
    try {
      final begin = await _call(Op.otaBegin, args, true);
      receiving = true;
      final chunk = _negotiatedChunk(begin, image.length);
      _phase(onPhase, TransferPhase.receiving);
      await _transfer(
        image,
        chunk,
        Op.otaEnd,
        cancellation,
        onProgress,
        beforeEnd: () {
          receiving = false;
          _phase(onPhase, TransferPhase.finalizing);
        },
        resume: () {
          receiving = true;
          _phase(onPhase, TransferPhase.receiving);
        },
      );
      // Accepted boot-slot selection, not permanent OTA confirmation.
      _phase(onPhase, TransferPhase.queued);
    } catch (e) {
      if (receiving) await _abortReceiving(Op.otaAbort, e is EspInkCancelled);
      rethrow;
    } finally {
      _receivingData = false;
    }
  });

  int _negotiatedChunk(Uint8List p, int length) {
    _exact(p, 4, 'BEGIN');
    final chunk = _u16(p, 0), maximum = _u16(p, 2);
    // The firmware may advertise a 512-byte capability even though this app
    // requests at most 510. Only the selected chunk must fit our write limit.
    if (chunk < 16 ||
        chunk > chunkSize ||
        chunk > maximum ||
        maximum > math.min(mtu - 5, 512)) {
      throw EspInkException('BEGIN', '设备返回了不合法的分片长度');
    }
    if ((length + chunk - 1) ~/ chunk > 65536) {
      throw EspInkException('BEGIN', '分片超过65536，需更大MTU');
    }
    return chunk;
  }

  Future<void> _transfer(
    Uint8List data,
    int chunk,
    int end,
    TransferCancellation? cancellation,
    void Function(double)? onProgress, {
    required void Function() beforeEnd,
    required void Function() resume,
  }) async {
    final total = (data.length + chunk - 1) ~/ chunk;
    var index = 0, retries = 0;
    _gapAt = null;
    _receivingData = true;
    void retry(int expected) {
      if (++retries > maxRetries || expected < 0 || expected >= total) {
        throw EspInkException(
          '传输',
          '恢复次数超限或设备返回非法分片号',
          status: StatusCode.seqGap,
        );
      }
      index = expected;
    }

    for (;;) {
      while (index < total) {
        _checkLink();
        if (cancellation?.isCancelled ?? false) throw EspInkCancelled();
        if (_gapAt != null) {
          final gap = _gapAt!;
          _gapAt = null;
          if (gap > index) throw EspInkException('传输', '设备请求尚未发送的分片');
          if (gap < index) retry(gap);
        }
        final finish = math.min((index + 1) * chunk, data.length);
        final packet = Uint8List(2 + finish - index * chunk);
        ByteData.sublistView(packet).setUint16(0, index, Endian.little);
        packet.setRange(2, packet.length, data, index * chunk);
        await Future.any<void>([
          transport.writeData(packet),
          _disconnected.future.then((_) {
            throw EspInkException('传输', '接收中断线，会话已丢弃');
          }),
        ]).timeout(
          commandTimeout,
          onTimeout: () {
            throw EspInkException('传输', '数据写入超时');
          },
        );
        index++;
        _progress(onProgress, finish / data.length);
        if (index % 32 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      // A gap in the final write still needs recovery before END.
      if (_gapAt != null) {
        final gap = _gapAt!;
        _gapAt = null;
        retry(gap);
        continue;
      }
      if (cancellation?.isCancelled ?? false) throw EspInkCancelled();
      beforeEnd(); // Sending END makes queue/boot-slot outcome uncertain.
      final reply = await _command(end, [], true);
      if (reply.status == StatusCode.ok) {
        if (end == Op.frameEnd) {
          if (reply.payload.length != 1 || reply.payload[0] != 1) {
            throw EspInkException(
              'FRAME_END',
              '排队回执无效，结果待确认',
              resultUnknown: true,
            );
          }
        } else {
          if (reply.payload.isNotEmpty) {
            throw EspInkException(
              'OTA_END',
              '校验回执无效，启动槽结果待确认',
              resultUnknown: true,
            );
          }
        }
        _receivingData = false;
        return;
      }
      if (reply.status == StatusCode.incomplete) {
        resume();
        _exact(reply.payload, 2, 'END INCOMPLETE');
        retry(_u16(reply.payload, 0));
        continue;
      }
      if (end == Op.frameEnd && reply.status == StatusCode.crc) {
        resume();
        _exact(reply.payload, 2, 'FRAME_END CRC');
        retry(0);
        continue;
      }
      if (end == Op.frameEnd &&
          (reply.status == StatusCode.badArg ||
              reply.status == StatusCode.busy)) {
        resume();
      }
      throw EspInkException(
        'END',
        '设备未接受传输',
        status: reply.status,
        detail: reply.payload,
        resultUnknown: end == Op.otaEnd && reply.status == StatusCode.noMem,
      );
    }
  }

  Future<void> _abortReceiving(int op, bool cancellation) async {
    if (_closed || !transport.isConnected) {
      if (cancellation) throw EspInkException('取消', '连接已断开，无法确认中止');
      return;
    }
    try {
      await _call(op, [], true);
    } catch (e) {
      if (cancellation) {
        throw EspInkException('取消', '中止回执缺失或失败，结果待确认', resultUnknown: true);
      }
    }
  }

  Future<void> abortFrame() =>
      _exclusive(() => _call(Op.frameAbort, [], true).then((_) {}));
  Future<void> abortOta() =>
      _exclusive(() => _call(Op.otaAbort, [], true).then((_) {}));
  Future<void> reboot({int delayS = 1}) {
    _range(delayS, 0, 10, 'delayS');
    return _exclusive(() => _call(Op.reboot, [delayS], true).then((_) {}));
  }

  Future<void> factoryReset() =>
      _exclusive(() => _call(Op.factoryReset, [], true).then((_) {}));
  Future<void> sleepNow() =>
      _exclusive(() => _call(Op.sleepNow, [], true).then((_) {}));
}

Map<String, dynamic> _storeResult(EspInkEvent event) {
  _exact(event.payload, 3, 'STORE_DONE');
  return {
    'status': event.arg,
    'slot': event.payload[0],
    'count': event.payload[1],
    'current': event.payload[2] == 255 ? null : event.payload[2],
  };
}

void _validateThumbnail(Uint8List p, bool gallery, int format, int w, int h) {
  if (p.isEmpty) return;
  if (!gallery ||
      w < 1 ||
      h < 1 ||
      w > 65535 ||
      h > 65535 ||
      p.length > 20000 ||
      frameLength + p.length + 64 > 131072) {
    throw ArgumentError('不合法的缩略图参数或槽容量超限');
  }
  if (format == 1) {
    if (w % 4 != 0 || w > 200 || h > 150 || p.length != w * h ~/ 4) {
      throw ArgumentError('packed2bpp缩略图尺寸/长度错误');
    }
  } else if (format == 2) {
    if (p.length < 4 ||
        p[0] != 255 ||
        p[1] != 216 ||
        p[p.length - 2] != 255 ||
        p.last != 217) {
      throw ArgumentError('JPEG缩略图首尾标记错误');
    }
  } else {
    throw ArgumentError('不支持的缩略图格式');
  }
}

/// Validates the whole transaction before encoding; no silently truncated fields.
Uint8List encodeSettings(Map<String, dynamic> settings) {
  const ids = {
    'panel': 1,
    'sleepS': 2,
    'timeoutAction': 3,
    'autoWakeS': 4,
    'name': 5,
    'gpioPreset': 6,
    'pins': 7,
    'cacheOn': 8,
    'wakeShow': 9,
  };
  if (settings.isEmpty || settings.keys.any((key) => !ids.containsKey(key))) {
    throw ArgumentError('设置为空或包含未知字段');
  }
  final out = BytesBuilder();
  for (final entry in settings.entries) {
    final key = entry.key, value = entry.value;
    List<int> bytes;
    if (key == 'name') {
      if (value is! String || value.codeUnits.any((c) => c < 32 || c == 127)) {
        throw ArgumentError('名称包含控制字符');
      }
      bytes = utf8.encode(value);
      if (bytes.length > 20 || utf8.decode(bytes) != value) {
        throw ArgumentError('名称须为有效UTF-8且不超过20字节');
      }
    } else if (key == 'pins') {
      if (value is! List || value.length != 8 || settings['gpioPreset'] != 3) {
        throw ArgumentError('自定义引脚须为8项并同时指定gpioPreset=3');
      }
      bytes = [];
      for (var i = 0; i < 8; i++) {
        final pin = value[i];
        if (pin is! int) throw ArgumentError('GPIO须为整数');
        _range(pin, 0, i == 0 ? 4 : (i == 1 ? 5 : 10), 'GPIO');
        bytes.add(pin);
      }
      if (bytes.contains(2) || bytes.toSet().length != 8) {
        throw ArgumentError('GPIO2保留且引脚不得重复');
      }
    } else if (key == 'cacheOn' || key == 'wakeShow') {
      if (value is! bool) throw ArgumentError('$key须为布尔值');
      bytes = [value ? 1 : 0];
    } else {
      if (value is! int) throw ArgumentError('$key须为整数');
      final wide = key == 'sleepS' || key == 'autoWakeS';
      _range(value, 0, wide ? 0xffffffff : (key == 'gpioPreset' ? 3 : 1), key);
      if (wide) {
        final b = ByteData(4)..setUint32(0, value, Endian.little);
        bytes = b.buffer.asUint8List();
      } else {
        bytes = [value];
      }
    }
    out.add([ids[key]!, bytes.length]);
    out.add(bytes);
  }
  return out.takeBytes();
}

void _range(int value, int min, int max, String field) {
  if (value < min || value > max) throw ArgumentError('$field须在$min..$max范围内');
}

int _u16(Uint8List p, int offset) =>
    ByteData.sublistView(p).getUint16(offset, Endian.little);
int _u32(Uint8List p, int offset) =>
    ByteData.sublistView(p).getUint32(offset, Endian.little);
void _need(Uint8List p, int n, String operation) {
  if (p.length < n) throw EspInkException(operation, '响应长度不足');
}

void _exact(Uint8List p, int n, String operation) {
  if (p.length != n) throw EspInkException(operation, '响应长度错误');
}

void _checkCancellation(TransferCancellation? cancellation) {
  if (cancellation?.isCancelled ?? false) throw EspInkCancelled();
}

void _progress(void Function(double)? handler, double progress) {
  // Presentation callback failures must never abort an accepted hardware job.
  try {
    handler?.call(progress);
  } catch (_) {}
}

void _phase(void Function(TransferPhase)? handler, TransferPhase phase) {
  try {
    handler?.call(phase);
  } catch (_) {}
}

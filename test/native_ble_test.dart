import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:esp_ink/core/native_ble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methodChannel = MethodChannel('io.github.robbieht.espink/ble');
  const eventChannel = EventChannel('io.github.robbieht.espink/ble_events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late NativeBle ble;
  late List<String> calls;
  MockStreamHandlerEventSink? eventSink;
  var autoReady = true;
  var cancellations = 0;
  Future<Object?> Function(MethodCall)? methodHandler;

  Future<void> flushMessages() => Future<void>.delayed(Duration.zero);

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    ble = NativeBle();
    calls = [];
    autoReady = true;
    eventSink = null;
    cancellations = 0;
    methodHandler = null;
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (_, sink) {
          eventSink = sink;
          if (autoReady) sink.success({'type': 'ready'});
        },
        onCancel: (_) => cancellations++,
      ),
    );
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call.method);
      if (methodHandler != null) return methodHandler!(call);
      if (call.method == 'connect') return {'mtu': 517};
      return null;
    });
  });

  tearDown(() async {
    await ble.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'dispose cancels a connect waiting for native event readiness',
    () async {
      autoReady = false;
      final connect = ble.connect('AA:BB:CC:DD:EE:FF');
      final failed = expectLater(
        connect,
        throwsA(
          isA<NativeBleException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await flushMessages();
      expect(eventSink, isNotNull);
      final firstDispose = ble.dispose();
      final secondDispose = ble.dispose();
      expect(identical(firstDispose, secondDispose), isTrue);
      await firstDispose;
      await failed;
      expect(calls, isNot(contains('connect')));
      expect(cancellations, 1);
      expect(ble.isConnected, isFalse);
    },
  );

  test(
    'a late connect success cannot revive a disconnected transport',
    () async {
      final reply = Completer<Object?>();
      methodHandler = (call) async {
        if (call.method == 'connect') return reply.future;
        return null;
      };
      final connect = ble.connect('AA:BB:CC:DD:EE:FF');
      final failed = expectLater(
        connect,
        throwsA(
          isA<NativeBleException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await flushMessages();
      expect(calls, contains('connect'));
      await ble.disconnect();
      reply.complete({'mtu': 517});
      await failed;
      expect(ble.isConnected, isFalse);
      expect(ble.mtu, 23);
    },
  );

  test(
    'scan cancellation before readiness never starts the native scan',
    () async {
      autoReady = false;
      final scan = ble.startScan();
      final failed = expectLater(
        scan,
        throwsA(
          isA<NativeBleException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await flushMessages();
      await ble.stopScan();
      eventSink!.success({'type': 'ready'});
      await failed;
      expect(calls, isNot(contains('startScan')));
    },
  );

  test('permission refusal preserves the native readable message', () async {
    methodHandler = (call) async {
      if (call.method == 'startScan') {
        throw PlatformException(
          code: 'permission_denied',
          message: '需要“附近的设备”权限，请在系统设置中允许。',
        );
      }
      return null;
    };
    await expectLater(
      ble.startScan(),
      throwsA(
        isA<NativeBleException>()
            .having((e) => e.code, 'code', 'permission_denied')
            .having((e) => e.toString(), 'message', contains('附近的设备')),
      ),
    );
    expect(ble.isConnected, isFalse);
  });

  test(
    'unsupported platforms return a useful error without platform calls',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(ble.supported, isFalse);
      await expectLater(
        ble.startScan(),
        throwsA(
          isA<NativeBleException>().having(
            (e) => e.code,
            'code',
            'unsupported_platform',
          ),
        ),
      );
      await ble.disconnect();
      expect(calls, isEmpty);
      expect(eventSink, isNull);
    },
  );

  test('MTU, notifications and stopped scans follow native events', () async {
    final received = <Uint8List>[];
    final notificationSubscription = ble.notifications.listen(received.add);
    await ble.connect('AA:BB:CC:DD:EE:FF');
    expect(ble.isConnected, isTrue);
    expect(ble.mtu, 517);
    eventSink!.success({
      'type': 'notification',
      'value': Uint8List.fromList([0x81, 0x00, 0x00]),
    });
    eventSink!.success({'type': 'scanState', 'scanning': true});
    await flushMessages();
    expect(received.single, [0x81, 0x00, 0x00]);
    expect(ble.isScanning, isTrue);
    eventSink!.success({'type': 'scanState', 'scanning': false});
    eventSink!.success({'type': 'connection', 'connected': false, 'mtu': 23});
    await flushMessages();
    expect(ble.isConnected, isFalse);
    expect(ble.mtu, 23);
    expect(ble.isScanning, isFalse);
    await notificationSubscription.cancel();
  });

  test('write validates MTU and propagates a disconnect failure', () async {
    await ble.connect('AA:BB:CC:DD:EE:FF');
    await expectLater(
      ble.writeData(Uint8List(515)),
      throwsA(isA<NativeBleException>()),
    );
    expect(calls, isNot(contains('writeData')));
    methodHandler = (call) async {
      if (call.method == 'writeCtrl') {
        throw PlatformException(code: 'disconnected', message: '蓝牙已断开，请重新连接。');
      }
      return null;
    };
    await expectLater(
      ble.writeCtrl(Uint8List.fromList([1, 0])),
      throwsA(
        isA<NativeBleException>().having((e) => e.code, 'code', 'disconnected'),
      ),
    );
  });

  test('MTU 517 limits complete CTRL and DATA values to 512 bytes', () async {
    await ble.connect('AA:BB:CC:DD:EE:FF');
    final written = <int>[];
    methodHandler = (call) async {
      if (call.method == 'writeCtrl' || call.method == 'writeData') {
        written.add((call.arguments as Uint8List).length);
      }
      return null;
    };
    await ble.writeCtrl(Uint8List(512));
    await ble.writeData(Uint8List(512));
    await expectLater(
      ble.writeCtrl(Uint8List(513)),
      throwsA(isA<NativeBleException>()),
    );
    await expectLater(
      ble.writeData(Uint8List(513)),
      throwsA(isA<NativeBleException>()),
    );
    expect(written, [512, 512]);
    expect(ble.mtu, 517);
    expect(ble.isConnected, isTrue);
  });

  test('smaller MTU still caps complete values below 512 bytes', () async {
    methodHandler = (call) async {
      if (call.method == 'connect') return {'mtu': 185};
      return null;
    };
    await ble.connect('AA:BB:CC:DD:EE:FF');
    await ble.writeCtrl(Uint8List(182));
    await ble.writeData(Uint8List(182));
    await expectLater(
      ble.writeCtrl(Uint8List(183)),
      throwsA(isA<NativeBleException>()),
    );
    await expectLater(
      ble.writeData(Uint8List(183)),
      throwsA(isA<NativeBleException>()),
    );
    expect(calls.where((call) => call == 'writeCtrl').length, 1);
    expect(calls.where((call) => call == 'writeData').length, 1);
  });
}

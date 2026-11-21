import 'dart:async';
import 'dart:io';

import 'package:esp_ink/app/controller.dart';
import 'package:esp_ink/app/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _photo(int red, int green) {
  final image = img.Image(width: 3, height: 2);
  img.fill(image, color: img.ColorRgb8(red, green, 30));
  return Uint8List.fromList(img.encodePng(image));
}

/// Exercises the real ImagePicker method-channel adapter and XFile disk read.
/// This does not launch Android's picker or simulate activity destruction.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late EspInkController controller;
  late Directory temporary;
  late File selectedFile, recoveredFile, emptyFile;
  late Uint8List selectedBytes, recoveredBytes;
  late ComposerDraft original;
  late List<MethodCall> calls;
  Future<Object?> Function(MethodCall)? handler;

  Map<String, Object> lostPhoto(File file) => {
    'type': 'image',
    'path': file.path,
    'pathList': [file.path],
  };

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    await Directory('build').create(recursive: true);
    temporary = await Directory('build').createTemp('photo-picker-controller-');
    selectedBytes = _photo(210, 40);
    recoveredBytes = _photo(30, 220);
    selectedFile = await File('${temporary.path}/selected.png')
        .writeAsBytes(selectedBytes);
    recoveredFile = await File('${temporary.path}/recovered.png')
        .writeAsBytes(recoveredBytes);
    emptyFile = await File('${temporary.path}/empty.png').writeAsBytes([]);
    calls = [];
    handler = null;
    messenger.setMockMethodCallHandler(pickerChannel, (call) async {
      calls.add(call);
      if (handler != null) return handler!(call);
      return call.method == 'pickImage' ? selectedFile.path : null;
    });
    controller = EspInkController();
    original = ComposerDraft(
      kind: CompositionKind.note,
      photoBytes: _photo(70, 80),
      zoom: 2.5,
      rotation: 18,
      quarterTurns: 1,
      mirror: true,
      offsetX: .2,
      offsetY: -.3,
      background: 2,
    );
    controller.updateDraft(original);
  });

  tearDown(() async {
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(pickerChannel, null);
    debugDefaultTargetPlatformOverride = null;
    await temporary.delete(recursive: true);
  });

  test(
    'accepted system photo returns true and resets only photo geometry',
    () async {
      expect(await controller.pickPhoto(), isTrue);
      expect(controller.draft.kind, CompositionKind.photo);
      expect(controller.draft.photoBytes, orderedEquals(selectedBytes));
      expect(controller.draft.zoom, 1);
      expect(controller.draft.rotation, 0);
      expect(controller.draft.quarterTurns, 0);
      expect(controller.draft.mirror, isFalse);
      expect(controller.draft.offsetX, 0);
      expect(controller.draft.offsetY, 0);
      expect(controller.draft.background, original.background);
      expect(controller.pickingPhoto, isFalse);
      expect(controller.recoveredPhotoNeedsAdjustment, isFalse);
      expect(calls.single.method, 'pickImage');
      expect(calls.single.arguments, containsPair('source', 1));
      expect(calls.single.arguments, containsPair('maxWidth', 2048.0));
      expect(calls.single.arguments, containsPair('maxHeight', 2048.0));
      expect(calls.single.arguments, containsPair('imageQuality', 95));
    },
  );

  test(
    'system picker cancellation returns false without changing the draft',
    () async {
      handler = (_) async => null;
      expect(await controller.pickPhoto(), isFalse);
      expect(controller.draft, same(original));
      expect(controller.pickingPhoto, isFalse);
      handler = null;
      expect(
        await controller.pickPhoto(),
        isTrue,
        reason: 'A cancelled picker must release its re-entry guard',
      );
    },
  );

  test('empty photo fails without discarding the existing draft', () async {
    handler = (_) async => emptyFile.path;
    expect(await controller.pickPhoto(), isFalse);
    expect(controller.draft, same(original));
    expect(controller.message, contains('图片文件为空'));
    expect(controller.pickingPhoto, isFalse);
  });

  test(
    'unreadable photo fails without discarding the existing draft',
    () async {
      handler = (_) async => '${temporary.path}/missing.png';
      expect(await controller.pickPhoto(), isFalse);
      expect(controller.draft, same(original));
      expect(controller.message, contains('无法打开这张照片'));
      expect(controller.pickingPhoto, isFalse);
    },
  );

  test(
    'over-limit photo fails without discarding the existing draft',
    () async {
      final oversized = File('${temporary.path}/oversized.png');
      final opened = await oversized.open(mode: FileMode.write);
      await opened.truncate(24 * 1024 * 1024 + 1);
      await opened.close();
      handler = (_) async => oversized.path;
      expect(await controller.pickPhoto(), isFalse);
      expect(controller.draft, same(original));
      expect(controller.message, contains('24 MB'));
      expect(controller.pickingPhoto, isFalse);
    },
  );

  test(
    'platform picker exception preserves the draft and releases the guard',
    () async {
      handler = (_) async => throw PlatformException(
        code: 'photo_access_denied',
        message: 'test denial',
      );
      expect(await controller.pickPhoto(), isFalse);
      expect(controller.draft, same(original));
      expect(controller.message, contains('无法打开这张照片'));
      expect(controller.pickingPhoto, isFalse);
      handler = null;
      expect(await controller.pickPhoto(), isTrue);
    },
  );

  test(
    'a concurrent pick returns false and opens only one system picker',
    () async {
      final reply = Completer<Object?>();
      final opened = Completer<void>();
      handler = (call) {
        if (call.method == 'pickImage') {
          opened.complete();
          return reply.future;
        }
        return Future.value();
      };
      final first = controller.pickPhoto();
      await opened.future;
      expect(controller.pickingPhoto, isTrue);
      expect(await controller.pickPhoto(), isFalse);
      expect(controller.draft, same(original));
      expect(calls.where((call) => call.method == 'pickImage'), hasLength(1));
      reply.complete(selectedFile.path);
      expect(await first, isTrue);
      expect(controller.draft.photoBytes, orderedEquals(selectedBytes));
      expect(controller.pickingPhoto, isFalse);
    },
  );

  test(
    'Android lost photo is accepted and adjustment navigation is consumed once',
    () async {
      handler = (call) async => call.method == 'retrieve'
          ? lostPhoto(recoveredFile)
          : selectedFile.path;
      await controller.init();
      expect(calls.map((call) => call.method), ['retrieve']);
      expect(controller.draft.photoBytes, orderedEquals(recoveredBytes));
      expect(controller.recoveredPhotoNeedsAdjustment, isTrue);
      expect(controller.consumeRecoveredPhotoAdjustment(), isTrue);
      expect(controller.consumeRecoveredPhotoAdjustment(), isFalse);
      expect(controller.recoveredPhotoNeedsAdjustment, isFalse);
    },
  );

  test(
    'a normal selection clears an unconsumed recovered-photo navigation',
    () async {
      handler = (call) async => call.method == 'retrieve'
          ? lostPhoto(recoveredFile)
          : selectedFile.path;
      await controller.init();
      expect(controller.recoveredPhotoNeedsAdjustment, isTrue);
      expect(await controller.pickPhoto(), isTrue);
      expect(controller.draft.photoBytes, orderedEquals(selectedBytes));
      expect(controller.recoveredPhotoNeedsAdjustment, isFalse);
      expect(controller.consumeRecoveredPhotoAdjustment(), isFalse);
    },
  );

  test(
    'late Android recovery cannot overwrite a newer normal selection',
    () async {
      final recovery = Completer<Object?>();
      final retrieving = Completer<void>();
      handler = (call) {
        if (call.method == 'retrieve') {
          retrieving.complete();
          return recovery.future;
        }
        return Future.value(selectedFile.path);
      };
      final initializing = controller.init();
      await retrieving.future;
      expect(await controller.pickPhoto(), isTrue);
      recovery.complete(lostPhoto(recoveredFile));
      await initializing;
      expect(controller.draft.photoBytes, orderedEquals(selectedBytes));
      expect(controller.recoveredPhotoNeedsAdjustment, isFalse);
      expect(controller.consumeRecoveredPhotoAdjustment(), isFalse);
      expect(calls.map((call) => call.method), ['retrieve', 'pickImage']);
    },
  );

  test('normal picker completing after recovery wins and clears duplicate navigation', () async {
    final picked = Completer<Object?>();
    final opening = Completer<void>();
    handler = (call) {
      if (call.method == 'pickImage') {
        opening.complete();
        return picked.future;
      }
      return Future.value(lostPhoto(recoveredFile));
    };
    final picking = controller.pickPhoto();
    await opening.future;
    await controller.init();
    expect(controller.draft.photoBytes, orderedEquals(recoveredBytes));
    expect(controller.recoveredPhotoNeedsAdjustment, isTrue);
    picked.complete(selectedFile.path);
    expect(await picking, isTrue);
    expect(controller.draft.photoBytes, orderedEquals(selectedBytes));
    expect(controller.recoveredPhotoNeedsAdjustment, isFalse);
    expect(controller.consumeRecoveredPhotoAdjustment(), isFalse);
  });

  test(
    'an explicit note choice supersedes a pending Android photo recovery',
    () async {
      final recovery = Completer<Object?>();
      final retrieving = Completer<void>();
      handler = (call) {
        if (call.method == 'retrieve') {
          retrieving.complete();
          return recovery.future;
        }
        return Future.value(selectedFile.path);
      };
      controller.updateDraft(
        original.copyWith(
          kind: CompositionKind.photo,
          photoTexts: [TextLayer(id: 'photo', text: '保留照片文字')],
          noteTexts: [TextLayer(id: 'note', text: '保留便签文字')],
        ),
      );
      final initializing = controller.init();
      await retrieving.future;
      final before = controller.draft;
      final expected = before.toJson()..['kind'] = CompositionKind.note.index;
      controller.selectNoteComposition();
      expect(controller.draft.kind, CompositionKind.note);
      recovery.complete(lostPhoto(recoveredFile));
      await initializing;
      expect(controller.draft.toJson(), expected);
      expect(controller.draft.photoBytes, same(before.photoBytes));
      expect(controller.draft.photoTexts, same(before.photoTexts));
      expect(controller.draft.noteTexts, same(before.noteTexts));
      expect(controller.recoveredPhotoNeedsAdjustment, isFalse);
      expect(controller.consumeRecoveredPhotoAdjustment(), isFalse);
      expect(calls.map((call) => call.method), ['retrieve']);
    },
  );

  test('choosing note clears recovered navigation while preserving the photo draft', () async {
    handler = (call) async => call.method == 'retrieve'
        ? lostPhoto(recoveredFile)
        : selectedFile.path;
    await controller.init();
    expect(controller.recoveredPhotoNeedsAdjustment, isTrue);
    controller.updateDraft(
      controller.draft.copyWith(
        zoom: 2.2,
        rotation: 14,
        mirror: true,
        photoTexts: [TextLayer(id: 'photo', text: '照片里的文字')],
        noteTexts: [TextLayer(id: 'note', text: '便签里的文字')],
      ),
    );
    final before = controller.draft;
    final expected = before.toJson()..['kind'] = CompositionKind.note.index;
    controller.selectNoteComposition();
    expect(controller.draft.toJson(), expected);
    expect(controller.draft.photoBytes, same(before.photoBytes));
    expect(controller.draft.photoBytes, orderedEquals(recoveredBytes));
    expect(controller.draft.photoTexts, same(before.photoTexts));
    expect(controller.draft.noteTexts, same(before.noteTexts));
    expect(controller.draft.adjustments, same(before.adjustments));
    expect(controller.recoveredPhotoNeedsAdjustment, isFalse);
    expect(controller.consumeRecoveredPhotoAdjustment(), isFalse);
  });

  test(
    'choosing note enables its saved text after photo overlays were hidden',
    () {
      controller.updateDraft(
        original.copyWith(
          kind: CompositionKind.photo,
          textEnabled: false,
          photoTexts: [TextLayer(id: 'photo-hidden', text: '保留照片叠加文字')],
          noteTexts: [TextLayer(id: 'note-visible', text: '重新显示已有便签文字')],
        ),
      );
      final before = controller.draft;
      final expected = before.toJson()
        ..['kind'] = CompositionKind.note.index
        ..['textEnabled'] = true;
      controller.selectNoteComposition();
      expect(controller.draft.toJson(), expected);
      expect(controller.draft.kind, CompositionKind.note);
      expect(controller.draft.textEnabled, isTrue);
      expect(controller.draft.textLayers.single.text, '重新显示已有便签文字');
      expect(controller.draft.photoTexts, same(before.photoTexts));
      expect(controller.draft.noteTexts, same(before.noteTexts));
      expect(controller.draft.photoBytes, same(before.photoBytes));
      expect(controller.draft.adjustments, same(before.adjustments));
    },
  );
}

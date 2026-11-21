import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ImageExportException implements Exception {
  const ImageExportException(this.message, {this.code = 'save_failed'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

const _channel = MethodChannel('app.moink/image_export');
const _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
const _pngEnd = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];

/// Saves a complete PNG supplied by a user action.
///
/// The result is a ready-to-display message. Web only acknowledges that the
/// browser download was requested, since browser download completion is opaque.
/// Desktop dialog cancellation throws [ImageExportException] with `cancelled`.
Future<String> saveGalleryImage(
  Uint8List png, {
  required String fileName,
}) async {
  if (png.length < 45 ||
      png.length > 16 * 1024 * 1024 ||
      !_matches(png, 0, _pngSignature) ||
      !_matches(png, png.length - _pngEnd.length, _pngEnd)) {
    throw const ImageExportException(
      '图片数据无效，请重新读取完整画面后再保存。',
      code: 'invalid_image',
    );
  }
  final name = fileName.trim();
  if (name.length < 5 ||
      name.startsWith('.') ||
      !name.toLowerCase().endsWith('.png') ||
      utf8.encode(name).length > 160 ||
      RegExp(r'[\x00-\x1f\x7f/\\<>:"|?*]').hasMatch(name)) {
    throw const ImageExportException(
      '图片文件名无效，请使用简短的 PNG 文件名。',
      code: 'invalid_filename',
    );
  }

  try {
    if (kIsWeb) {
      // cross_file's HTML implementation creates a Blob URL and clicks an
      // anchor with its download attribute set to XFile.name.
      await XFile.fromData(png, mimeType: 'image/png', name: name).saveTo(name);
      return '已发起下载：$name（请查看浏览器下载列表）';
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      final result = await _channel.invokeMethod<String>('savePng', {
        'png': png,
        'fileName': name,
      });
      if (result == null || result.trim().isEmpty) {
        throw const ImageExportException('相册未返回保存结果，请检查相册后重试。');
      }
      return result;
    }
    if (!const [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ].contains(defaultTargetPlatform)) {
      throw const ImageExportException(
        '当前平台暂不支持保存图片，请使用 Android 应用或网页下载。',
        code: 'unsupported_platform',
      );
    }
    final location = await getSaveLocation(
      suggestedName: name,
      confirmButtonText: '保存图片',
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'PNG 图片',
          extensions: ['png'],
          mimeTypes: ['image/png'],
          uniformTypeIdentifiers: ['public.png'],
        ),
      ],
    );
    if (location == null) {
      throw const ImageExportException('已取消保存。', code: 'cancelled');
    }
    await XFile.fromData(
      png,
      mimeType: 'image/png',
      name: name,
    ).saveTo(location.path);
    return '已保存到：${location.path}';
  } on ImageExportException {
    rethrow;
  } on PlatformException catch (error) {
    throw ImageExportException(
      error.message ?? '图片保存失败，请检查存储空间与权限。',
      code: error.code,
    );
  } on MissingPluginException {
    throw const ImageExportException(
      '此安装包未包含图片保存服务，请安装更新后的应用。',
      code: 'missing_plugin',
    );
  } catch (_) {
    throw const ImageExportException('图片保存失败，请检查目标位置与可用空间后重试。');
  }
}

bool _matches(Uint8List bytes, int start, List<int> expected) {
  for (var i = 0; i < expected.length; i++) {
    if (bytes[start + i] != expected[i]) return false;
  }
  return true;
}

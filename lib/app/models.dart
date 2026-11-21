import 'dart:typed_data';

import 'package:flutter/material.dart';

enum CompositionKind { photo, note }

enum ImageFitMode { cover, contain }

enum ImageStyle { natural, adaptive, gray, naive }

enum DitherMode { fs, stucki, jarvis, burkes, sierra, atkinson, bayer, none }

enum ColorSpaceMode { standard, linear, srgb }

enum TextFont { sans, serif, mono }

class ImageAdjustments {
  const ImageAdjustments({
    this.style = ImageStyle.natural,
    this.dither = DitherMode.fs,
    this.colorSpace = ColorSpaceMode.standard,
    this.brightness = 0,
    this.contrast = 0,
    this.gamma = 1,
    this.saturation = 1,
    this.warmCast = 0.40,
    this.castRamp = 'sunset',
    this.warmCenter = 30,
    this.warmSpan = 58,
    this.warmBoost = 0.60,
    this.coolPull = 0.25,
    this.coolCap = 60,
    this.coolDesat = 0.25,
    this.warmPull = 0.12,
    this.warmPullCap = 18,
    this.autoLevels = true,
    this.sharpen = 0.30,
    this.ditherStrength = 0.85,
  });
  final ImageStyle style;
  final DitherMode dither;
  final ColorSpaceMode colorSpace;
  final double brightness;
  final double contrast;
  final double gamma;
  final double saturation;
  final double warmCast;
  final String castRamp;
  final double warmCenter;
  final double warmSpan;
  final double warmBoost;
  final double coolPull;
  final double coolCap;
  final double coolDesat;
  final double warmPull;
  final double warmPullCap;
  final bool autoLevels;
  final double sharpen;
  final double ditherStrength;
  ImageAdjustments copyWith({
    ImageStyle? style,
    DitherMode? dither,
    ColorSpaceMode? colorSpace,
    double? brightness,
    double? contrast,
    double? gamma,
    double? saturation,
    double? warmCast,
    String? castRamp,
    double? warmCenter,
    double? warmSpan,
    double? warmBoost,
    double? coolPull,
    double? coolCap,
    double? coolDesat,
    double? warmPull,
    double? warmPullCap,
    bool? autoLevels,
    double? sharpen,
    double? ditherStrength,
  }) => ImageAdjustments(
    style: style ?? this.style,
    dither: dither ?? this.dither,
    colorSpace: colorSpace ?? this.colorSpace,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    gamma: gamma ?? this.gamma,
    saturation: saturation ?? this.saturation,
    warmCast: warmCast ?? this.warmCast,
    castRamp: castRamp ?? this.castRamp,
    warmCenter: warmCenter ?? this.warmCenter,
    warmSpan: warmSpan ?? this.warmSpan,
    warmBoost: warmBoost ?? this.warmBoost,
    coolPull: coolPull ?? this.coolPull,
    coolCap: coolCap ?? this.coolCap,
    coolDesat: coolDesat ?? this.coolDesat,
    warmPull: warmPull ?? this.warmPull,
    warmPullCap: warmPullCap ?? this.warmPullCap,
    autoLevels: autoLevels ?? this.autoLevels,
    sharpen: sharpen ?? this.sharpen,
    ditherStrength: ditherStrength ?? this.ditherStrength,
  );
  Map<String, dynamic> toJson() => {
    'style': style.index,
    'dither': dither.index,
    'colorSpace': colorSpace.index,
    'brightness': brightness,
    'contrast': contrast,
    'gamma': gamma,
    'saturation': saturation,
    'warmCast': warmCast,
    'castRamp': castRamp,
    'warmCenter': warmCenter,
    'warmSpan': warmSpan,
    'warmBoost': warmBoost,
    'coolPull': coolPull,
    'coolCap': coolCap,
    'coolDesat': coolDesat,
    'warmPull': warmPull,
    'warmPullCap': warmPullCap,
    'autoLevels': autoLevels,
    'sharpen': sharpen,
    'ditherStrength': ditherStrength,
  };
  factory ImageAdjustments.fromJson(Map<String, dynamic> data) =>
      ImageAdjustments(
        style:
            ImageStyle.values[(data['style'] as int? ??
                    ImageStyle.natural.index)
                .clamp(0, 3)],
        dither:
            DitherMode.values[(data['dither'] as int? ?? DitherMode.fs.index)
                .clamp(0, 7)],
        colorSpace:
            ColorSpaceMode.values[(data['colorSpace'] as int? ??
                    ColorSpaceMode.standard.index)
                .clamp(0, 2)],
        brightness: (data['brightness'] as num?)?.toDouble() ?? 0,
        contrast: (data['contrast'] as num?)?.toDouble() ?? 0,
        gamma: (data['gamma'] as num?)?.toDouble() ?? 1,
        saturation: (data['saturation'] as num?)?.toDouble() ?? 1,
        warmCast: (data['warmCast'] as num?)?.toDouble() ?? 0.40,
        castRamp: data['castRamp'] as String? ?? 'sunset',
        warmCenter: (data['warmCenter'] as num?)?.toDouble() ?? 30,
        warmSpan: (data['warmSpan'] as num?)?.toDouble() ?? 58,
        warmBoost: (data['warmBoost'] as num?)?.toDouble() ?? 0.60,
        coolPull: (data['coolPull'] as num?)?.toDouble() ?? 0.25,
        coolCap: (data['coolCap'] as num?)?.toDouble() ?? 60,
        coolDesat: (data['coolDesat'] as num?)?.toDouble() ?? 0.25,
        warmPull: (data['warmPull'] as num?)?.toDouble() ?? 0.12,
        warmPullCap: (data['warmPullCap'] as num?)?.toDouble() ?? 18,
        autoLevels: data['autoLevels'] as bool? ?? true,
        sharpen: (data['sharpen'] as num?)?.toDouble() ?? 0.30,
        ditherStrength: (data['ditherStrength'] as num?)?.toDouble() ?? 0.85,
      );
}

class TextLayer {
  const TextLayer({
    required this.id,
    this.text = '在这里写下文字',
    this.x = 384,
    this.y = 276,
    this.size = 48,
    this.rotation = 0,
    this.wrap = 640,
    this.stroke = 0,
    this.color = 0,
    this.background,
    this.strokeColor = 1,
    this.font = TextFont.sans,
    this.bold = false,
  });
  final String id, text;
  final double x, y, size, rotation, wrap, stroke;
  final int color, strokeColor;
  final int? background;
  final TextFont font;
  final bool bold;
  TextLayer copyWith({
    String? text,
    double? x,
    double? y,
    double? size,
    double? rotation,
    double? wrap,
    double? stroke,
    int? color,
    int? background,
    bool clearBackground = false,
    int? strokeColor,
    TextFont? font,
    bool? bold,
  }) => TextLayer(
    id: id,
    text: text ?? this.text,
    x: x ?? this.x,
    y: y ?? this.y,
    size: size ?? this.size,
    rotation: rotation ?? this.rotation,
    wrap: wrap ?? this.wrap,
    stroke: stroke ?? this.stroke,
    color: color ?? this.color,
    background: clearBackground ? null : background ?? this.background,
    strokeColor: strokeColor ?? this.strokeColor,
    font: font ?? this.font,
    bold: bold ?? this.bold,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'x': x,
    'y': y,
    'size': size,
    'rotation': rotation,
    'wrap': wrap,
    'stroke': stroke,
    'color': color,
    'background': background,
    'strokeColor': strokeColor,
    'font': font.index,
    'bold': bold,
  };
  factory TextLayer.fromJson(Map<String, dynamic> j) => TextLayer(
    id: j['id'] as String,
    text: j['text'] as String? ?? '',
    x: (j['x'] as num?)?.toDouble() ?? 384,
    y: (j['y'] as num?)?.toDouble() ?? 276,
    size: (j['size'] as num?)?.toDouble() ?? 48,
    rotation: (j['rotation'] as num?)?.toDouble() ?? 0,
    wrap: (j['wrap'] as num?)?.toDouble() ?? 640,
    stroke: (j['stroke'] as num?)?.toDouble() ?? 0,
    color: j['color'] as int? ?? 0,
    background: j['background'] as int?,
    strokeColor: j['strokeColor'] as int? ?? 1,
    font: TextFont.values[(j['font'] as int? ?? 0).clamp(0, 2)],
    bold: j['bold'] as bool? ?? false,
  );
}

class ComposerDraft {
  const ComposerDraft({
    this.photoBytes,
    this.kind = CompositionKind.photo,
    this.adjustments = const ImageAdjustments(),
    this.fit = ImageFitMode.cover,
    this.quarterTurns = 0,
    this.rotation = 0,
    this.mirror = false,
    this.zoom = 1,
    this.offsetX = 0,
    this.offsetY = 0,
    this.paddingEnabled = false,
    this.padTop = 32,
    this.padRight = 32,
    this.padBottom = 64,
    this.padLeft = 32,
    this.background = 1,
    this.textEnabled = true,
    this.photoTexts = const [],
    this.noteTexts = const [],
  });
  final Uint8List? photoBytes;
  final CompositionKind kind;
  final ImageAdjustments adjustments;
  final ImageFitMode fit;
  final int quarterTurns;
  final double rotation;
  final bool mirror;
  final double zoom;
  final double offsetX;
  final double offsetY;
  final bool paddingEnabled;
  final double padTop;
  final double padRight;
  final double padBottom;
  final double padLeft;
  final int background;
  final bool textEnabled;
  final List<TextLayer> photoTexts;
  final List<TextLayer> noteTexts;
  ComposerDraft copyWith({
    Uint8List? photoBytes,
    bool clearPhoto = false,
    CompositionKind? kind,
    ImageAdjustments? adjustments,
    ImageFitMode? fit,
    int? quarterTurns,
    double? rotation,
    bool? mirror,
    double? zoom,
    double? offsetX,
    double? offsetY,
    bool? paddingEnabled,
    double? padTop,
    double? padRight,
    double? padBottom,
    double? padLeft,
    int? background,
    bool? textEnabled,
    List<TextLayer>? photoTexts,
    List<TextLayer>? noteTexts,
  }) => ComposerDraft(
    photoBytes: clearPhoto ? null : photoBytes ?? this.photoBytes,
    kind: kind ?? this.kind,
    adjustments: adjustments ?? this.adjustments,
    fit: fit ?? this.fit,
    quarterTurns: quarterTurns ?? this.quarterTurns,
    rotation: rotation ?? this.rotation,
    mirror: mirror ?? this.mirror,
    zoom: zoom ?? this.zoom,
    offsetX: offsetX ?? this.offsetX,
    offsetY: offsetY ?? this.offsetY,
    paddingEnabled: paddingEnabled ?? this.paddingEnabled,
    padTop: padTop ?? this.padTop,
    padRight: padRight ?? this.padRight,
    padBottom: padBottom ?? this.padBottom,
    padLeft: padLeft ?? this.padLeft,
    background: background ?? this.background,
    textEnabled: textEnabled ?? this.textEnabled,
    photoTexts: photoTexts ?? this.photoTexts,
    noteTexts: noteTexts ?? this.noteTexts,
  );
  List<TextLayer> get textLayers =>
      kind == CompositionKind.photo ? photoTexts : noteTexts;
  Map<String, dynamic> toJson() => {
    'kind': kind.index,
    'adjustments': adjustments.toJson(),
    'fit': fit.index,
    'quarterTurns': quarterTurns,
    'rotation': rotation,
    'mirror': mirror,
    'zoom': zoom,
    'offsetX': offsetX,
    'offsetY': offsetY,
    'paddingEnabled': paddingEnabled,
    'padTop': padTop,
    'padRight': padRight,
    'padBottom': padBottom,
    'padLeft': padLeft,
    'background': background,
    'textEnabled': textEnabled,
    'photoTexts': photoTexts.map((t) => t.toJson()).toList(),
    'noteTexts': noteTexts.map((t) => t.toJson()).toList(),
  };
  factory ComposerDraft.fromJson(Map<String, dynamic> j) => ComposerDraft(
    kind: CompositionKind.values[(j['kind'] as int? ?? 0).clamp(0, 1)],
    adjustments: ImageAdjustments.fromJson(
      Map<String, dynamic>.from(j['adjustments'] as Map? ?? {}),
    ),
    fit: ImageFitMode.values[(j['fit'] as int? ?? 0).clamp(0, 1)],
    quarterTurns: j['quarterTurns'] as int? ?? 0,
    rotation: (j['rotation'] as num?)?.toDouble() ?? 0,
    mirror: j['mirror'] as bool? ?? false,
    zoom: (j['zoom'] as num?)?.toDouble() ?? 1,
    offsetX: (j['offsetX'] as num?)?.toDouble() ?? 0,
    offsetY: (j['offsetY'] as num?)?.toDouble() ?? 0,
    paddingEnabled: j['paddingEnabled'] as bool? ?? false,
    padTop: (j['padTop'] as num?)?.toDouble() ?? 32,
    padRight: (j['padRight'] as num?)?.toDouble() ?? 32,
    padBottom: (j['padBottom'] as num?)?.toDouble() ?? 64,
    padLeft: (j['padLeft'] as num?)?.toDouble() ?? 32,
    background: j['background'] as int? ?? 1,
    textEnabled: j['textEnabled'] as bool? ?? true,
    photoTexts: (j['photoTexts'] as List? ?? [])
        .map((t) => TextLayer.fromJson(Map<String, dynamic>.from(t as Map)))
        .toList(),
    noteTexts: (j['noteTexts'] as List? ?? [])
        .map((t) => TextLayer.fromJson(Map<String, dynamic>.from(t as Map)))
        .toList(),
  );
}

class DeviceView {
  const DeviceView(this.id, this.name, this.rssi);
  final String id, name;
  final int rssi;
}

class GalleryItemView {
  const GalleryItemView({
    required this.slot,
    required this.title,
    this.current = false,
    this.png,
  });
  final int slot;
  final String title;
  final bool current;
  final Uint8List? png;
}

class SettingsView {
  const SettingsView({
    this.name = '',
    this.panel = 0,
    this.sleepSeconds = 180,
    this.wakeSeconds = 0,
    this.timeoutAction = 0,
    this.cache = true,
    this.wakeShow = true,
    this.gpioPreset = 2,
    this.pins = const [0, 1, 4, 3, 5, 6, 7, 10],
  });
  final String name;
  final int panel, sleepSeconds, wakeSeconds, timeoutAction, gpioPreset;
  final bool cache, wakeShow;
  final List<int> pins;
  SettingsView copyWith({
    String? name,
    int? panel,
    int? sleepSeconds,
    int? wakeSeconds,
    int? timeoutAction,
    bool? cache,
    bool? wakeShow,
    int? gpioPreset,
    List<int>? pins,
  }) => SettingsView(
    name: name ?? this.name,
    panel: panel ?? this.panel,
    sleepSeconds: sleepSeconds ?? this.sleepSeconds,
    wakeSeconds: wakeSeconds ?? this.wakeSeconds,
    timeoutAction: timeoutAction ?? this.timeoutAction,
    cache: cache ?? this.cache,
    wakeShow: wakeShow ?? this.wakeShow,
    gpioPreset: gpioPreset ?? this.gpioPreset,
    pins: pins ?? this.pins,
  );
}

const inkBlack = Color(0xFF000000);
const paperWhite = Color(0xFFFFFFFF);
const inkYellow = Color(0xFFFFFF00);
const inkRed = Color(0xFFFF0000);
const displayPalette = [inkBlack, paperWhite, inkYellow, inkRed];

/// Color mapping and serpentine dithering ported from moink-R1.3.4/page/index.html.
/// All coordinates here are upright; frame_codec alone performs wire rotation.
library;

import 'dart:math' as math;
import 'dart:typed_data';

const devicePalette = <List<int>>[
  [0, 0, 0],
  [255, 255, 255],
  [255, 255, 0],
  [255, 0, 0],
];

/// Names and units deliberately match the reference JavaScript algorithm.
const imageFilterDefaults = <String, Object>{
  'mode': 'natural',
  'brightness': 0.0,
  'contrast': 0.0,
  'gamma': 1.0,
  'saturation': 1.0,
  'warmCast': .40,
  'castRamp': 'sunset',
  'warmCenter': 30.0,
  'warmSpan': 58.0,
  'warmBoost': .60,
  'coolPull': .25,
  'coolCap': 60.0,
  'coolDesat': .25,
  'warmPull': .12,
  'warmPullCap': 18.0,
  'autoLevels': true,
  'sharpen': .30,
  'dither': 'fs',
  'ditherStrength': .85,
  'space': 'std',
};

Map<String, Object> _settings(Map<String, Object> options) {
  final cfg = {...imageFilterDefaults, ...options};
  for (final key in imageFilterDefaults.keys) {
    if (imageFilterDefaults[key] is num &&
        (cfg[key] is! num || !(cfg[key] as num).isFinite)) {
      throw ArgumentError('Invalid image filter $key');
    }
  }
  if (!['natural', 'adaptive', 'gray', 'naive'].contains(cfg['mode']) ||
      ![
        'fs',
        'stucki',
        'jarvis',
        'burkes',
        'sierra',
        'atkinson',
        'bayer',
        'none',
      ].contains(cfg['dither']) ||
      !['std', 'linear', 'srgb'].contains(cfg['space']) ||
      !['sunset', 'ember', 'duotone', 'sepia'].contains(cfg['castRamp']) ||
      cfg['autoLevels'] is! bool ||
      (cfg['gamma'] as num) <= 0) {
    throw ArgumentError('Invalid image filter configuration');
  }
  return cfg;
}

void _geometry(List<num> values, int width, int height, int channels) {
  if (width <= 0 || height <= 0 || values.length != width * height * channels) {
    throw ArgumentError('Image buffer does not match dimensions');
  }
}

double _clamp(num v, num low, num high) => v.clamp(low, high).toDouble();
double _luma(double r, double g, double b) => r * .2126 + g * .7152 + b * .0722;
double _s2l(double value) {
  final v = _clamp(value, 0, 255) / 255;
  return 255 * (v <= .04045 ? v / 12.92 : math.pow((v + .055) / 1.055, 2.4).toDouble());
}

final _linearLut = List<double>.generate(256, (i) => _s2l(i.toDouble()));
final _standardLut = List<double>.generate(
  256,
  (i) => 255 * math.pow(i / 255, 1.75).toDouble(),
);
final _standardPalette = <List<num>>[
  [0, 0, 0],
  [255, 255, 255],
  [255, _standardLut[230], 0],
  [_standardLut[230], 0, 0],
];
final _linearPalette = devicePalette
    .map((p) => p.map((c) => _s2l(c.toDouble())).toList())
    .toList();

const _ramps = <String, List<List<double>>>{
  'sunset': [
    [0, 0, 0, 0],
    [.10, 26, 6, 4],
    [.26, 92, 18, 12],
    [.42, 168, 40, 16],
    [.56, 214, 86, 18],
    [.70, 236, 140, 26],
    [.84, 248, 200, 60],
    [.93, 255, 235, 150],
    [1, 255, 255, 255],
  ],
  'ember': [
    [0, 0, 0, 0],
    [.12, 40, 4, 0],
    [.28, 120, 10, 4],
    [.44, 196, 28, 6],
    [.58, 232, 74, 6],
    [.72, 246, 140, 10],
    [.86, 252, 204, 26],
    [.95, 255, 240, 110],
    [1, 255, 255, 255],
  ],
  'duotone': [
    [0, 0, 0, 0],
    [.30, 150, 20, 10],
    [.55, 235, 80, 10],
    [.78, 250, 190, 20],
    [1, 255, 255, 255],
  ],
  'sepia': [
    [0, 22, 14, 8],
    [.25, 92, 66, 38],
    [.50, 150, 116, 72],
    [.72, 202, 172, 124],
    [.88, 232, 212, 172],
    [1, 255, 250, 236],
  ],
};
final _rampCache = <String, Float64List>{};
Float64List _rampLut(String name) => _rampCache.putIfAbsent(name, () {
  final stops = _ramps[name]!;
  final out = Float64List(256 * 3);
  for (var i = 0; i < 256; i++) {
    final t = i / 255;
    var k = 0;
    while (k < stops.length - 2 && t >= stops[k + 1][0]) {
      k++;
    }
    for (var c = 0; c < 3; c++) {
      final slope =
          (stops[k + 1][c + 1] - stops[k][c + 1]) /
          (stops[k + 1][0] - stops[k][0]);
      out[i * 3 + c] = slope * (t - stops[k][0]) + stops[k][c + 1];
    }
  }
  return out;
});

(double, double, double) _rgb2hsl(double r, double g, double b) {
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final l = (mx + mn) * .5, d = mx - mn;
  final den = l > .5 ? 2 - mx - mn : mx + mn;
  final s = _clamp(d > 1e-12 ? d / math.max(den, 1e-12) : 0, 0, 1);
  var h = 0.0;
  if (d > 1e-12) {
    final rc = (mx - r) / d, gc = (mx - g) / d, bc = (mx - b) / d;
    final hh = mx == r ? bc - gc : (mx == g ? 2 + rc - bc : 4 + gc - rc);
    h = (hh / 6) % 1;
  }
  return (h, s, l);
}

double _hue2rgb(double p, double q, double value) {
  final t = value % 1;
  if (t < 1 / 6) return p + (q - p) * 6 * t;
  if (t < .5) return q;
  if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
  return p;
}

(double, double, double) _hsl2rgb(double h, double s, double l) {
  final q = l < .5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
  return (
    _hue2rgb(p, q, h + 1 / 3),
    _hue2rgb(p, q, h),
    _hue2rgb(p, q, h - 1 / 3),
  );
}

double _warmAffinity(double hd) {
  final hi = _clamp((hd - 300) / 50, 0, 1), lo = _clamp((hd - 60) / 50, 0, 1);
  if (hd > 300) return hi * hi * (3 - 2 * hi);
  if (hd < 110) return 1 - lo * lo * (3 - 2 * lo);
  return 0;
}

/// In-place 0.5% luminance clipping into the reference [18, 246] range.
void autoLevels(Float64List buf, {double clip = .005}) {
  if (buf.length % 3 != 0 || clip < 0 || clip >= .5) {
    throw ArgumentError('Invalid levels input');
  }
  final n = buf.length ~/ 3;
  if (n == 0) return;
  final histogram = Uint32List(256);
  for (var i = 0; i < n; i++) {
    histogram[_luma(
      buf[i * 3],
      buf[i * 3 + 1],
      buf[i * 3 + 2],
    ).round().clamp(0, 255)]++;
  }
  var count = 0, lo = 0, hi = 255;
  for (var i = 0; i < 256; i++) {
    count += histogram[i];
    if (count >= clip * n) {
      lo = i;
      break;
    }
  }
  count = 0;
  for (var i = 0; i < 256; i++) {
    count += histogram[i];
    if (count >= (1 - clip) * n) {
      hi = i;
      break;
    }
  }
  if (hi - lo < 8) return;
  final scale = (246 - 18) / (hi - lo);
  for (var i = 0; i < buf.length; i++) {
    buf[i] = (buf[i] - lo) * scale + 18;
  }
}

Float64List _blur3(Float64List src, int w, int h) {
  final tmp = Float64List(src.length), out = Float64List(src.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final xm = math.max(0, x - 1),
          xp = math.min(w - 1, x + 1),
          o = (y * w + x) * 3;
      for (var c = 0; c < 3; c++) {
        tmp[o + c] =
            src[(y * w + xm) * 3 + c] +
            2 * src[o + c] +
            src[(y * w + xp) * 3 + c];
      }
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final ym = math.max(0, y - 1),
          yp = math.min(h - 1, y + 1),
          o = (y * w + x) * 3;
      for (var c = 0; c < 3; c++) {
        out[o + c] =
            (tmp[(ym * w + x) * 3 + c] +
                2 * tmp[o + c] +
                tmp[(yp * w + x) * 3 + c]) *
            .0625;
      }
    }
  }
  return out;
}

/// Maps a copy of interleaved RGB values without changing the caller's snapshot.
Float64List warmMap(
  Float64List input,
  int width,
  int height, [
  Map<String, Object> options = const {},
]) {
  _geometry(input, width, height, 3);
  final cfg = _settings(options), buf = Float64List.fromList(input);
  double value(String key) => (cfg[key] as num).toDouble();
  final brightness = value('brightness'),
      contrast = value('contrast'),
      gamma = value('gamma');
  for (var i = 0; i < buf.length; i++) {
    var v = buf[i] + brightness;
    if (contrast != 0) v = (v - 128) * (1 + contrast / 100) + 128;
    if (gamma != 1) v = 255 * math.pow(_clamp(v, 0, 255) / 255, gamma).toDouble();
    buf[i] = _clamp(v, 0, 255);
  }
  if (cfg['autoLevels'] == true) {
    autoLevels(buf);
    for (var i = 0; i < buf.length; i++) {
      buf[i] = _clamp(buf[i], 0, 255);
    }
  }
  final sharpen = value('sharpen');
  if (sharpen > 0) {
    final blur = _blur3(buf, width, height);
    for (var i = 0; i < buf.length; i++) {
      buf[i] = _clamp(buf[i] + sharpen * (buf[i] - blur[i]), 0, 255);
    }
  }
  final mode = cfg['mode'], out = Float64List(buf.length);
  if (mode == 'naive') return buf;
  if (mode == 'gray') {
    for (var i = 0; i < buf.length; i += 3) {
      final l = _clamp(_luma(buf[i], buf[i + 1], buf[i + 2]), 0, 255);
      out[i] = out[i + 1] = out[i + 2] = l;
    }
    return out;
  }
  final saturation = value('saturation'), center = value('warmCenter');
  if (mode == 'natural') {
    for (var i = 0; i < buf.length; i += 3) {
      final (h, s, l) = _rgb2hsl(
        buf[i] / 255,
        buf[i + 1] / 255,
        buf[i + 2] / 255,
      );
      final hd = h * 360, wa = _warmAffinity(h * 360);
      final g = _clamp(value('warmBoost') * wa, 0, 1);
      var s2 = math.pow(s, 1 - .75 * g).toDouble();
      s2 *= 1 - _clamp(value('coolDesat') * (1 - wa), 0, 1);
      s2 = _clamp(s2 * saturation, 0, 1);
      final drift = _clamp(
        -value('coolPull') * (1 - wa) * (hd - 60),
        -value('coolCap'),
        0,
      );
      final d2 = (center - hd + 540) % 360 - 180;
      final pull = _clamp(
        value('warmPull') * d2,
        -value('warmPullCap'),
        value('warmPullCap'),
      );
      final h2 = (hd + drift + wa * pull) % 360;
      final (r, g2, b) = _hsl2rgb(h2 / 360, s2, l);
      out[i] = _clamp(r * 255, 0, 255);
      out[i + 1] = _clamp(g2 * 255, 0, 255);
      out[i + 2] = _clamp(b * 255, 0, 255);
    }
    return out;
  }
  final lut = _rampLut(cfg['castRamp'] as String), cast = value('warmCast');
  for (var i = 0; i < buf.length; i += 3) {
    final (h, s, l) = _rgb2hsl(
      buf[i] / 255,
      buf[i + 1] / 255,
      buf[i + 2] / 255,
    );
    final hda = (center + (h - .5) * value('warmSpan')) % 360;
    final (yr, yg, yb) = _hsl2rgb(hda / 360, s, l);
    var r = yr * 255, g = yg * 255, b = yb * 255;
    final lm = _clamp(_luma(r, g, b), 0, 255).round();
    r = r * (1 - cast) + lut[lm * 3] * cast;
    g = g * (1 - cast) + lut[lm * 3 + 1] * cast;
    b = b * (1 - cast) + lut[lm * 3 + 2] * cast;
    final (h3, s3, l3) = _rgb2hsl(
      _clamp(r, 0, 255) / 255,
      _clamp(g, 0, 255) / 255,
      _clamp(b, 0, 255) / 255,
    );
    final (fr, fg, fb) = _hsl2rgb(h3, _clamp(s3 * saturation, 0, 1), l3);
    out[i] = _clamp(fr * 255, 0, 255);
    out[i + 1] = _clamp(fg * 255, 0, 255);
    out[i + 2] = _clamp(fb * 255, 0, 255);
  }
  return out;
}

// Sierra here is Sierra Lite, as named by the reference UI.
const _kernels = <String, List<(int, int, double)>>{
  'fs': [(1, 0, 7 / 16), (-1, 1, 3 / 16), (0, 1, 5 / 16), (1, 1, 1 / 16)],
  'atkinson': [
    (1, 0, 1 / 8),
    (2, 0, 1 / 8),
    (-1, 1, 1 / 8),
    (0, 1, 1 / 8),
    (1, 1, 1 / 8),
    (0, 2, 1 / 8),
  ],
  'burkes': [
    (1, 0, 8 / 32),
    (2, 0, 4 / 32),
    (-2, 1, 2 / 32),
    (-1, 1, 4 / 32),
    (0, 1, 8 / 32),
    (1, 1, 4 / 32),
    (2, 1, 2 / 32),
  ],
  'sierra': [(1, 0, 2 / 4), (-1, 1, 1 / 4), (0, 1, 1 / 4)],
  'stucki': [
    (1, 0, 8 / 42),
    (2, 0, 4 / 42),
    (-2, 1, 2 / 42),
    (-1, 1, 4 / 42),
    (0, 1, 8 / 42),
    (1, 1, 4 / 42),
    (2, 1, 2 / 42),
    (-2, 2, 1 / 42),
    (-1, 2, 2 / 42),
    (0, 2, 4 / 42),
    (1, 2, 2 / 42),
    (2, 2, 1 / 42),
  ],
  'jarvis': [
    (1, 0, 7 / 48),
    (2, 0, 5 / 48),
    (-2, 1, 3 / 48),
    (-1, 1, 5 / 48),
    (0, 1, 7 / 48),
    (1, 1, 5 / 48),
    (2, 1, 3 / 48),
    (-2, 2, 1 / 48),
    (-1, 2, 3 / 48),
    (0, 2, 5 / 48),
    (1, 2, 3 / 48),
    (2, 2, 1 / 48),
  ],
};
const _bayer8 = [
  0,
  32,
  8,
  40,
  2,
  34,
  10,
  42,
  48,
  16,
  56,
  24,
  50,
  18,
  58,
  26,
  12,
  44,
  4,
  36,
  14,
  46,
  6,
  38,
  60,
  28,
  52,
  20,
  62,
  30,
  54,
  22,
  3,
  35,
  11,
  43,
  1,
  33,
  9,
  41,
  51,
  19,
  59,
  27,
  49,
  17,
  57,
  25,
  15,
  47,
  7,
  39,
  13,
  45,
  5,
  37,
  63,
  31,
  55,
  23,
  61,
  29,
  53,
  21,
];

int _nearest(double r, double g, double b, List<List<num>> palette) {
  var best = 0, distance = double.infinity;
  for (var k = 0; k < 4; k++) {
    final p = palette[k], dr = r - p[0], dg = g - p[1], db = b - p[2];
    final d = dr * dr + dg * dg + db * db;
    if (d < distance) {
      best = k;
      distance = d;
    }
  }
  return best;
}

/// Palette snapping after text composition never diffuses text edge error.
int snapPalette(num r, num g, num b) =>
    _nearest(r.toDouble(), g.toDouble(), b.toDouble(), devicePalette);

Uint8List quantize(
  Float64List mapped,
  int width,
  int height, [
  Map<String, Object> options = const {},
]) {
  _geometry(mapped, width, height, 3);
  final cfg = _settings(options),
      flat = Float64List.fromList(mapped),
      out = Uint8List(width * height);
  final space = cfg['space'],
      mode = cfg['dither'],
      strength = (cfg['ditherStrength'] as num).toDouble();
  final palette = space == 'std'
      ? _standardPalette
      : (space == 'linear' ? _linearPalette : devicePalette);
  if (space == 'std' || space == 'linear') {
    final lut = space == 'std' ? _standardLut : _linearLut;
    for (var i = 0; i < flat.length; i++) {
      flat[i] = lut[_clamp(flat[i], 0, 255).round()];
    }
  }
  int nearest(int offset) =>
      _nearest(flat[offset], flat[offset + 1], flat[offset + 2], palette);
  if (mode == 'none') {
    for (var i = 0; i < out.length; i++) {
      out[i] = nearest(i * 3);
    }
    return out;
  }
  if (mode == 'bayer') {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final o = (y * width + x) * 3,
            offset =
                (_bayer8[(y & 7) * 8 + (x & 7)] / 64 - .5) * strength * 128;
        for (var c = 0; c < 3; c++) {
          flat[o + c] = _clamp(flat[o + c] + offset, 0, 255);
        }
        out[y * width + x] = nearest(o);
      }
    }
    return out;
  }
  final kernel = _kernels[mode]!;
  for (var y = 0; y < height; y++) {
    final ltr = y.isEven;
    for (var i = 0; i < width; i++) {
      final x = ltr ? i : width - 1 - i,
          o = (y * width + (ltr ? i : width - 1 - i)) * 3;
      final k = nearest(o);
      out[y * width + x] = k;
      if (strength <= 0) continue;
      final p = palette[k];
      final er = (flat[o] - p[0]) * strength,
          eg = (flat[o + 1] - p[1]) * strength,
          eb = (flat[o + 2] - p[2]) * strength;
      for (final (dx, dy, weight) in kernel) {
        final nx = x + (ltr ? dx : -dx), ny = y + dy;
        if (nx >= 0 && nx < width && ny < height) {
          final n = (ny * width + nx) * 3;
          flat[n] += er * weight;
          flat[n + 1] += eg * weight;
          flat[n + 2] += eb * weight;
        }
      }
    }
  }
  return out;
}

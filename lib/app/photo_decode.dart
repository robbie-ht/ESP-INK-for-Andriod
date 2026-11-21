import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decode one consistently sized photo for editing and device composition.
/// Choose the target from intrinsic dimensions, so a very tall image is
/// bounded by its height instead of being expanded to an arbitrary width.
/// Use the portable codec API: encoded ImageDescriptor dimensions are not
/// available in Flutter's web engine.
/// The caller owns and must dispose the returned image.
Future<ui.Image> decodePhoto(Uint8List bytes, {int maxDimension = 2400}) async {
  if (maxDimension <= 0) {
    throw ArgumentError.value(maxDimension, 'maxDimension', 'Must be positive');
  }
  ui.Codec? codec;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // instantiateImageCodecWithSize owns and disposes the buffer on all paths.
    codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        if (width <= 0 || height <= 0) {
          throw const FormatException('Photo dimensions must be positive');
        }
        final ratio = math.min(1.0, maxDimension / math.max(width, height));
        return ui.TargetImageSize(
          width: math.max(1, (width * ratio).round()),
          height: math.max(1, (height * ratio).round()),
        );
      },
    );
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
  }
}

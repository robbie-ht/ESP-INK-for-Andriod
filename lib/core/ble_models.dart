class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });

  final String id;
  final String name;
  final int rssi;
}

class NativeBleException implements Exception {
  const NativeBleException(this.message, {this.code = 'ble_error'});
  final String message;
  final String code;

  @override
  String toString() => message;
}

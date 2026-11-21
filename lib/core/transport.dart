import 'dart:typed_data';

/// A single connected GATT link. Notifications must be subscribed before CTRL.
abstract interface class EspInkTransport {
  int get mtu;
  bool get isConnected;
  Stream<Uint8List> get notifications;
  Stream<bool> get connectionChanges;
  Future<void> writeCtrl(Uint8List value);
  Future<void> writeData(Uint8List value);
  Future<void> disconnect();
}

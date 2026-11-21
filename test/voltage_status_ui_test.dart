import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moink_app/app/controller.dart';
import 'package:moink_app/main.dart';

class _VoltageController extends MoinkController {
  bool online = true;
  @override
  bool get connected => online;
}

void main() {
  Future<void> launch(WidgetTester tester, _VoltageController c) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(c.dispose);
    c.tabIndex = 2;
    await tester.pumpWidget(MoinkApp(controller: c));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'voltage labels distinguish a valid sample from a retained sample',
    (tester) async {
      final c = _VoltageController()..batteryMv = 3870;
      await launch(tester, c);
      expect(find.text('3.87 V'), findsOneWidget);
      expect(find.text('空闲时自动更新'), findsOneWidget);
      c.batteryReadingStale = true;
      c.notifyListeners();
      await tester.pump();
      expect(find.text('3.87 V'), findsOneWidget);
      expect(find.text('上次有效读数，正在等待新采样'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unknown voltage is waiting for a sample and is not invented', (
    tester,
  ) async {
    final c = _VoltageController();
    await launch(tester, c);
    expect(find.text('暂无读数'), findsOneWidget);
    expect(find.text('等待有效采样，空闲时重读'), findsOneWidget);
    c.online = false;
    c.batteryMv = 3900;
    c.notifyListeners();
    await tester.pump();
    expect(find.text('3.90 V'), findsNothing);
    expect(find.text('连接后读取'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

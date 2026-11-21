import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'components.dart';
import 'composer_page.dart';
import 'device_page.dart';
import 'gallery_page.dart';
import 'sheets.dart';

class EspInkHome extends StatelessWidget {
  const EspInkHome({super.key, required this.controller});
  final EspInkController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final c = controller;
      final size = MediaQuery.sizeOf(context);
      final rail = size.width >= 1000;
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: rail ? 32 : 20,
                  vertical: 18,
                ),
                child: Row(
                  children: [
                    Brand(compact: size.width < 720),
                    const Spacer(),
                    if (size.width >= 620) ...[
                      const Text(
                        '为生活，留一点空白',
                        style: TextStyle(fontSize: 12, color: mutedText),
                      ),
                      const SizedBox(width: 28),
                    ],
                    ActionChip(
                      avatar: Icon(
                        c.demo
                            ? Icons.play_circle_outline_rounded
                            : c.connected
                            ? Icons.bluetooth_connected_rounded
                            : Icons.bluetooth_rounded,
                        size: 17,
                        color: c.connected
                            ? const Color(0xFF30754A)
                            : const Color(0xFF476995),
                      ),
                      label: Text(
                        c.connectionLabel,
                        style: const TextStyle(fontSize: 11),
                      ),
                      side: BorderSide.none,
                      backgroundColor: c.connected
                          ? const Color(0xFFE5F1E7)
                          : const Color(0xFFEAF0FA),
                      onPressed: c.busy && !c.galleryReading
                          ? null
                          : c.connected
                          ? () => c.setTab(2)
                          : () => showConnectionSheet(context, c),
                    ),
                    if (size.width >= 620) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: '查看日志',
                        onPressed: () => showLogsSheet(context, c),
                        icon: const Icon(Icons.more_horiz_rounded),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (rail)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 26, 10, 20),
                        child: NavigationRail(
                          backgroundColor: Colors.transparent,
                          minWidth: 80,
                          labelType: NavigationRailLabelType.all,
                          selectedIndex: c.tabIndex,
                          onDestinationSelected: c.setTab,
                          useIndicator: true,
                          indicatorColor: const Color(0xFFDCE8FF),
                          selectedLabelTextStyle: const TextStyle(
                            color: Color(0xFF1967D2),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          unselectedLabelTextStyle: const TextStyle(
                            color: mutedText,
                            fontSize: 12,
                          ),
                          destinations: const [
                            NavigationRailDestination(
                              icon: Icon(Icons.dashboard_customize_outlined),
                              selectedIcon: Icon(
                                Icons.dashboard_customize_rounded,
                              ),
                              label: Text('创作'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.photo_library_outlined),
                              selectedIcon: Icon(Icons.photo_library_rounded),
                              label: Text('图库'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.devices_other_outlined),
                              selectedIcon: Icon(Icons.devices_other_rounded),
                              label: Text('设备'),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        key: PageStorageKey('tab-${c.tabIndex}'),
                        padding: EdgeInsets.fromLTRB(
                          rail ? 26 : 20,
                          rail ? 30 : 15,
                          rail ? 40 : 20,
                          10,
                        ),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1240),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (c.demo)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 23),
                                    child: Container(
                                      padding: const EdgeInsets.fromLTRB(
                                        15,
                                        8,
                                        8,
                                        8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFE9EFFA),
                                        borderRadius: BorderRadius.circular(15),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.play_circle_outline_rounded,
                                            size: 18,
                                            color: Color(0xFF496A9C),
                                          ),
                                          const SizedBox(width: 9),
                                          const Expanded(
                                            child: Text(
                                              '本地演示 · 操作不会发送到真实设备',
                                              style: TextStyle(
                                                color: Color(0xFF496A9C),
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: c.busy
                                                ? null
                                                : c.leaveDemo,
                                            child: const Text(
                                              '退出',
                                              style: TextStyle(fontSize: 11),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                if (c.busy && !c.galleryReading)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 22),
                                    child: SectionCard(
                                      color: const Color(0xFFEAF1FD),
                                      padding: const EdgeInsets.all(18),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(
                                                Icons.sync_rounded,
                                                color: Color(0xFF1967D2),
                                                size: 20,
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Text(
                                                  c.phase,
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                              if (c.progress != null)
                                                Text(
                                                  '${(c.progress! * 100).round()}%',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              if (c.canCancel)
                                                TextButton(
                                                  onPressed: c.cancelTransfer,
                                                  child: const Text('取消'),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 13),
                                          LinearProgressIndicator(
                                            value: c.progress,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            minHeight: 5,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                switch (c.tabIndex) {
                                  0 => ComposerPage(c: c),
                                  1 => GalleryPage(c: c),
                                  _ => DevicePage(c: c),
                                },
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: rail
            ? null
            : NavigationBar(
                selectedIndex: c.tabIndex,
                onDestinationSelected: c.setTab,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.dashboard_customize_outlined),
                    selectedIcon: Icon(Icons.dashboard_customize_rounded),
                    label: '创作',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.photo_library_outlined),
                    selectedIcon: Icon(Icons.photo_library_rounded),
                    label: '图库',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.devices_other_outlined),
                    selectedIcon: Icon(Icons.devices_other_rounded),
                    label: '设备',
                  ),
                ],
              ),
      );
    },
  );
}

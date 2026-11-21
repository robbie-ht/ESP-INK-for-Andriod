import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import 'components.dart';

Future<void> showConnectionSheet(
  BuildContext context,
  EspInkController c,
) async {
  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  if (android && !c.scanning && !c.connected) unawaited(c.scan());
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => AnimatedBuilder(
      animation: c,
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .86,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(
                        color: Color(0xFFE1ECFF),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.bluetooth_rounded,
                        color: Color(0xFF1967D2),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '连接你的墨水屏',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 3),
                          const Text(
                            '让好看的画面，拥有自己的位置。',
                            style: TextStyle(fontSize: 12, color: mutedText),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (!android)
                  const SectionCard(
                    color: sectionFill,
                    padding: EdgeInsets.all(18),
                    child: Text(
                      '蓝牙连接请使用 Android 手机安装版。这里可以编辑画面，或体验本地演示。',
                      style: TextStyle(color: mutedText),
                    ),
                  ),
                if (android) ...[
                  const Text(
                    '按一下设备按键唤醒，并保持设备在手机附近。',
                    style: TextStyle(color: mutedText),
                  ),
                  const SizedBox(height: 16),
                  if (c.scanning) const LinearProgressIndicator(minHeight: 3),
                  if (c.devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 30),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              c.scanning
                                  ? Icons.radar_rounded
                                  : Icons.bluetooth_searching_rounded,
                              size: 45,
                              color: const Color(0xFF84A5D9),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              c.scanning ? '正在寻找附近的墨水屏…' : '暂时没有发现设备',
                              style: const TextStyle(color: mutedText),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ...c.devices.map(
                    (device) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SectionCard(
                        padding: EdgeInsets.zero,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 8,
                          ),
                          leading: const Icon(
                            Icons.tablet_mac_rounded,
                            color: Color(0xFF1967D2),
                          ),
                          title: Text(
                            device.name.isEmpty ? 'ESP-INK' : device.name,
                          ),
                          subtitle: Text(
                            '信号 ${device.rssi} dBm',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: c.connecting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.chevron_right_rounded),
                          onTap: c.connecting
                              ? null
                              : () async {
                                  await c.connect(device.id);
                                  if (context.mounted && c.connected) {
                                    Navigator.pop(context);
                                  }
                                },
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: c.scanning || c.connecting ? null : c.scan,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('重新扫描'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.outlined(
                        onPressed: c.openBluetoothSettings,
                        tooltip: '蓝牙设置',
                        icon: const Icon(Icons.settings_bluetooth_rounded),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 26),
                const Divider(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '设备还没在身边？',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          SizedBox(height: 3),
                          Text(
                            '演示只在本地展示，不连接真实设备',
                            style: TextStyle(fontSize: 11, color: mutedText),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: c.busy
                          ? null
                          : () async {
                              await c.enterDemo();
                              if (context.mounted) Navigator.pop(context);
                            },
                      child: const Text('体验演示'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> showSendSheet(BuildContext context, EspInkController c) async {
  if (!c.connected && !c.demo) {
    await showConnectionSheet(context, c);
    if (!context.mounted || (!c.connected && !c.demo)) return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('把这一刻，送到墨水屏', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              c.demo ? '本地演示 · 不向真实设备发送' : c.deviceName,
              style: const TextStyle(color: mutedText),
            ),
            const SizedBox(height: 22),
            _SendOption(
              icon: Icons.send_rounded,
              title: '立即显示',
              subtitle: '更新屏幕上的画面',
              onTap: () {
                Navigator.pop(context);
                c.send();
              },
            ),
            if (c.gallerySupported) ...[
              const SizedBox(height: 10),
              _SendOption(
                icon: Icons.collections_bookmark_outlined,
                title: '存入图库并显示',
                subtitle: '保留在设备里，下次也能随时看',
                onTap: c.gallery.length >= c.galleryCapacity
                    ? null
                    : () {
                        Navigator.pop(context);
                        c.send(saveGallery: true);
                      },
              ),
              const SizedBox(height: 10),
              _SendOption(
                icon: Icons.add_photo_alternate_outlined,
                title: '仅存入图库',
                subtitle: '保持当前屏幕不变',
                onTap: c.gallery.length >= c.galleryCapacity
                    ? null
                    : () {
                        Navigator.pop(context);
                        c.send(saveGallery: true, storeOnly: true);
                      },
              ),
              if (c.gallery.length >= c.galleryCapacity)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    '设备图库已满，请先删除一张图片。',
                    style: TextStyle(color: mutedText),
                  ),
                ),
            ],
            const SizedBox(height: 20),
            const Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: mutedText),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '墨水屏刷新时会闪烁，请保持连接直到完成。',
                    style: TextStyle(fontSize: 12, color: mutedText),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _SendOption extends StatelessWidget {
  const _SendOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: onTap == null ? const Color(0xFFE9EBEF) : Colors.white,
    borderRadius: BorderRadius.circular(20),
    child: ListTile(
      enabled: onTap != null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      contentPadding: const EdgeInsets.all(14),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF1FD),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: const Color(0xFF1967D2)),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.arrow_forward_rounded, size: 20),
      onTap: onTap,
    ),
  );
}

Future<void> showLogsSheet(BuildContext context, EspInkController c) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => AnimatedBuilder(
        animation: c,
        builder: (context, _) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .72,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '连接与操作日志',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: '复制日志',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: c.logs.join('\n')),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('日志已复制')),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy_all_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEDF1F6),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: c.logs.isEmpty
                          ? const Center(
                              child: Text(
                                '还没有操作记录',
                                style: TextStyle(color: mutedText),
                              ),
                            )
                          : ListView.builder(
                              itemCount: c.logs.length,
                              itemBuilder: (context, i) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: SelectableText(
                                  c.logs[i],
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    height: 1.55,
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

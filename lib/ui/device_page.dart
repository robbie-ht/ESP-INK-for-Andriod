import 'dart:convert';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'components.dart';
import 'sheets.dart';

class DevicePage extends StatelessWidget {
  const DevicePage({super.key, required this.c});
  final MoinkController c;
  bool get enabled => (c.connected || c.demo) && (!c.busy || c.galleryReading);
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('和墨印，保持连接。', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 8),
      const Text('屏幕的状态，日常的小习惯，都在这里。', style: TextStyle(color: mutedText)),
      const SizedBox(height: 25),
      SectionCard(
        color: const Color(0xFFEAF1FD),
        child: LayoutBuilder(
          builder: (context, box) => Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 28,
            runSpacing: 22,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 84,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAFCFF),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFFCFDDF4),
                        width: 5,
                      ),
                    ),
                    child: const Icon(
                      Icons.landscape_rounded,
                      color: Color(0xFF75A2E6),
                      size: 38,
                    ),
                  ),
                  const SizedBox(width: 18),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth - 118),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.deviceName,
                          style: Theme.of(context).textTheme.titleLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 7),
                        Text(
                          c.demo
                              ? '本地演示 · 无真实设备连接'
                              : c.connected
                              ? '${c.deviceState} · 四彩墨水屏'
                              : '按一下设备按键，唤醒后靠近手机',
                          style: const TextStyle(
                            fontSize: 12,
                            color: mutedText,
                          ),
                        ),
                        const SizedBox(height: 9),
                        const InkDots(size: 9, spacing: 6),
                      ],
                    ),
                  ),
                ],
              ),
              c.connected
                  ? OutlinedButton.icon(
                      onPressed: c.busy && !c.galleryReading
                          ? null
                          : c.disconnect,
                      icon: const Icon(Icons.link_off_rounded, size: 18),
                      label: const Text('断开连接'),
                    )
                  : FilledButton.icon(
                      onPressed: c.connecting || c.busy
                          ? null
                          : () => showConnectionSheet(context, c),
                      icon: const Icon(Icons.bluetooth_rounded, size: 18),
                      label: const Text('连接设备'),
                    ),
            ],
          ),
        ),
      ),
      if (c.rebootRequired)
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: SectionCard(
            color: const Color(0xFFFFF2D8),
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.restart_alt_rounded),
                const SizedBox(width: 12),
                const Expanded(child: Text('引脚设置已保存，重启后才能生效。')),
                TextButton(
                  onPressed: enabled ? c.reboot : null,
                  child: const Text('重启'),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 22),
      LayoutBuilder(
        builder: (context, constraints) {
          final first = Column(
            children: [
              _status(context),
              const SizedBox(height: 20),
              _preferences(context),
            ],
          );
          final second = Column(
            children: [
              _maintenance(context),
              const SizedBox(height: 20),
              _advanced(context),
            ],
          );
          return constraints.maxWidth >= 820
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: first),
                    const SizedBox(width: 22),
                    Expanded(child: second),
                  ],
                )
              : Column(children: [first, const SizedBox(height: 20), second]);
        },
      ),
      const SizedBox(height: 26),
    ],
  );

  Widget _status(BuildContext context) => SectionCard(
    child: Column(
      children: [
        SectionTitle(
          '此刻的状态',
          trailing: IconButton(
            tooltip: '刷新状态',
            onPressed: enabled ? c.refresh : null,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _metric(
                Icons.battery_4_bar_rounded,
                '电池电压',
                !c.connected || c.batteryMv == null || c.batteryMv! < 0
                    ? '暂无读数'
                    : '${(c.batteryMv! / 1000).toStringAsFixed(2)} V',
                subtitle: !c.connected
                    ? c.demo
                          ? '演示不提供实测电压'
                          : '连接后读取'
                    : c.batteryMv == null
                    ? '等待有效采样，空闲时重读'
                    : c.batteryReadingStale
                    ? '上次有效读数，正在等待新采样'
                    : '空闲时自动更新',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _metric(Icons.sensors_rounded, '设备状态', c.deviceState),
            ),
          ],
        ),
        const SizedBox(height: 17),
        _detail('固件版本', c.firmware),
        _detail('屏幕规格', '768 × 552 · 四色'),
        _detail(
          '屏型',
          c.connected || c.demo
              ? (c.settings.panel == 0 ? 'A0' : 'A1')
              : '连接后读取',
        ),
      ],
    ),
  );
  Widget _metric(
    IconData icon,
    String title,
    String value, {
    String? subtitle,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: sectionFill,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 21, color: const Color(0xFF5475A4)),
        const SizedBox(height: 11),
        Text(
          value,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 3),
        Text(title, style: const TextStyle(fontSize: 11, color: mutedText)),
        if (subtitle != null) ...[
          const SizedBox(height: 5),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 10, color: mutedText),
          ),
        ],
      ],
    ),
  );
  Widget _detail(String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Text(title, style: const TextStyle(fontSize: 12, color: mutedText)),
        const Spacer(),
        Text(value, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
  Widget _preferences(BuildContext context) => SectionCard(
    padding: const EdgeInsets.fromLTRB(22, 22, 12, 12),
    child: Column(
      children: [
        const Padding(
          padding: EdgeInsets.only(right: 10, bottom: 13),
          child: SectionTitle('按你的习惯'),
        ),
        _row(
          Icons.tune_rounded,
          '屏幕与名称',
          '屏型、设备名称、最近画面缓存',
          enabled ? () => _displaySettings(context) : null,
        ),
        _row(
          Icons.bedtime_outlined,
          '休眠与唤醒',
          '空闲休眠、定时醒来、离线换图',
          enabled ? () => _powerSettings(context) : null,
        ),
        _row(
          Icons.power_settings_new_rounded,
          '让设备休息',
          '保留画面，按设备按键即可唤醒',
          enabled
              ? () async {
                  if (await confirmAction(
                    context,
                    title: '让墨印进入休眠？',
                    message: '屏幕上的画面会保留。蓝牙将断开，下次连接前请按设备按键唤醒；手机不能远程唤醒休眠设备。',
                    confirm: '进入休眠',
                  )) {
                    await c.sleep();
                  }
                }
              : null,
        ),
      ],
    ),
  );
  Widget _maintenance(BuildContext context) => SectionCard(
    padding: const EdgeInsets.fromLTRB(22, 22, 12, 12),
    child: Column(
      children: [
        const Padding(
          padding: EdgeInsets.only(right: 10, bottom: 13),
          child: SectionTitle('画面与维护'),
        ),
        _row(
          Icons.cached_rounded,
          '重刷最近画面',
          '从设备缓存重新显示',
          enabled ? c.showCache : null,
        ),
        _row(
          Icons.auto_fix_high_rounded,
          '清理屏幕残影',
          '执行两轮清理，屏幕会闪烁',
          enabled
              ? () async {
                  if (await confirmAction(
                    context,
                    title: '清理屏幕残影？',
                    message: '清理期间墨水屏会多次闪烁，请保持设备供电，等待作业结束。',
                    confirm: '开始清理',
                  )) {
                    await c.clearGhost(cycles: 2);
                  }
                }
              : null,
        ),
        _row(
          Icons.system_update_alt_rounded,
          '更新固件',
          '选择应用 .bin 文件',
          enabled ? () => _ota(context) : null,
        ),
      ],
    ),
  );
  Widget _advanced(BuildContext context) => SectionCard(
    padding: const EdgeInsets.fromLTRB(22, 10, 12, 12),
    child: Column(
      children: [
        ExpansionTile(
          key: const PageStorageKey<String>('device-advanced-expansion'),
          tilePadding: const EdgeInsets.only(right: 10),
          shape: const Border(),
          collapsedShape: const Border(),
          title: const Text(
            '高级设置',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            '接线、重启与恢复',
            style: TextStyle(fontSize: 11, color: mutedText),
          ),
          children: [
            _row(
              Icons.memory_rounded,
              '接线与 GPIO',
              '修改前请核对硬件接线',
              enabled ? () => _gpio(context) : null,
            ),
            _row(
              Icons.restart_alt_rounded,
              '重启设备',
              '会短暂断开蓝牙连接',
              enabled
                  ? () async {
                      if (await confirmAction(
                        context,
                        title: '重启墨印？',
                        message: '重启后需要重新连接设备。',
                        confirm: '重启',
                      )) {
                        await c.reboot();
                      }
                    }
                  : null,
            ),
            _row(
              Icons.settings_backup_restore_rounded,
              '恢复出厂设置',
              '保留图库和最近画面缓存',
              enabled
                  ? () async {
                      if (await confirmAction(
                        context,
                        title: '恢复设备设置？',
                        message: '名称、休眠、屏型与 GPIO 接线配置都会恢复出厂并重启。图库和最近画面缓存保留。请确认实际接线适合当前固件出厂整合板预设 2。',
                        confirm: '恢复设置',
                        danger: true,
                      )) {
                        await c.factoryReset();
                      }
                    }
                  : null,
            ),
          ],
        ),
        _row(
          Icons.code_rounded,
          '调试日志',
          '查看连接与操作记录',
          () => showLogsSheet(context, c),
        ),
      ],
    ),
  );
  Widget _row(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback? tap,
  ) => ListTile(
    contentPadding: const EdgeInsets.only(right: 5),
    enabled: tap != null,
    leading: Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: sectionFill,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(icon, size: 21),
    ),
    title: Text(
      title,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
    ),
    subtitle: Text(
      subtitle,
      style: const TextStyle(fontSize: 11, color: mutedText),
    ),
    trailing: const Icon(Icons.chevron_right_rounded, size: 19),
    onTap: tap,
  );

  Future<void> _displaySettings(BuildContext context) async {
    var settings = c.settings;
    var name = settings.name;
    final form = GlobalKey<FormState>();
    await _editSheet(
      context,
      '屏幕与名称',
      (context, setState) => [
        Form(
          key: form,
          child: TextFormField(
            initialValue: name,
            onChanged: (value) => name = value,
            decoration: const InputDecoration(
              labelText: '设备名称',
              hintText: '留空恢复默认名称',
            ),
            validator: (v) => utf8.encode(v ?? '').length > 20
                ? '名称最多 20 个 UTF-8 字节（约 6 个汉字）'
                : RegExp(r'[\x00-\x1F\x7F]').hasMatch(v ?? '')
                ? '名称不能包含控制字符'
                : null,
          ),
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<int>(
          initialValue: settings.panel,
          decoration: const InputDecoration(labelText: '屏幕型号'),
          items: const [
            DropdownMenuItem(value: 0, child: Text('A0')),
            DropdownMenuItem(value: 1, child: Text('A1')),
          ],
          onChanged: (v) =>
              setState(() => settings = settings.copyWith(panel: v)),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('保留最近画面缓存', style: TextStyle(fontSize: 14)),
          subtitle: const Text('下次可以直接重刷', style: TextStyle(fontSize: 12)),
          value: settings.cache,
          onChanged: (v) =>
              setState(() => settings = settings.copyWith(cache: v)),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: () {
            if (form.currentState!.validate()) {
              Navigator.pop(context);
              c.saveSettings(settings.copyWith(name: name));
            }
          },
          child: const Text('保存设置'),
        ),
      ],
    );
  }

  Future<void> _powerSettings(BuildContext context) async {
    var settings = c.settings;
    var idle = settings.sleepSeconds.toString();
    var wake = settings.wakeSeconds.toString();
    final form = GlobalKey<FormState>();
    String? seconds(String? value) {
      final n = int.tryParse(value ?? '');
      return n == null || n < 0 || n > 4294967295 ? '请输入有效的非负秒数' : null;
    }

    await _editSheet(
      context,
      '休眠与唤醒',
      (context, setState) => [
        Form(
          key: form,
          child: Column(
            children: [
              TextFormField(
                initialValue: idle,
                onChanged: (value) => idle = value,
                keyboardType: TextInputType.number,
                validator: seconds,
                decoration: const InputDecoration(
                  labelText: '空闲多久后休息',
                  suffixText: '秒',
                  helperText: '0 表示关闭普通空闲超时',
                ),
              ),
              const SizedBox(height: 18),
              TextFormField(
                initialValue: wake,
                onChanged: (value) => wake = value,
                keyboardType: TextInputType.number,
                validator: seconds,
                decoration: const InputDecoration(
                  labelText: '深睡后多久自动醒来',
                  suffixText: '秒',
                  helperText: '0 表示关闭定时唤醒',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        DropdownButtonFormField<int>(
          initialValue: settings.timeoutAction,
          decoration: const InputDecoration(labelText: '空闲超时动作'),
          items: const [
            DropdownMenuItem(value: 0, child: Text('深度休眠')),
            DropdownMenuItem(value: 1, child: Text('断电关机（需要自锁电路）')),
          ],
          onChanged: (v) =>
              setState(() => settings = settings.copyWith(timeoutAction: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('定时醒来时换下一张', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '使用设备图库，空图库时保留画面',
            style: TextStyle(fontSize: 11),
          ),
          value: settings.wakeShow,
          onChanged: (v) =>
              setState(() => settings = settings.copyWith(wakeShow: v)),
        ),
        const SizedBox(height: 12),
        const Text(
          '休眠时蓝牙会断开，手机不能通过蓝牙唤醒设备。关机后需要按设备按键唤醒。',
          style: TextStyle(fontSize: 12, color: mutedText),
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: () {
            if (form.currentState!.validate()) {
              Navigator.pop(context);
              c.saveSettings(
                settings.copyWith(
                  sleepSeconds: int.parse(idle),
                  wakeSeconds: int.parse(wake),
                ),
              );
            }
          },
          child: const Text('保存设置'),
        ),
      ],
    );
  }

  Future<void> _gpio(BuildContext context) async {
    var preset = c.settings.gpioPreset;
    var checked = false;
    String? error;
    final fields = [for (final pin in c.settings.pins) '$pin'];
    const labels = ['ADC', 'WAKE', 'SCK', 'MOSI', 'CS', 'DC', 'RST', 'BUSY'];
    await _editSheet(
      context,
      '接线与 GPIO',
      (context, setState) => [
        const SectionCard(
          color: Color(0xFFFFF2D8),
          padding: EdgeInsets.all(16),
          child: Text(
            '接线设置与屏幕型号彼此独立。错误的引脚配置可能导致屏幕或唤醒失效，保存后需要重启。',
            style: TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<int>(
          initialValue: preset,
          decoration: const InputDecoration(labelText: '接线预设'),
          items: const [
            DropdownMenuItem(value: 0, child: Text('原默认接线（预设 0）')),
            DropdownMenuItem(value: 1, child: Text('排线')),
            DropdownMenuItem(value: 2, child: Text('整合板（当前出厂预设 2）')),
            DropdownMenuItem(value: 3, child: Text('自定义 8 引脚')),
          ],
          onChanged: (v) => setState(() => preset = v!),
        ),
        const SizedBox(height: 18),
        if (preset == 0)
          const Text(
            '默认：ADC 0 · WAKE 5 · SCK 4 · MOSI 6\nCS 7 · DC 1 · RST 3 · BUSY 10',
            style: TextStyle(fontSize: 12, color: mutedText),
          ),
        if (preset == 2)
          const Text(
            '整合板：ADC 0 · WAKE 1 · SCK 4 · MOSI 3\nCS 5 · DC 6 · RST 7 · BUSY 10',
            style: TextStyle(fontSize: 12, color: mutedText),
          ),
        if (preset == 3) ...[
          Wrap(
            spacing: 12,
            runSpacing: 14,
            children: List.generate(
              8,
              (i) => SizedBox(
                width: 105,
                child: TextFormField(
                  initialValue: fields[i],
                  onChanged: (value) => fields[i] = value,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: labels[i],
                    prefixText: 'GPIO ',
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'ADC：0–4；WAKE：0–5；其它：0–10。\nGPIO 2 保留给自锁，所有引脚必须互不重复。',
            style: TextStyle(fontSize: 11, color: mutedText),
          ),
        ],
        const SizedBox(height: 18),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('我已核对实际接线，并了解需要重启', style: TextStyle(fontSize: 13)),
          value: checked,
          onChanged: (v) => setState(() => checked = v ?? false),
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: !checked
              ? null
              : () {
                  final pins = fields
                      .map((f) => int.tryParse(f) ?? -1)
                      .toList();
                  if (preset == 3 &&
                      (pins.any((p) => p < 0 || p > 10 || p == 2) ||
                          pins[0] > 4 ||
                          pins[1] > 5 ||
                          pins.toSet().length != 8)) {
                    setState(() => error = '请检查引脚范围、GPIO 2 保留限制与重复引脚。');
                    return;
                  }
                  Navigator.pop(context);
                  c.saveSettings(
                    c.settings.copyWith(
                      gpioPreset: preset,
                      pins: preset == 3 ? pins : c.settings.pins,
                    ),
                  );
                },
          child: const Text('保存接线设置'),
        ),
      ],
    );
  }

  Future<void> _ota(BuildContext context) async {
    var checked = false;
    await _editSheet(
      context,
      '更新墨印固件',
      (context, setState) => [
        const TonalLabel(
          '请保持供电和蓝牙连接',
          icon: Icons.info_outline_rounded,
          color: Color(0xFFFFF2D8),
          foreground: Color(0xFF8B6520),
        ),
        const SizedBox(height: 24),
        const Text(
          '1  选择正确的应用固件',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        const Text(
          '仅使用匹配 ESP32-C3、硬件和当前分区布局的应用 .bin。不能选择合并固件、bootloader 或分区表。B1 升 B2 需首次串口刷写。',
          style: TextStyle(fontSize: 12, color: mutedText),
        ),
        const SizedBox(height: 20),
        const Text(
          '2  留在此页面，等待校验与重启',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        const Text(
          '传输到 100% 还不代表升级完成。请勿断电、休眠或将应用切到后台。',
          style: TextStyle(fontSize: 12, color: mutedText),
        ),
        const SizedBox(height: 20),
        const Text(
          '3  重连并核对新版本',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        const Text(
          '新固件需稳定运行约 45 秒后确认。在此之前复位或断电可能触发回滚。',
          style: TextStyle(fontSize: 12, color: mutedText),
        ),
        const SizedBox(height: 18),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('已核对固件来源、硬件与分区布局', style: TextStyle(fontSize: 13)),
          value: checked,
          onChanged: (v) => setState(() => checked = v ?? false),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: checked && c.connected
              ? () {
                  Navigator.pop(context);
                  c.pickAndUpgrade();
                }
              : null,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('选择 .bin 并开始升级'),
        ),
        if (c.demo)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              '固件升级需要连接真实设备，演示不会传送固件。',
              style: TextStyle(fontSize: 12, color: mutedText),
            ),
          ),
      ],
    );
  }

  Future<void> _editSheet(
    BuildContext context,
    String title,
    List<Widget> Function(BuildContext, StateSetter) body,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .9,
          ),
          child: SingleChildScrollView(
            key: PageStorageKey<String>('device-settings-scroll-$title'),
            padding: EdgeInsets.fromLTRB(
              24,
              0,
              24,
              28 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 24),
                ...body(context, setState),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

# ESP-INK 1.0.8 · Windows x64

首次提供 Windows x64 桌面版。完整解压 `ESP-INK-1.0.8-windows-x64.zip` 后，双击 `ESP-INK.exe`，保留 DLL 和 data 文件夹。

- 保留 Material 3 界面、实时裁切、自动墨水屏效果，以及拍立得 C1 / 便签 C2 的独立调整。
- Windows 系统文件选择器选图，图库完整 PNG 通过“另存为”保存，内置中文字体。
- 新增 WinRT BLE：扫描、连接、EVT 通知、实际 MTU 和串行 CTRL/DATA 写入；发送、图库、设备设置、应用 OTA 共用 B2 协议。电脑需支持 BLE。
- 便携 ZIP 包含 Flutter、蓝牙/选图插件及 MSVC 运行库，不需要安装 JDK。无 Authenticode 签名。

目标为 Windows 10/11 x64；本次不发布新 Android APK，Android 继续使用 [1.0.7](https://github.com/robbie-ht/ESP-INK-for-Andriod/releases/tag/v1.0.7)。设备固件请到独立 [ESP_INK B2.0.1](https://github.com/robbie-ht/ESP_INK/releases/tag/B2.0.1) 下载。

Linux与Windows各424项Flutter测试及Dart分析通过，Windows Release实际编译118.3秒；30文件完整包、14项AMD64 PE32+、1.0.8+9产品版本、独立解包SHA256和中文空格路径的首帧窗口启动检查通过。成品61,507,582字节，SHA256：`fc5fed22035b0cf9173301cae1d2579cf6661a3c8a1106b9e98769540f62ccc4`。构建报告随包提供。

CI 不提供实体蓝牙设备，本次没有实测真实 Windows 蓝牙、图库回读、屏幕传输或 OTA，也没有刷写硬件。源码归档和 SHA256SUMS 随发布提供。

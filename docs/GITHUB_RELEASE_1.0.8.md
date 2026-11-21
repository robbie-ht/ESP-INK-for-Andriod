# ESP-INK 1.0.8 · Windows x64

首次提供 Windows x64 桌面版。完整解压 `ESP-INK-1.0.8-windows-x64.zip` 后，双击 `ESP-INK.exe`，保留 DLL 和 data 文件夹。

- 保留 Material 3 界面、实时裁切、自动墨水屏效果，以及拍立得 C1 / 便签 C2 的独立调整。
- Windows 系统文件选择器选图，图库完整 PNG 通过“另存为”保存，内置中文字体。
- 新增 WinRT BLE：扫描、连接、EVT 通知、实际 MTU 和串行 CTRL/DATA 写入；发送、图库、设备设置、应用 OTA 共用 B2 协议。电脑需支持 BLE。
- 便携 ZIP 包含 Flutter、蓝牙/选图插件及 MSVC 运行库，不需要安装 JDK。无 Authenticode 签名。

目标为 Windows 10/11 x64；本次不发布新 Android APK，Android 继续使用 [1.0.7](https://github.com/robbie-ht/ESP-INK-for-Andriod/releases/tag/v1.0.7)。设备固件请到独立 [ESP_INK B2.0.1](https://github.com/robbie-ht/ESP_INK/releases/tag/B2.0.1) 下载。

Linux最终424项Flutter测试、Dart分析与55项Windows边界联合检查通过。Windows Release实际编译、完整运行库/AMD64 PE/1.0.8+9产品版本/独立解包SHA256验证，以及中文空格解压路径下的首帧窗口启动检查，必须以发布附件构建报告中的实际结果为准。

CI 不提供实体蓝牙设备，本次没有实测真实 Windows 蓝牙、图库回读、屏幕传输或 OTA，也没有刷写硬件。源码归档和 SHA256SUMS 随发布提供。

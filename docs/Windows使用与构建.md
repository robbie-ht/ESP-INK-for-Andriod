# ESP-INK Windows 使用与构建

版本：1.0.9+10 / Windows x64，2026-11-22。

## 使用

1. 下载 `ESP-INK-1.0.9-windows-x64.zip`，完整解压到一个可写文件夹。
2. 双击文件夹中的 `ESP-INK.exe`。保持旁边的 DLL、data 和 licenses 文件夹完整，不要在压缩包内运行。
3. 主页选择拍立得后从 Windows 文件选择器选图，进入 C1 调整；便签进入 C2。中文字体已打包。图库完整 PNG 通过系统“另存为”保存。
4. 真实设备：开启电脑蓝牙，按设备按键唤醒，在 APP 连接窗口扫描并选择设备。电脑需要支持 BLE；Windows 管理蓝牙适配器和 MTU 协商。遇到关闭/不可用提示可点蓝牙设置。不要求先在系统设置配对。

Windows 10/11 x64 为交付目标，ARM64 和 32 位系统未编译。程序未作 Authenticode 签名，系统可能显示未知发布者。下载来源和 SHA256 见发布页，不需要管理员权限运行 APP。

## 与 Android 共用的功能

图像裁切与实时预览、自动墨水屏效果、拍立得/便签独立模式、图库缩略图与完整帧、完整 PNG 保存、设置、电池、发送和应用 OTA 共用现有协议和业务层。Windows 使用 WinRT BLE，Android 保留原 Kotlin 桥；两端都根据真实 MTU 限制包长。B2.0.1 安全窗口协议和旧 B2.0.0 串行回退保持不变。

Windows 不能请求固定 MTU517，系统返回多少便使用多少；即使设备支持大包，也保持属性值不超过512字节。控制包有响应、图片 DATA 无响应，两类写入共用串行链；EVT 订阅完成才宣布连接就绪。协议收到回执才算设备任务完成，不能把 GATT 写入完成当作刷屏或 OTA 完成。

草稿参数和文字会保存；与 Android 原设计一样，照片字节不写入草稿 JSON，重启后需要重新选择照片。

## 本机重新编译

在 Windows 安装 Flutter **3.47.8**（Dart3.13.7）和 Visual Studio 2022 的“使用 C++ 的桌面开发”（含 Windows SDK/CMake），安装 PowerShell7。根目录执行：

```powershell
flutter config --enable-windows-desktop
flutter pub get --enforce-lockfile
flutter test
flutter build windows --release
pwsh -File tool/package_windows.ps1 -SmokeTest
```

Flutter3.47.8 的 Windows 命令按主机架构构建，未提供 `--target-platform` 参数；本工作流使用 x64 runner，并在打包时逐个验证 AMD64 PE。

实际编译目录：`build/windows/x64/runner/Release/`；ZIP、SHA256、构建报告输出到 `releases/windows/`。Windows 不嵌入 JVM，CMake 跳过 Android image_picker 间接依赖 jni 的可选 Java 探测，用户不需要 JDK。

打包脚本会加入 x64 MSVC app-local CRT，核对所有 exe/DLL 的 AMD64 PE32+、产品版本、数据/字体完整性，独立解包逐文件验证 SHA256，最后确认 APP 创建窗口并维持运行。需替换同版本本地包时显式加 `-Force`。

## GitHub Actions

Windows构建完成后仍须等待同版本Android APK验证通过，再按[双平台发布规则](RELEASING.md)一起发布；单独的Windows Actions artifact不等于正式发版。

`.github/workflows/windows-release.yml` 使用 Windows runner、固定 action commit 和精确 Flutter 版本，锁文件解析后执行分析、全部测试、Release 编译和打包。Actions artifact 包含完整 ZIP、摘要和构建报告，日志单独保存。工作流只有仓库读取权限；正式 GitHub Release 由发布操作单独上传。

Linux 可以分析、运行 Flutter 测试、打源码包；不能直接生成 Windows Release。不得把仅有 `windows/` 目录、CI 配置或者 Linux 单测通过写成 Windows 构建成功。

## 验证边界

1.0.8曾完成双平台424项、实际Release与解包启动检查；1.0.9新增OTA修复的最终结果见 [VERIFICATION](VERIFICATION.md)。CI 窗口启动与包结构验证不等于实体 Windows 蓝牙、真实屏幕传输/图库/OTA、中文输入和不同 DPI 验收；没有连接或刷写设备。固件独立发布于 [ESP_INK B2.0.1](https://github.com/robbie-ht/ESP_INK/releases/tag/B2.0.1)。

## 依赖与许可证

Windows BLE 使用固定 `universal_ble 3.4.0`（BSD-3-Clause），桌面文件选择使用 `file_selector_windows`。Flutter 的 NOTICES 以及 Noto 字体许可证随完整包提供，具体锁定版本见 `pubspec.lock`。

1.0.9实际CI44977701454：456项/静态检查、138.7秒Release、30文件/14AMD64 PE32+、解压逐文件SHA及中文空格路径窗口启动通过。本地完整编译产物保存在 `build/windows-1.0.9/x64/runner/Release`，旧1.0.8产物保留。详细记录与硬件边界见 [VERIFICATION](VERIFICATION.md)。

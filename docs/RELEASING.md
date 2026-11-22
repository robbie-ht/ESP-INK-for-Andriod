# Android 与 Windows 同步发布

2026-11-22，用户明确要求：每次APP更新，Android和Windows一起更新、一起Release。

## 固定规则

Android APK和Windows x64完整ZIP使用相同的`pubspec.yaml`版本号与构建号、同一份最终APP源码和锁定依赖。即使只修某个平台，也重新构建两端，不能让最新版Android和Windows停在不同版本。两端构建平台可以不同，编译输入必须对应同一源码版本。

两端验证全部通过后，只发布一个`v<version>` GitHub Release，同时提供APK、完整Windows ZIP、Windows构建报告、完整源码和SHA256SUMS。设备固件仍单独在ESP_INK仓库管理，不因APP发版重复发布固件。

## 每次发版流程

1. 完成修改、统一版本和依赖，记录最终源码提交与编译输入摘要；执行适用测试与静态检查。
2. 实际构建Android Release APK，核对包名、版本/构建号、ABI、ZIP完整性及原签名。
3. 使用Windows环境实际构建Release，执行测试与静态检查，打包完整ZIP；核对版本、x64 PE、DLL/CRT、字体、独立解包SHA和程序启动。Windows命令及CI见[Windows使用与构建](Windows使用与构建.md)。
4. 任一平台失败，先修复并重新验证；不能先公开另一端。若APP源码或锁定依赖再次变化，两端均须基于最终输入重新构建。
5. 准备同一个草稿Release，上传两端成品、构建报告、源码、SHA256SUMS和共同发布说明；核对附件齐全、同版本、大小和摘要后，再把草稿转为正式Release。
6. 公开后复核远端附件与本地产物一致，记录验证范围，保留本地实际编译文件、源码、文档和历史成品；交付目录不留软链接。

协议模拟、编译、包结构和Windows窗口启动与实体BLE/OTA验收分别记录，不把前者当作后者。纯文档或发布规则修改不改变APP版本，也不替换已经发布的安装包/ZIP/源码归档。

## 当前基线

[v1.0.9](https://github.com/robbie-ht/ESP-INK-for-Andriod/releases/tag/v1.0.9)已经在同一Release中提供Android APK和Windows x64 ZIP；本规则适用于之后每次APP更新。

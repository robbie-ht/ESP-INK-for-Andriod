# 实际验证记录

验证日期：2026-11-17。宿主 Linux x86_64，Docker 29.6.1，用户 UID/GID 1000:1000。

## 结果

- 最终 Dockerfile 实际构建成功；构建脚本复用缓存再次执行成功。
- 镜像：`flutter-android:3.47.8`。
- 镜像 ID：`sha256:161a99114fb9525b3a513f5df8c27fd14bd626356a677aab879322fdccaebb27`。
- `docker image inspect` 报告 Size 为 3,016,029,727 bytes；这不是整个 Docker 存储目录、解压层及构建缓存的总磁盘占用。
- `docker buildx build --check`：无警告。
- 四个脚本 Bash 语法检查通过；参数/空格路径/UID/GID/root拒绝/缓存/代理变量/错误码/空目录保护检查通过。
- `flutter doctor -v` 的 Flutter、Android toolchain、Network resources 均通过；仅提示没有连接设备。
- 容器实测 Flutter 3.47.8、Dart 3.13.7、OpenJDK 17.0.21、SDK Platform 36、Build Tools 36.0.0；SDK licenses 已全部接受。
- 已安装 NDK 28.2.13676358、CMake 3.22.1、platform-tools 37.0.1。platform-tools 使用本次构建时仓库版本。

## 完整应用打包

通过包内 `smoke-test.sh` 在全新目录创建默认 Android 项目，未修改生成的应用源码、Gradle 或签名配置。模板 Gradle 9.3.1，AGP 9.1.0，KGP 2.4.0。

| 产物 | 大小 | 结果 |
| --- | --- | --- |
| app-release.apk | 44,143,024 bytes | Release 构建成功，Gradle 阶段 261.4 秒 |
| app-release.aab | 44,300,262 bytes | Release 构建成功，Gradle 阶段 17.0 秒，复用前次依赖缓存 |

上述时间属于本机本次运行，不能作为其他主机的耗时保证。

两个文件的 ZIP CRC 检查通过；均含 Android manifest、DEX，以及 arm64-v8a、armeabi-v7a、x86_64 的 `libapp.so` / `libflutter.so`。宿主文件属主为 1000:1000。

- APK SHA256：`1bad97ce7b706d5ce29ec2881007c4cb96d646a75570b94e37f161a620d953f4`
- AAB SHA256：`7588817ab334c6626b2fd35731d950b96306282f7c8f705363dfbf4492514fd7`

APK `apksigner verify --verbose` 通过，v2 签名有效。AAB `jarsigner -verify` 退出0并报告 `jar verified.`，同时存在警告：默认debug证书自签名、无可信证书链/时间戳；以及 JarFile 与 JarInputStream 读取时的 manifest/签名可见性差异。实际ZIP中签名manifest位于末部，该结构检查不等于流式JAR读取或Google Play验收。没有重排或重新签名产物来消除提示，未将该结果写成无警告的正式发布签名验证。

## 已知提示与验证边界

APK/AAB 构建都出现 SDK XML 4→3 解析兼容提示，随后继续并成功。只读检查发现当前 AGP 对应 `repository:32.1.0` 的解析器含该警告和 namespace 回退逻辑；具体触发文件未追踪，不据此断言为 Flutter 旧依赖问题，也没有为隐藏提示而修改工具链。

本次通过的是 Docker 工具链和默认 Flutter 示例的 APK/AAB 编译。尚未验证用户自己的项目、第三方插件、正式发行密钥、商店上传、手机安装或运行；未测试 ARM64 宿主、Windows 或 macOS。示例的 Release 构建仍按模板使用 debug signing。

测试源码、产物、原始构建日志及校验 JSON 保存在本次聊天 `work/` 中；此配置包不包含示例安装包、大型 SDK 下载缓存或 Docker image tar。可在另一台 Linux x86_64 主机执行 `build-image.sh` 重建并运行 `smoke-test.sh` 复核。

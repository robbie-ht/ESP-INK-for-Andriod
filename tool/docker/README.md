# Flutter Android Docker 编译环境

用于在 Linux x86_64 主机上编译 Flutter Android APK / AAB。项目挂载到容器，编译产物直接保存在项目的 `build/` 目录。无需在宿主安装 Flutter、Android Studio 或 Android SDK。

2026-11-17 已在本机实际构建镜像，并用默认示例生成 Release APK 和 AAB。详细结果及警告边界见 [验证记录](VERIFICATION.md)。

## 环境

| 组件 | 固定版本 |
| --- | --- |
| Ubuntu | 24.04 |
| Flutter / Dart | 3.47.8 stable / 3.13.7 |
| Java | OpenJDK 17 |
| Android SDK Platform | 36 |
| Android SDK Build Tools | 36.0.0 |
| Android Command-line Tools | 22.0，下载编号 15859902 |
| Android NDK | 28.2.13676358 |
| Android CMake | 3.22.1 |

Flutter 3.47.8 新项目的模板使用 Gradle 9.3.1、AGP 9.1.0。已有项目仍使用自己的 Gradle Wrapper 和插件版本，脚本不会替换它们；旧项目需要自行核对与 Java 17 / Flutter 3.47.8 的兼容性。

Flutter 和 Android 命令行工具下载包均验证固定 SHA256。Ubuntu 系统包及 `platform-tools` 使用构建时仓库版本，因此不是字节级可复现镜像。构建会自动接受 Android SDK licenses；对应操作位于 Dockerfile 的 `sdkmanager --licenses`。

## 1. 构建镜像

在本目录中，以能调用 Docker 的普通用户执行：

```bash
./build-image.sh
```

镜像名为 `flutter-android:3.47.8`。需要 Docker Engine；本包面向 Linux x86_64（Windows 可在配置好 Docker 的 WSL2 Linux 环境使用，但本轮不验证 Windows）。首次需要联网下载数 GB 工具与依赖，建议 Docker 存储分区至少预留 20 GB，项目缓存另计。

镜像内 `builder` 的 UID/GID 默认与构建者一致。换到其他 UID 的主机，请在那里重新执行构建脚本，避免 Flutter SDK 写权限不匹配。不要用 `sudo` 调用这些脚本。

## 2. 编译已有项目

将下方路径换成含 `pubspec.yaml` 和 `android/` 的 Flutter 项目根目录：

```bash
# Release APK，默认同时包含 Flutter 支持的 Android CPU 架构
./build-app.sh /绝对路径/my_app apk

# 按 CPU 架构分别生成较小 APK
./build-app.sh /绝对路径/my_app apk --split-per-abi

# Release Android App Bundle
./build-app.sh /绝对路径/my_app aab
```

输出在宿主项目目录：

- 通用 APK：`build/app/outputs/flutter-apk/app-release.apk`
- 分架构 APK：`build/app/outputs/flutter-apk/app-*-release.apk`
- AAB：`build/app/outputs/bundle/release/app-release.aab`

Flavor 会影响文件名和目录。编译参数可继续追加，例如 `--flavor production -t lib/main_production.dart --dart-define=API_URL=https://example.com`。Flutter 会自动执行依赖解析；脚本不删除项目文件、不自动运行 `flutter clean`。

如果原项目只有 Linux 平台，先检查代码和插件是否支持 Android，再按需要运行下面命令添加 Android 工程；这一步会生成项目文件：

```bash
./run.sh /绝对路径/my_app flutter create --platforms=android .
```

## 3. 进入容器或检查环境

```bash
./run.sh /绝对路径/my_app
./run.sh /绝对路径/my_app flutter doctor -v
./run.sh /绝对路径/my_app flutter test
./run.sh /绝对路径/my_app flutter analyze
```

进入后工作目录为 `/workspace`，可以直接运行 `flutter build apk --release`。无界面容器中 Android Studio、浏览器或设备检测提示不等于编译失败；以 Android toolchain 检查及实际编译结果为准。

默认缓存目录为 `${XDG_CACHE_HOME:-$HOME/.cache}/flutter-android-docker`，其中 `pub/`、`gradle/`、`android/` 分别持久保存依赖与 Android 用户配置，包括示例的 debug keystore。容器退出后这些缓存仍保留。

可指定有足够空间的缓存目录：

```bash
FLUTTER_ANDROID_CACHE_DIR=/有写权限的数据盘/flutter-cache \
  ./build-app.sh /绝对路径/my_app apk
```

缓存目录需要由当前用户拥有。项目目录及缓存会被容器读写；容器以当前用户身份运行，产物不会变成 root 所有。脚本检查镜像构建者 UID/GID，遇到不同用户会提示重建。项目与缓存的路径支持空格，但不能包含逗号（Docker `--mount` 的分隔符）。项目之外的相对路径依赖没有自动挂载：monorepo 应将共同根目录传给 `run.sh`，在容器内进入子项目编译。

## 4. 用全新示例检查 APK 和 AAB

```bash
./smoke-test.sh /绝对路径/一个不存在或为空的示例目录
```

脚本会新建默认 Flutter Android 应用，再分别构建 Release APK 和 AAB。它拒绝非空目录，避免覆盖已有工程。

## 网络、升级与签名

- 首次编译需要访问 Flutter 下载站、pub.dev、Google Maven、Maven Central 和 Gradle 下载站；缓存预热不代表可以完全离线编译任意项目。
- 构建代理可通过 Docker 标准参数传入：`./build-image.sh --build-arg HTTP_PROXY --build-arg HTTPS_PROXY --build-arg NO_PROXY`。先在当前终端设置相应变量。
- 运行脚本会传入已设置的代理变量及 `PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL`。容器里的 `127.0.0.1` 是容器自身；代理地址应能从容器访问。Gradle / Java 可能还需要自己的代理配置，可在专用缓存的 `gradle/gradle.properties` 配置；不要把密码提交进项目。
- 更换 Flutter 时必须同步修改版本和 SHA256，并核对 Android SDK / NDK / Java 兼容关系，再重建、重跑示例；只改版本号会触发校验失败。
- APK/AAB 编译成功不等于完成正式发布签名。新建示例通常使用 debug 签名；正式发行需在项目中配置自己的 upload keystore 和 release signing。镜像不包含你的签名密钥。不要把私钥或密码写进 Dockerfile。
- 此环境负责 Android 编译；不包含 Android 模拟器或设备连接配置。第三方插件、设备安装和真实运行需要针对项目另行验证。

## 官方依据

- [Flutter Linux release 元数据](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)
- [Flutter 3.47.8 Android 默认版本](https://github.com/flutter/flutter/blob/3.47.8/packages/flutter_tools/lib/src/android/gradle_utils.dart)
- [AGP 9.1 的 Gradle、JDK、Build Tools 兼容表](https://developer.android.com/build/releases/agp-9-1-0-release-notes)
- [Android 命令行工具下载](https://developer.android.com/studio#command-tools)
- [Flutter APK/AAB 构建与签名](https://docs.flutter.dev/deployment/android)

具体实测结果见本目录 `VERIFICATION.md`。

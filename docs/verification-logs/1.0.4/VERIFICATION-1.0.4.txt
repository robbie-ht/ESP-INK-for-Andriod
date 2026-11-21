# ESP-INK 1.0.4 验证记录

日期：2026-11-21。应用采用独立ESP-INK名称，参考项目为[atunverse/moink（墨印 · MoInk）](https://github.com/atunverse/moink)，引用见README、[参考说明](reference/README.md)、功能对照与图像滤镜注释。历史[1.0.3验证记录](verification-logs/1.0.3/VERIFICATION-1.0.3.txt)及原接口资料保留真实旧名称。

## 身份与兼容边界

- 显示名称ESP-INK，Dart包esp_ink，Android包/namespace为io.github.robbieht.espink，版本1.0.4+5。
- Kotlin包、启动Activity和三个Dart/Android平台通道同步迁移；DEX已包含新包且不存在旧原生包。
- 包ID改变后独立安装，可与旧版并存，不删除旧版，也不自动继承旧草稿或权限。新文件保存到Pictures/ESP-INK，旧相册文件不删除。
- BLE服务、CTRL/DATA/EVT特征和CCCD UUID逐项与1.0.3比较不变；图像/OTA/B2报文字节契约保持，不强制改设备真实名称。原JS来源路径及金标fixture保留用于追溯。

## 自动检查

- 最终统一 **308项全部通过**：[tests.log](verification-logs/1.0.4/tests.log)。覆盖协议/MTU、图像金标与像素、实时裁切、预览流水线、空闲高清/缓存、电压、UI及新平台通道的mock对接。
- `dart analyze lib test`：No issues found，[analyze.log](verification-logs/1.0.4/analyze.log)。
- 84份改名后的源码/测试/构建输入在最终编译前捕获，编译后SHA256逐项不变：[build-inputs.json](verification-logs/1.0.4/build-inputs.json)与[identity-check.json](verification-logs/1.0.4/identity-check.json)。

## Web界面复核

实际Web Release构建 **18.7秒成功**，见[web-build.log](verification-logs/1.0.4/web-build.log)。在390×844、640×800、1280×720实看：页面标题与头部为ESP-INK；窄屏无重复中文品牌，640宽度头部不溢出，桌面显示ESP-INK与中性“四色墨水屏”描述。新名字较长，中等宽度采用紧凑品牌区。

- [手机](previews/1.0.4/esp-ink-phone.jpg)、[640宽度](previews/1.0.4/esp-ink-640.jpg)、[桌面](previews/1.0.4/esp-ink-desktop.jpg)。
- [浏览器操作记录](verification-logs/1.0.4/browser-check.json)、[控制台](verification-logs/1.0.4/browser-console.json)：无error，仅CPU渲染fallback警告。本次实看重点为品牌/排版，不重新声称真机图像或蓝牙性能。

## Android实际编译与成品

`ESP_INK_CACHE_DIR=/mnt/data/moink-flutter-work/docker-cache ./tool/build_android.sh apk`，Docker镜像flutter-android:3.47.8（Flutter3.47.8 / Dart3.13.7 / JDK17 / SDK36）。实际assembleRelease **58.2秒成功**，[android-build.log](verification-logs/1.0.4/android-build.log)。SDK XML3/4兼容警告保留，插件自动安装SDK35；未关闭TLS。宿主pub环境已恢复。

- [ESP-INK-1.0.4-android.apk](../releases/ESP-INK-1.0.4-android.apk)，与build实际副本SHA相同。
- aapt确认application-label=ESP-INK、applicationId=io.github.robbieht.espink、启动Activity同namespace、versionName1.0.4/code5，min24/target36，三ABI。见[apk-badging.log](verification-logs/1.0.4/apk-badging.log)。
- 379个ZIP条目CRC全部通过，DEX新包存在且旧包不存在；见[apk-integrity.json](verification-logs/1.0.4/apk-integrity.json)及身份检查。
- apksigner确认v2签名有效、与旧版使用相同测试证书，SHA256为6b487c9d967a408332050c6d2ad48f88b4b40612eb99b6712e5c2713feb06eaa；见[apk-signature.log](verification-logs/1.0.4/apk-signature.log)。同证书不改变包ID不同导致独立安装的事实，也不等于商店正式发行签名。

APK大小：105112577 bytes；SHA256：`407a4807c6217a422d6d10bae6cdaf96c50e6dfa1d11f195935a336c10b0965f`。

## 源码归档与GitHub

新通用包为[ESP-INK-Flutter-source.tar.gz](../releases/ESP-INK-Flutter-source.tar.gz)，打包脚本独立解包后核对每个文件SHA，具体文件数/大小/校验见[生成报告](../releases/source-package.json)和releases/SHA256SUMS。源码包不含完整build、SDK/缓存或签名凭据；APP本地实际build仍保留，整个目录无软链接。

首次品牌迁移前，原MoInk-Flutter-source.tar.gz保留原字节，并另存MoInk-1.0.3-source.tar.gz及source-package-1.0.3.json。旧verified归档、原APK及v1.0.3发布不覆盖。新源码及文档推送main，并发布[v1.0.4](https://github.com/robbie-ht/ESP-INK-for-Andriod/releases/tag/v1.0.4)的APK、源码包和SHA256SUMS；远端核对记录留在本地releases/github-v1.0.4/。

## 实物边界

本次未安装到真实手机、未连接或刷写ESP设备，BLE吞吐/ADC稳定/新相册目录实际落盘仍需[真机检查](hardware-check.md)。编译、模拟、文件校验及Web实看与实机验收分别记录。改名没有修改原设备协议或自动更改固件/广播名称。

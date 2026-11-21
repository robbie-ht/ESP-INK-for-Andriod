# MoInk 1.0.3 验证记录

日期：2026-11-21。工程、实际build、APK和文档均在APP真实目录；1.0.2恢复记录保存在[历史记录](verification-logs/recovery-2026-11-21/VERIFICATION-1.0.2.txt)。

## 本次变更

1. 墨水屏效果自动更新：激活效果模式时立即生成，参数变化240ms防抖，单处理队列合并最新草稿；原图交互不强制量化。发送使用捕获的同一份快照。
2. 固定预览调参：独立效果页面，竖屏上方固定图/下方滚动参数，横屏左右并排；保留上一张效果并明确更新中，去掉手动刷新按钮。
3. 图库先缩略图后高清：设备空闲时后台逐张补读完整画面；在途当前回包排空后可取消，不与前台操作竞争，不发送读事务ABORT。打开的大图随后台高清升级并保留缩放。
4. 只在确认追加成功、同会话、元数据前缀和单步revision均吻合时迁移已验证高清缓存；删除、换槽、断线和异常revision仍清除。包含存成功但显示失败的部分结果。这是会话内存缓存，不承诺退出APP或重连后保留。
5. 电压保留同连接最近有效采样并标旧，空闲每15秒轻量GET_STATUS重读，低电量事件的真实电压纳入更新；无有效值时说明等待采样，不推断未接电池或没电。

## 自动检查

- 最终统一 **308项测试全部通过**：[tests.log](verification-logs/1.0.3/tests.log)。涵盖算法金标、真实处理器像素、裁切、原生桥模拟、B2协议、MTU517通知限长、预览合并/过期、后台取消/忙态恢复、追加保留/失效、电压和UI。
- 最终 `dart analyze lib test`：No issues found，[analyze.log](verification-logs/1.0.3/analyze.log)。图库30项专项日志见[gallery-final-race-tests.log](verification-logs/1.0.3/gallery-final-race-tests.log)。
- 真实15秒计时检查状态读取更新电压、设备BUSY后恢复完整帧，并确认不额外读取设置和图库元数据。两项确定性微任务交错检查await空闲后再确认前台占用，以及按owner清理取消早退的loading和尝试标记。
- 84份源码/测试/构建输入在最终编译前捕获，编译后逐份SHA256不变；Web对应63份非测试输入也一致。详见[build-inputs.json](verification-logs/1.0.3/build-inputs.json)和[final-input-check.json](verification-logs/1.0.3/final-input-check.json)。
- 旧UI字段映射用例已适配自动预览：保留真实updateDraft版本逻辑，注入即时处理结果检验最终草稿字段和预览结束；真实图像量化另由处理器测试和浏览器操作覆盖。初期并发编译诊断日志保留，最终结论只依据上述统一成功日志。

## Web实际界面复核

Flutter Web Release实际构建18.5秒，见[web-build.log](verification-logs/1.0.3/web-build.log)。在390×844和844×390导入本地[测试PNG](previews/1.0.3/test-landscape.png)，确认原图可见、切效果自动生成、独立调整页可用；竖屏滚到底部仍可见固定预览，对比度从0调至56后效果自动变化；横屏左图右参数且可独立滚到底部。

- [竖屏顶部](previews/1.0.3/effect-portrait-top.jpg)、[竖屏底部](previews/1.0.3/effect-portrait-bottom.jpg)、[自动调参后](previews/1.0.3/effect-portrait-adjusted.jpg)。
- [横屏参数](previews/1.0.3/effect-landscape-bottom.jpg)、[横屏底部](previews/1.0.3/effect-landscape-last.jpg)。
- [操作范围](verification-logs/1.0.3/browser-check.json)及[控制台](verification-logs/1.0.3/browser-console.json)：无error，只有CPU渲染fallback警告。浏览器结果不证明Android性能、BLE或相册落盘。

## Android实际构建与成品

使用本地已存在的Docker镜像 `flutter-android:3.47.8`：Flutter3.47.8 / Dart3.13.7 / JDK17 / Android SDK36，镜像ID `sha256:161a99114fb9525b3a513f5df8c27fd14bd626356a677aab879322fdccaebb27`。`MOINK_CACHE_DIR=/mnt/data/moink-flutter-work/docker-cache ./tool/build_android.sh apk` 实际assembleRelease **56.9秒成功**，见[android-build.log](verification-logs/1.0.3/android-build.log)。SDK XML3/4兼容警告保留，依赖自动安装SDK35；没有放宽TLS。宿主离线pub配置已恢复。

- 安装包：[MoInk-1.0.3-android.apk](../releases/MoInk-1.0.3-android.apk)，与实际build副本SHA一致。
- 应用ID `app.moink.moink_app`，versionName1.0.3 / versionCode4，minSdk24 / targetSdk36；arm64-v8a、armeabi-v7a、x86_64三ABI。
- 379 ZIP条目CRC全部通过，manifest、DEX、原生库和三套中文字体存在；见[apk-integrity.json](verification-logs/1.0.3/apk-integrity.json)及[apk-badging.log](verification-logs/1.0.3/apk-badging.log)。
- apksigner确认v2测试签名有效，证书SHA256与恢复版一致：`6b487c9d967a408332050c6d2ad48f88b4b40612eb99b6712e5c2713feb06eaa`。见[apk-signature.log](verification-logs/1.0.3/apk-signature.log)。这是测试签名，非商店发行签名。

APK大小：105112561 bytes；SHA256：`d3720a5ae77ec1b6a10de552187b4d20a3fad8785a9334bb09a38177dc72cfe5`。

## 源码包与目录

运行 `python3 tool/package_source.py` 输出[最新源码包](../releases/MoInk-Flutter-source.tar.gz)、根目录SOURCE_SHA256SUMS及releases/SHA256SUMS；独立解包后逐文件SHA一致，拒绝链接/路径穿越/重复成员。最终文件数、包SHA和打包范围以[生成报告](../releases/source-package.json)为准，源码包不含完整build、SDK/缓存或签名凭据。原来的恢复1.0.2源码包另保留为MoInk-1.0.2-source.tar.gz，旧APK与1.0.0归档保留。

APP全树软链接为0，build是真实目录。完整编译文件仍位于本APP/build，源码与测试在lib/test，照片与浏览器证据在docs/previews/1.0.3。

## 实物边界

本次没有当前可读的固件源码目录，电压采样的固件解释来自已保存接口文档和历史生产源码记录，不证明用户当前烧入版本。未连接实体设备或安装到手机，后台实际吞吐、电压ADC采样和相册最终落盘仍需按[真机步骤](hardware-check.md)实测。模拟链路、浏览器和编译结果分别记录，不混为真机验收。没有修改或烧录ESP固件。

## GitHub上传补充（2026-11-21）

发布仓库为[robbie-ht/ESP-INK-for-Andriod](https://github.com/robbie-ht/ESP-INK-for-Andriod)，分支main、标签v1.0.3。上传准备仅增加Git忽略规则、下载入口和发布说明，运行源码及上述84份构建/测试输入未改；APK沿用本次已验证产物。源码校验清单和归档因文档更新重新生成，最终SHA以Release的SHA256SUMS为准；此前1.0.3验证源码归档另保留为MoInk-1.0.3-verified-source.tar.gz。Git不提交build、缓存、local.properties或签名文件，明确包含Gradle wrapper与验证日志。

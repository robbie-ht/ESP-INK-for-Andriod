# ESP-INK 1.0.6 验证记录

日期：2026-11-21，版本1.0.6+7，Android应用ID仍为io.github.robbieht.espink。参考项目：[atunverse/moink](https://github.com/atunverse/moink)。历史[1.0.5验证记录](verification-logs/1.0.5/VERIFICATION-1.0.5.txt)及旧APK/源码归档保留。

## 本次行为

- A预览区先弹出底部类型选择窗。选拍立得后打开系统相册B，成功进入固定照片编辑C1；选便签直接进入固定便签编辑C2。C1含照片、裁切旋转、留白、滤镜与文字，C2仅底色和文字。两页不再切类型，文字列表独立。完成返回A后，调整按钮按当前draft.kind直达C1或C2，不重复弹窗或选图。取消选择保留原模式和草稿；选便签会使迟到的丢失照片恢复失效。
- 删除图二后，图一已缓存PNG和高清状态保留，不再清空卡片或重新读图。确认本APP成功单次删除后，验证同会话、回执、完整旧快照、数量、单步revision（含回绕）、INFO/LIST与剩余元数据映射，按删除位置迁移slot与缓存。缩略图仍可空闲补高清；外部修改、异常回执/版本/元数据继续失效保护。删除不调用屏幕显示命令，用户本次反馈明确指APP预览重载。

## 自动检查

最终统一 **351项全部通过**：[tests.log](verification-logs/1.0.6/tests.log)。相对1.0.5新增24项：16项删除缓存、5项模式导航、2项便签与照片恢复竞争及1项隐藏照片文字后便签正常显示。Dart分析No issues found：[analyze.log](verification-logs/1.0.6/analyze.log)。

删除核心回归逐次监听通知，断言图一PNG始终是同一对象、高清及current保留；空闲650ms后无READ，命令只有DELETE/INFO/LIST。覆盖三图删除首项后的不同PNG/高清映射、当前项、空库、revision回绕、缩略图自动补高清、7种证明不一致、同frame CRC但缩略图变更、外部删除和失败不盲迁移。原slot错图保护、追加缓存及全部协议/图像/裁切/后台读取/电压回归保留。

模式回归覆盖先选类型才打开相册、便签不打开相册、弹窗取消整稿不变、独立页工具隔离、重进记住模式、两组文字独立，以及选便签对迟到恢复的保护。Android选图使用真实控制器+mock MethodChannel和XFile，不等于启动了Android系统相册或Activity回收实测。

87份最终编译/测试输入、64份Web非测试输入前后SHA不变：[build-inputs.json](verification-logs/1.0.6/build-inputs.json)、[web-inputs.json](verification-logs/1.0.6/web-inputs.json)、[input-check.json](verification-logs/1.0.6/input-check.json)。缓存修复中间343项已通过，证据保留cache-first-*；随后加入新模式流程，最终结果以351项统一记录为准。

## Web实际操作

Web Release实际 **18.9秒**构建成功：[web-build.log](verification-logs/1.0.6/web-build.log)。390×844实际走通A类型弹窗→便签C2→改黄色底→完成回A→调整直达同一C2；再从A选拍立得，实际浏览器file chooser选择本地PNG进入C1，完成回A，再调整直达C1。C1无便签类型开关，C2无照片工具；便签保留一段文字，照片为独立空文字列表。

[模式弹窗](previews/1.0.6/a-mode-sheet.jpg)、[便签C2](previews/1.0.6/c2-note.jpg)、[A便签](previews/1.0.6/a-note.jpg)、[重进C2](previews/1.0.6/c2-reopened.jpg)、[照片C1](previews/1.0.6/c1-photo.jpg)、[A照片](previews/1.0.6/a-photo.jpg)、[重进C1](previews/1.0.6/c1-reopened.jpg)。另有A空白首页，共8张实际截图。

[操作记录](verification-logs/1.0.6/before-final-followup-browser-check.json)、[控制台](verification-logs/1.0.6/before-final-followup-browser-console.json)：无error，仅CPU渲染fallback警告，不代表Android性能。本次没有实体BLE，因此图库缓存行为由协议/控制器回归验证，没有将演示或Web截图当设备删除实测。

模式浏览器截图/操作记录在350项阶段采集；随后补便签显字修复与移除电池旧读数副标题，最终351项与Web/Android均重新构建。所示模式页面布局未再改动。电压UI回归确认3.87V仍保留且已删除文案不存在；内部采样与轮询逻辑未改。

## Android实际构建

`ESP_INK_CACHE_DIR=/mnt/data/moink-flutter-work/docker-cache ./tool/build_android.sh apk`，Docker flutter-android:3.47.8，Flutter3.47.8 / Dart3.13.7 / JDK17 / SDK36。实际assembleRelease **40.1秒**成功：[android-build.log](verification-logs/1.0.6/android-build.log)。SDK XML3/4警告及插件安装SDK35记录保留，未关闭TLS，宿主pub环境已恢复。

- [ESP-INK-1.0.6-android.apk](../releases/ESP-INK-1.0.6-android.apk)，105129105 bytes，与实际build副本SHA相同：`0994edd00f4852a2aa652c0677e341de6b952a497dd99f07444f2c5df89cc59e`。
- [aapt](verification-logs/1.0.6/apk-badging.log)：ESP-INK，io.github.robbieht.espink，1.0.6/code7，min24/target36，三ABI。[ZIP完整性](verification-logs/1.0.6/apk-integrity.json)：379条CRC通过。
- [签名](verification-logs/1.0.6/apk-signature.log)：v2有效，与1.0.5/1.0.4相同开发测试证书，支持同应用覆盖更新；本次未在手机执行升级，不是商店发行签名。

## 归档与发布

源码、实际build、APK和文档均在用户指定APP真实目录，全树无软链接。新[ESP-INK-Flutter-source.tar.gz](../releases/ESP-INK-Flutter-source.tar.gz)独立解包逐文件核对SHA；文件数、包大小与SHA见[生成报告](../releases/source-package.json)，根SOURCE_SHA256SUMS与releases/SHA256SUMS分别为源/成品清单。原1.0.5通用源码保留为ESP-INK-1.0.5-source.tar.gz，新源码另有数据盘独立备份。旧版APK与归档不覆盖。

[GitHub v1.0.6](https://github.com/robbie-ht/ESP-INK-for-Andriod/releases/tag/v1.0.6)发布APK、源码包和SHA256SUMS；远端main/tag/tree与附件digest核对记录位于本地releases/github-v1.0.6。

## 实物边界

本次未安装真实手机、未连接或刷写ESP。Android原生相册/Activity恢复、实际BLE删图与缓存体验仍需[真机复核](hardware-check.md)。原生BLE/导出桥、协议和固件未改；本次删除缓存修复不要求先刷固件。

刷屏期间并行读取图库高清尚未开放：当前APP作业/协议队列与参考B2的BUSY契约会等待设备空闲。用户已进一步澄清此需求，当前固件源码路径待提供后核对，未把本版缓存修复声称为刷屏与读图并行。

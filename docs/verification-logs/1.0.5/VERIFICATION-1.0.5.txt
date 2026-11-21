# ESP-INK 1.0.5 验证记录

日期：2026-11-21。源码版本1.0.5+6，Android包名仍为io.github.robbieht.espink。参考项目：[atunverse/moink](https://github.com/atunverse/moink)。历史[1.0.4验证记录](verification-logs/1.0.4/VERIFICATION-1.0.4.txt)保留，旧APK与归档不覆盖。

## 本次行为

A主页保留一个选图/结果区，下面是“调整图片”“发送图片”。点击选图直接打开系统照片选择器B，成功后自动进入集中编辑页C；取消或读取失败留A，保留旧草稿。C默认墨水屏效果，固定预览，集中原图、裁切旋转、留白、文字、便签及全部滤镜。完成或返回保留编辑并回A，补齐最后一版效果；A的调整按钮直接重进C。

A互斥覆盖B与C；C内换图不嵌套新C，等待选图期间禁止退出。恢复选图一次消费，正常新选图优先于迟到恢复。照片普通重启仍不持久保存；Android原生相册及活动回收场景仍需真机确认。

## 自动检查

- 最终统一 **327项全部通过**：[tests.log](verification-logs/1.0.5/tests.log)，含原308项与新增19项。新增8项路由回归覆盖成功、空/有旧图取消、防重入、最后编辑回A、重进保留、无图便签入口及C选图退出锁；新增11项真实控制器加mock平台通道测试覆盖文件接受/异常/并发及恢复交错。
- `dart analyze lib test`：No issues found，[analyze.log](verification-logs/1.0.5/analyze.log)。旧实时预览及UI测试迁到C，保留受控异步转换、文字、几何与滤镜断言；路由内查找限定C，避免把底层A预览误当C。
- 87份源码/测试/构建输入冻结后统一测试并编译Android，SHA256逐项不变：[build-inputs.json](verification-logs/1.0.5/build-inputs.json)、[input-check.json](verification-logs/1.0.5/input-check.json)。Web的64份非测试输入与最终冻结版本一致：[web-inputs.json](verification-logs/1.0.5/web-inputs.json)。
- 初次迁移测试曾因屏外按钮和A/C同名预览查找失败，保留原日志；最终统一结果以上述tests.log为准。

## Web实际操作

Web Release实际构建 **19.0秒成功**：[web-build.log](verification-logs/1.0.5/web-build.log)。390×844从A点击选图，实际浏览器file chooser选择本地测试PNG，自动进入C；滚到参数底部，预览仍固定可见，将对比度56改为-51后效果自动变化。完成返回A显示最新结果，点调整直接重进C并保留效果。844×390验证左右分区。

- [A空白首页](previews/1.0.5/a-home.jpg)、[C初次进入](previews/1.0.5/c-editor.jpg)、[A最终结果](previews/1.0.5/a-result.jpg)、[C重新进入](previews/1.0.5/c-reopened.jpg)、[C横屏](previews/1.0.5/c-landscape.jpg)。
- 固定预览调节[前](previews/1.0.5/c-fixed-before.jpg)/[后](previews/1.0.5/c-fixed-after.jpg)，[操作记录](verification-logs/1.0.5/browser-check.json)及[控制台](verification-logs/1.0.5/browser-console.json)。无error，仅CPU渲染fallback警告；不代表Android性能。浏览器选择器不等于Android原生相册验收，取消/恢复在自动测试中使用mock。

## Android实际构建

`ESP_INK_CACHE_DIR=/mnt/data/moink-flutter-work/docker-cache ./tool/build_android.sh apk`，Docker flutter-android:3.47.8，Flutter3.47.8 / Dart3.13.7 / JDK17 / SDK36。实际assembleRelease **48.8秒成功**：[android-build.log](verification-logs/1.0.5/android-build.log)。保留SDK XML3/4警告及插件安装SDK35记录，未关闭TLS，宿主pub环境已恢复。

- [ESP-INK-1.0.5-android.apk](../releases/ESP-INK-1.0.5-android.apk)与实际build副本SHA一致，105112681 bytes，SHA256 `d32343f3822a9759841611ff01faa4171d5bdd3ea4ec0a50218acb4970e606a0`。
- [aapt](verification-logs/1.0.5/apk-badging.log)：label=ESP-INK，io.github.robbieht.espink，versionName1.0.5/code6，min24/target36，三ABI。[ZIP完整性](verification-logs/1.0.5/apk-integrity.json)：379条CRC通过。
- [验签](verification-logs/1.0.5/apk-signature.log)：v2有效，测试证书SHA256为6b487c9d967a408332050c6d2ad48f88b4b40612eb99b6712e5c2713feb06eaa，与1.0.4一致。相同包名与证书支持覆盖更新1.0.4；尚未在真实手机执行升级。仍为测试签名，非商店发行签名。

## 归档与发布入口

完整源码[ESP-INK-Flutter-source.tar.gz](../releases/ESP-INK-Flutter-source.tar.gz)由打包工具独立解包逐文件核对SHA；文件数、包SHA与大小见[生成报告](../releases/source-package.json)。源清单为根SOURCE_SHA256SUMS，成品清单为releases/SHA256SUMS。APP本地真实build保留，包不包含build、SDK缓存或签名材料，目录无软链接；1.0.4原通用归档另保留为ESP-INK-1.0.4-source.tar.gz。

[GitHub v1.0.5](https://github.com/robbie-ht/ESP-INK-for-Andriod/releases/tag/v1.0.5)发布APK、源码包和SHA256SUMS；远端commit/tag/tree与附件digest核对证据保留于本地releases/github-v1.0.5。另保存数据盘独立源码备份，旧v1.0.4附件保留。

## 验收边界

本次完成自动测试、Web操作、Android构建/结构/签名与文件归档检查，未安装到真实手机，未连接或刷写ESP设备。Android系统相册、活动回收恢复、BLE吞吐、ADC及相册落盘仍按[真机步骤](hardware-check.md)执行。设备协议、原生BLE/导出桥与固件未因本次导航调整而修改。

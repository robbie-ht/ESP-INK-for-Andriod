# ESP-INK 1.0.7与ESP_INK B2.0.1验证记录

日期：2026-11-21。APP为1.0.7+8、Android应用ID `io.github.robbieht.espink`。固件基线为用户给出的 [ESP_INK / 4909e4c](https://github.com/robbie-ht/ESP_INK/tree/4909e4c36172daa1d54a21ae4d4f0d6998eac007)，关键源码与恢复目录修改前逐字节一致。历史[1.0.6记录](verification-logs/1.0.6/VERIFICATION-1.0.6.txt)及旧APK/源码保留。

## APP回归与实现

最终统一 **389项全部通过**：[tests.log](verification-logs/1.0.7/tests.log)。相对1.0.6新增18项协议和20项控制器回归。Dart分析No issues found：[analyze.log](verification-logs/1.0.7/analyze.log)。

覆盖真实客户端的CTRL序号匹配、显示等待、分片元数据和CRC；验证show/cache/ghost/send窗口内HD在DISPLAY_DONE前完成且刷屏busy/phase/progress保持；旧固件和上传/存储/OTA不放开；窗口关闭排空在途响应后停止后续片段；后来排队修改不越过读尾；事件早于RSP、状态响应晚于STATE/DONE、同步readiness监听器重入及断连；flags1/3/7兼容与独立窗口追加证据；最终保存失败/错slot/count撤销暂存；已有追加/删除缓存、编辑器、相册和电压回归保留。

最后新增[迟到BUSY定向检查](verification-logs/1.0.7/busy-done-race-test.log)：DISPLAY_DONE已到后，旧BUSY不能重新阻塞读图；无新增GET_STATUS，2秒内恢复，严格核对一次BUSY加完整分片、CRC与同一身份，maxActiveReads=1。已重新运行389项与Android构建。前388项和49.1秒APK只是中间结果，记录为before-readiness-race-fix-*，没有发布。

排队读若跨追加使revision变化，会返回changed，再以新身份重新请求，不能静默拼接不同版本。STORE_DONE仍在完整作业末尾，flags7不替代最终回执。详细契约见[刷屏读取说明](刷屏期间读取图库.md)。

88份最终编译/测试输入在检查及构建前后SHA一致：[build-inputs.json](verification-logs/1.0.7/build-inputs.json)、[input-check.json](verification-logs/1.0.7/input-check.json)。本次改动集中于协议和控制器，未改变页面布局，未把旧Web演示截图当作BLE并行实测。

## Android产物

使用 `ESP_INK_CACHE_DIR=/mnt/data/moink-flutter-work/docker-cache ./tool/build_android.sh apk`，固定flutter-android:3.47.8、Flutter3.47.8/Dart3.13.7/JDK17/SDK36。实际assembleRelease成功：[android-build.log](verification-logs/1.0.7/android-build.log)。保留SDK XML3/4提示及插件SDK35安装记录；未关闭TLS。宿主pub环境已恢复。

[APK](../releases/ESP-INK-1.0.7-android.apk)与实际build副本一致，379条ZIP CRC通过、包含arm64-v8a/armeabi-v7a/x86_64。字节数和SHA见[完整性记录](verification-logs/1.0.7/apk-integrity.json)。[aapt](verification-logs/1.0.7/apk-badging.log)确认ESP-INK、1.0.7/code8、min24/target36与原包ID；[验签](verification-logs/1.0.7/apk-signature.log)确认v2有效且沿用1.0.4至1.0.6的开发测试证书。未执行手机覆盖安装，不是商店发行签名。

## 固件与复制核验

[B2.0.1完整验证记录](../firmware/B2.0.1/source/validation/B2.0.1/RESULTS.md)包含实际store/settings/cache主机错误注入、生产BLE函数提取、真实pthread互斥排空、6种状态/8种MTU/15条显示任务路径、帧编码27项、Python SDK16项及TypeScript SDK15项。TypeScript以Node experimental transform执行，未声称独立tsc分析。外设仍为模拟。

ESP-IDF5.2.2 Docker实际编译/链接成功，app445136B，静态D/IRAM102162B；这不代表运行期堆测量。配置阶段保留第三方OpenThread Git ownership非致命诊断，最终exit0，不能称作完全无警告。5个bin及4MiB合并镜像组件/偏移/SHA检查通过，当前分区表与旧B2.0.0同字节。

[OTA应用镜像](../firmware/B2.0.1/moink_B2.0.1_app.bin) SHA256为 `1cadab640ee3e09e268f604f1614dbbeeda9d9321b31d647a3fa25036bad2f26`；[manifest](../firmware/B2.0.1/manifest.json)记录integrated-board/preset2及引脚[0,1,4,3,5,6,7,10]、hardware_tested=false。有效NVS优先行为及分区不变，13份最终构建输入、16份保护文件不变。

102份选定固件源码与验证/历史材料逐字节复制到APP/firmware/B2.0.1/source；实际IDF编译目录复制到APP/build/firmware-B2.0.1/build-idf522，复制的app与OTA成品一致。APP/releases/firmware-B2.0.1-copy-check.json保留逐文件SHA。另提供基于4909e4c的ESP_INK-B2.0.1.patch。没有使用软链接。

## 归档与发布

[完整源码包](../releases/ESP-INK-Flutter-source.tar.gz)包含Flutter和设备固件源码、构建脚本、文档、验证材料与设备镜像，独立解包逐文件核对SHA。文件数、大小和摘要见[生成报告](../releases/source-package.json)。SOURCE_SHA256SUMS为源码清单，releases/SHA256SUMS为成品清单。原1.0.6通用源码保留为版本归档，最新源码另有数据盘独立备份。

[GitHub v1.0.7](https://github.com/robbie-ht/ESP-INK-for-Andriod/releases/tag/v1.0.7)发布APK、完整源码、B2.0.1 OTA应用及SHA256SUMS，远端核对记录放在本地releases/github-v1.0.7。固件修改源码随本APP仓库和源包交付；固件基线链接不表示已改写ESP_INK的main。

## 实机边界

本轮未连接、擦除或刷写ESP，也未安装真实手机或检验物理屏幕。新并行功能需要APP与B2.0.1同时使用；旧B2.0.0仍兼容但保持刷完再读。已有B2分区选app.bin走OTA，无需清图库；R/B1不能直接用此OTA跨分区升级，merged全量镜像与erase会覆盖数据。

真实BLE吞吐、通知丢失、射频/Flash/SPI并发、A0/A1面板、运行堆与电源稳定性仍待[硬件步骤](hardware-check.md)。窗口通知丢失时可能由15秒状态轮询补发现；窗口关闭时未完成的下载会丢弃部分数据后重读。没有把模拟通过写成实机验收。

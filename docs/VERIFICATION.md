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


## 1.0.8+9 Windows x64（2026-11-21）

新增 Windows runner、系统选图、WinRT BLE 和 GitHub Actions Windows 编译；Android 原生桥保留。`universal_ble`固定3.4.0，Windows以真实MTU分片、EVT订阅完成才连接就绪，CTRL/DATA串行。Windows选图新增10项回归，PNG桌面保存3项、Windows BLE 22项（含真实接口委派）已进入最终套件。Windows不嵌JVM，跳过Android间接JNI的可选探测。Linux最终 **424项全部通过**（51秒），Dart分析No issues found；三个Windows边界文件55项联合通过。首轮399日志与中间分析记录保留，最终结果以linux-tests.log/analyze.log为准。Windows实际编译与首帧启动尚待云端结果，完成结果将另存构建报告并追加下文。


### Windows最终构建和分发验证通过

[GitHub Actions run44896748384](https://github.com/robbie-ht/ESP-INK-for-Andriod/actions/runs/44896748384) 成功，编译提交63119ff1b0b12d5e4c5b1cad37dc874f1fa6aaf8，Flutter3.47.8/Dart3.13.7、VS2022/x64。Windows最终424项全通过、Dart分析无问题，Release实际编译118.3秒生成ESP-INK.exe。构建报告、最终日志和前两次CI失败证据均保留在verification-logs/1.0.8/，初次bootstrap JSON和不支持target-platform的命令问题均已修正；后续不使用该参数，架构通过PE检查确认。

完整ZIP为releases/windows/ESP-INK-1.0.8-windows-x64.zip，61507582字节，SHA256=fc5fed22035b0cf9173301cae1d2579cf6661a3c8a1106b9e98769540f62ccc4。30文件（29项内部SHA加清单本身）、14个AMD64 PE32+、嵌入1.0.8+9/ESP-INK产品版本、两插件/三字体/全10个MSVC CRT DLL检查通过；独立解包逐文件SHA、ZIP CRC通过。Windows CI从“解压 验证”中文空格路径启动了真正ZIP内的exe，首帧窗口ESP-INK出现后进程继续存活，再正常关闭。外部build.json记录启动和最终ZIP SHA，内置BUILD-INFO避免自引用。

下载回Linux后独立复查外部/内部SHA、30文件CRC、14PE架构、版本/编译提交报告，全通过；实际Windows Release文件已复制到APP/build/windows/x64/runner/Release/，源码、成品及文档继续为APP内实文件。临时Windows插件软链接已清理，SDK/依赖缓存正常由工具链管理。发布时仅增加文档和验证记录；Dart/Windows/pubspec等构建输入SHA未改变，具体数量见input-check.json。

本轮不构建新Android APK，已发布1.0.7 APK及旧源包保留。Windows实体蓝牙适配器、真实设备图库/传输/OTA、不同DPI/中文输入未实机验收；CI首帧启动不是这些功能的验收，没有刷写任何设备。


## 1.0.9+10 OTA入口与异常保护（2026-11-22）

用户仅报告OTA有问题，尚未补平台、错误/阶段和所选bin。已核对ESP_INK远端仍为B2.0.1/main3a1dd16，正常分片/CRC/END契约一致；没有证据断言用户本次根因或正常OTA必失败。设备固件未修改、未连接/刷写硬件。

APP修复：图库高清读取不再使OTA静默返回；选文件阶段抑制resume刷新、状态轮询和自动补读，单一升级流程防重入；文件length/read及读图排空后均复核原client与连接代次，断线换设备不发旧bin。接收取消、BEGIN回执待确认、校验失败与END提交待确认分别提示。未知结果会阻止继续修改和再次打开picker；END非法成功载荷同样保留unknown，不ABORT、不自动重发。

发送前加入ESP32-C3段边界、首段256字节app_desc及校验尾部空间检查，真实B2.0.1应用通过、同仓库bootloader等错误镜像拒绝。不验证镜像内部checksum/hash值、签名、硬件或分区布局；传输CRC32与设备最终镜像校验仍是独立步骤。使用及已知固件/文件提供器边界见 [OTA使用与排查](OTA使用与排查.md)。

Linux与Windows各456项全部通过；相对1.0.8新增14项协议、18项控制器回归，Linux51秒、Windows62秒。两端Dart分析均No issues found。真实协议客户端覆盖GAP/INCOMPLETE有限恢复、BEGIN超时、END异常/断线、取消/ABORT未知、重复升级保护、真实file_selector通道、生命周期及换连接场景。首轮测试适配问题与定向/全量通过日志分别保留；模拟不代表手机文件提供器或实体Flash行为。

Android assembleRelease105.2秒成功：`releases/ESP-INK-1.0.9-android.apk`，105977193字节，SHA256=10deb05191490beced995bf23d48d3a18b00741b8eaa1c79f5741c10f18920d6。379条ZIP CRC、原包ID、1.0.9/code10、min24/target36、三ABI和APK v2原开发证书均通过，可覆盖旧版同签名应用。

[Windows CI44977701454](https://github.com/robbie-ht/ESP-INK-for-Andriod/actions/runs/44977701454) 成功，实际编译提交47272fa7adf295b420f7dde541eb4e8599aae044、Flutter3.47.8/Dart3.13.7、VS2022/x64，Release编译138.7秒。完整ZIP `releases/windows/ESP-INK-1.0.9-windows-x64.zip`，61515942字节，SHA256=d3171cd9500b80bac958bde4df553e4a4d8d659c155dc004003f35ec942f3610。30文件、14个真实AMD64 PE32+、EXE版本1.0.9.10、两插件/三字体/10个CRT、内部逐文件SHA与ZIP CRC通过。CI从中文空格路径独立解压后启动ESP-INK窗口且进程保持存活。Linux下载后再次独立校验和实文件复制到 `build/windows-1.0.9/x64/runner/Release`；旧1.0.8目录及历史成品保留。许可证仅有Windows Git CRLF与Linux LF差异，归档内部仍逐字节SHA核对，源码文本单独仅归一CRLF比较。

本地112份快照未变化；其中111份受版本控制的编译/测试相关输入与Windows CI编译提交逐字匹配，另1份本地Android IDE .iml未入库、不参与构建。全部原始日志和报告保存在 `verification-logs/1.0.9/`。v1.0.9标签指向实际Windows编译提交；最终main/源码包另外收录构建报告与文档，编译输入相同。源码独立解包及远端附件摘要核对另存本地 `releases/source-package.json`、`releases/github-v1.0.9/`，避免归档自引用。

构建、协议/控制器模拟、包结构和Windows首帧启动均不替代Android/Windows实体BLE、手机系统文件提供器、设备Flash、断电回滚、45秒新固件确认实测。本轮未进行这些硬件验收。

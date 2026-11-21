# ESP-INK 1.0.7 + ESP_INK B2.0.1

墨水屏刷新时，原固件拒绝图库读取，APP也会等待完整显示作业。本版配合B2.0.1固件发布的安全只读窗口，让缩略图和高清继续下载，同时保留刷屏进度。存并显示会核对保存信号、图库版本和完整旧图片元数据，保留已有高清；最终回执异常时撤销不能确认的缓存。

需要同时升级APP和设备固件。旧B2.0.0仍兼容新APP，但新高清会等待刷屏完成。已采用B2分区的设备仅选择B2.0.1的app.bin进行OTA，无需擦除图库；R/B1分区不兼容，不能直接用此OTA文件迁移。

APP 389项统一回归与Dart静态分析通过；固件离线检查、ESP-IDF5.2.2构建及镜像校验通过。Android构建、签名及文件摘要以[验证记录](VERIFICATION.md)为准。未在真实手机/ESP/面板验证并行读取，未刷写设备。

附件为安卓APK、完整源码包、B2.0.1 OTA应用镜像及SHA256SUMS。源码包包含固件完整选定源码、编译脚本、验证记录和二进制；所有本地源码、实际编译目录和成品集中在APP真实目录，旧版归档保留。

参考项目：[atunverse/moink](https://github.com/atunverse/moink)；固件基线：[robbie-ht/ESP_INK](https://github.com/robbie-ht/ESP_INK/tree/4909e4c36172daa1d54a21ae4d4f0d6998eac007)。本项目客户端品牌为ESP-INK，不代表上游官方APP。

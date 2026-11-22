# OTA 使用与排查

1.0.9+10，2026-11-22。本次针对APP OTA入口和异常结果保护；用户最初具体错误/平台/所选文件尚未提供，不能把这些修复直接认定为该次故障根因。

## 选择哪个固件

设备已使用B2分区时，下载独立 [ESP_INK固件仓库](https://github.com/robbie-ht/ESP_INK/releases/tag/B2.0.1) 的 `moink_B2.0.1_app.bin`。不要选 `bootloader.bin`、`partition-table.bin`、`ota_data_initial.bin` 或 `moink_B2.0.1_merged.bin`。R/B1迁B2涉及分区表变化，需要第一次USB完整迁移，普通应用OTA不负责分区迁移。本次APP修复未修改或刷写设备固件。

新版APP会在发送OTA_BEGIN前检查大小、ESP32-C3头、段表及数据边界、首段256字节应用描述符、校验字节/SHA字段的储存空间。`bootloader.bin`虽然也是E9/chip5，因缺应用描述符会被提前拒绝。这些是结构检查，不校验checksum/SHA的值、签名、板型或分区兼容性；设备最终仍需校验并决定切槽。

## 入口行为

- 系统文件选择期间保留升级流程，暂停自动设备刷新/高清补读；已有读图先取消后续分片并排空在途回执，再发送OTA_BEGIN。返回APP不会因生命周期自动refresh抢占而无声退出。
- 一次只允许一个固件选择流程。文件及异步读取绑定原设备连接，断线或换设备后，旧选择不会发送给新设备，也不会覆盖新会话提示。
- 传输进度100%仅表示数据已发送，随后还要等OTA_END有效回执。接收取消、开始回执缺失、固件校验失败与提交结果待确认分别提示。
- OTA_END回执丢失、断线或异常成功载荷均可能已影响启动槽，APP不自动重发、不发送危险ABORT，也不将其显示为已升级成功；重新连接读取版本核对。

## 若仍失败

提供APP平台/版本、界面错误原文、选用bin文件名以及卡住阶段即可；无需提供密钥或整份手机日志。

- 文件选择/读取就报错：尚未发送蓝牙数据。锁定的Android文件选择插件依赖内容提供器报告文件大小，部分云端/未知大小文件会失败；可先将bin完整下载到手机Downloads，再从本地选择。普通content URI有临时授权，不意味着一定不能读取。
- 显示设备正忙：等待刷屏/存储等实际设备作业结束。APP已排空自身读图，并不代表能中断设备正在执行的写作业。
- 固件校验失败：核对选的是否为当前硬件和B2布局对应的app.bin。不要为此直接擦除图库或刷全量镜像。
- 提交结果待确认：先重新连接核对固件版本，暂勿重复升级。有效END后固件约1.5秒重启，新固件运行约45秒才确认；确认前断电/复位可能回滚。

## 已知设备端边界

当前B2.0.1的OTA_BEGIN没有检查PENDING_VERIFY，使用自管Flash写入而非esp_ota_begin；启动确认期内再次OTA可能触及原回滚槽。本轮没有修改该固件，需避免在45秒确认期内连续发第二次升级。这是独立源码风险，未认定为用户本次失败原因。

前台OTA期间不主动因普通inactive/pause取消传输，但目前没有保持唤醒或后台服务，需保持APP前台供电稳定。普通熄屏是否导致具体失败取决于系统行为，不能从源码断定每次都会中断。

## 验证范围

测试与构建结果见 [VERIFICATION](VERIFICATION.md)。协议/控制器模拟、镜像结构、APK/ZIP/启动检查均不替代手机/Windows BLE、物理Flash、bootloader回滚和设备端45秒确认实测。本轮未连接或刷写硬件。

参考：[ESP-IDF5.2.2镜像结构](https://docs.espressif.com/projects/esp-idf/en/v5.2.2/esp32c3/api-reference/system/app_image_format.html)、[ESP-IDF5.2.2 OTA](https://docs.espressif.com/projects/esp-idf/en/v5.2.2/esp32c3/api-reference/system/ota.html)。

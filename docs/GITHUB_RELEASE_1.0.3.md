# MoInk 1.0.3

Flutter / Material 3 Android伴侣应用，连接四彩墨水屏B2设备。

- 墨水屏效果自动更新；竖屏固定上方预览，横屏左右分栏，调参无需翻回顶部。
- 图库先读缩略图，空闲时自动补读高清；确认追加成功后保留已有高清预览。
- 偶发无效电压保留并标注最近有效读数，空闲每15秒重读。
- 保留MTU517下图库读响应总长不超过512字节的修复。

下载MoInk-1.0.3-android.apk安装，最低Android 7.0 / API24，包含arm64-v8a、armeabi-v7a、x86_64。应用ID app.moink.moink_app，版本1.0.3+4，使用与恢复1.0.2相同的测试证书。SHA256见同一Release的SHA256SUMS。

MoInk-Flutter-source.tar.gz包含完整源码、文档和Docker构建工具；GitHub自动生成的Source code归档对应v1.0.3标签。build、SDK、依赖缓存和签名凭据不进入Git；本地APP目录仍保留实际编译产物。

验证：308项测试、静态检查、横竖屏Web实看、Android Release构建、ZIP完整性与v2验签通过。手机BLE、实际ADC采样和相册落盘仍待实测；测试签名不等于商店正式发行签名。

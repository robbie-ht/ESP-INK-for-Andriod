# ESP-INK 1.0.4

应用正式采用 **ESP-INK** 名称，Flutter包、Android应用ID、界面文案、平台通道、导出图片名称和相册目录同步更新。

## 参考与致谢

照片/便签交互、四色图像风格与抖动算法参考 [atunverse/moink（墨印 · MoInk）](https://github.com/atunverse/moink)，感谢原作者。ESP-INK是本仓库独立Flutter Android客户端的名称，不代表上游官方应用；来源资料与历史记录保留原名。

## 安装与功能

下载ESP-INK-1.0.4-android.apk，最低Android7.0 / API24，包含arm64-v8a、armeabi-v7a、x86_64。包ID为io.github.robbieht.espink，版本1.0.4+5；新包独立安装，可与旧版并存，不删除旧版或自动迁移旧草稿/权限。新图片保存到Pictures/ESP-INK；旧相册文件保留。

保留自动墨水屏效果、固定预览调参、空闲补读高清、追加时高清缓存保留、无效电压标旧和15秒状态重读，以及MTU517的496字节读取限长。BLE UUID和报文协议未变，不会主动修改设备真实名称。

ESP-INK-Flutter-source.tar.gz包含完整源码、文档与Docker构建工具；SHA256见同Release的SHA256SUMS。旧v1.0.3标签和附件保留。

验证：308项测试与静态检查通过；Web新品牌及390/640/1280宽度实看、Android Release实际构建、379 ZIP CRC和v2验签通过。使用测试签名，实体手机BLE、ADC和MediaStore相册落盘仍待实测。

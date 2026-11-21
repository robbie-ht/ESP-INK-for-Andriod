ESP-INK 1.0.5 将照片流程整理为：主页A选择照片 → 系统相册B → 自动进入实时调整C → 完成返回A发送。

- A保留一个照片选择/结果区，下方为“调整图片”“发送图片”；调整按钮直接重进C，保留当前照片和参数。
- C固定显示预览，集中裁切、旋转、留白、文字、便签与完整滤镜，效果自动更新。取消系统选图保留旧照片，连续点击不重复打开页面，恢复选图只进入一次C。
- 完成时补齐最后一次效果，避免刚调完立即退出显示旧结果。C内更换照片等待期间禁止提前退出。

Android 7.0及以上，版本1.0.5+6，应用ID io.github.robbieht.espink，与ESP-INK 1.0.4包名和测试证书一致，可覆盖更新。旧MoInk 1.0.3及更早版本为不同应用，不自动迁移其草稿。本次仍使用开发测试签名。

327项测试及静态分析通过，Web实际走通A→B→C→A和重新调整，Android Release实际编译并通过ZIP完整性/签名检查；未安装到实体手机或连接ESP，原生相册/活动恢复及BLE仍待真机验收。保留自动高清、缓存、电压与MTU517读取限长修复。

附件：APK、完整源码压缩包和SHA256SUMS。源码与文档均在仓库中，Docker构建入口为tool/build_android.sh，详细证据见docs/VERIFICATION.md。

参考与致谢：[atunverse/moink（墨印 · MoInk）](https://github.com/atunverse/moink)。ESP-INK是本仓库Flutter Android客户端名称，不代表上游官方应用；历史来源与字体许可保留。

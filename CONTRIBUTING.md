# Contributing

提交变更前请确认：

1. 保留 `com.dlzz.harmonyasf`、`SteamArk*` 和 `steam_ark_*` 兼容标识，除非有明确迁移方案。
2. `steam_core` 的修改提交到 OpenHarmonyASF 子模块，不在应用仓库复制一份源码。
3. `steam_core` 不依赖 NGF、HarmonyOS、ArkUI 或平台 API。
4. 用户可见文案同时维护中文与英文资源，不能在页面硬编码。
5. 不提交真实账号、密码、Cookie、Token、验证码、maFile、签名或设备日志。
6. 功能按钮必须连接真实服务，或者明确门控并交接到已登录浏览器。
7. 使用 API 26 `assembleHap --no-daemon --stacktrace` 完成编译验证。

# `steam_core` 开源与可剥离边界

## 目标

ASF/Steam 的底层逻辑必须能够从 ASF工坊工程中独立取出，作为单独的
ArkTS 开源模块维护、测试和发布。`steam_core` 是这个边界，不是
`ngf_framework` 的业务扩展。

## 模块职责

`steam_core` 只包含：

- Steam 账号、会话、游戏掉落、库存和挂卡快照的强类型模型；
- CM UnifiedMessages 现代密码/二维码认证、Steam Guard/TOTP、refresh token
  状态机，以及无秘密 `SteamAuthPendingSnapshot` 导出/恢复契约；
- `ISteamCmIdentityResolver` 等宿主契约，用于在二维码轮询缺少 SteamID64 时
  由宿主完成一次性 CM 身份解析；
- Steam 服务契约和平台注入接口；
- varint/静态 Protobuf 编解码；
- Steam TOTP、maFile 和 ASF JSON 导入；
- Simple/Complex 挂卡规划与无平台状态协调逻辑；
- ASF 核心挂卡命令解析契约(`start`、`stop`、`pause`、`resume`、`status`、
  `play`、`reset`)以及独立的手动挂卡状态恢复逻辑；
- `ClientGamesPlayed` 的静态编码、32 槽位限制、自定义名称 Shortcut 语义和
  空 playing 状态停止行为；
- 徽章分页解析报告、跨页同步诊断和 CM 到挂卡桥接事件；
- 不依赖设备的单元测试和 fake transport。

`steam_core` 不包含：

- `ngf_framework` 依赖；
- `@kit.*`、HarmonyOS 上下文、ArkUI、RDB、AssetStore、通知和后台任务；
- Steam 密钥、refresh token、Cookie 等秘密数据的持久化；
- C# DLL、ASF `.db`、ASF Web UI、CLI、IPC 或远程 Worker 兼容层。

## 依赖方向

```text
steam_core  <-  entry/steamAdapters  <-  NGF/HarmonyOS APIs
     ^
     +-- 可独立复制、测试和开源
ngf_framework 仅提供通用网络、安全、数据和系统任务能力
```

核心通过 `IBinaryCrypto`、`ISteamTransport`、`IClock`、`IStateStore` 等
显式接口接收平台能力。这样可以在 Node/TS 兼容测试宿主、HarmonyOS
`entry` 适配器和未来其他宿主之间替换实现，而不改变挂卡算法。
徽章同步通过 `SteamBadgeSyncReport` 和 `BADGE_SYNCED` 事件暴露非敏感的
页数、重复项和解析警告；报告不包含密码、token、Cookie 或代理凭据。
命令解析通过 `SteamCommandRequest`、`SteamCommandResult` 和
`ISteamCommandExecutor` 连接宿主；`entry` 只提供账号路由和平台 runtime，
不会把 NGF 或 HarmonyOS API 带入核心。未实现的 ASF 命令不能被静默映射为
库存写操作、交易或兑换。
`ClientGamesPlayed` 的容量和自定义名称行为也在核心中保持为可测试的协议逻辑，
不会由 entry 页面自行拼接协议报文。

## 发布规则

1. 单独发布 `steam_core` 时保留本目录的 `README.md`、许可证和变更记录。
2. 任何新增文件都必须通过依赖边界扫描，不能导入 NGF 或 HarmonyOS API。
3. 秘密字段只能在认证调用的内存对象中短暂存在，不能进入快照、RDB、普通
   JSON 导出或普通日志。
   认证挑战的 `clientId`、`requestId`、SteamID、轮询间隔和 15 分钟内的
   过期窗口可以作为 `SteamAuthPendingSnapshot` 持久化，但恢复时必须重新从
   宿主安全存储读取凭据；格式错误或过期的挑战必须失效，不能发起请求。
   CM `sessionToken` 同样只允许由当前 CM client 在内存中短时提供，连接结束
   时清理，不属于开源核心的持久化实体或事件字段。
4. 基于 ASF 行为的实现应保持独立代码和来源说明；不复制 ASF 源文件，保留
   ASF/SteamKit2 作为行为参考的记录。
5. 核心模块的版本、测试和协议更新记录独立于应用 HAP 版本。

当前许可证为 Apache-2.0；发布前仍需由项目方确认 Steam 商标、ASF/SteamKit2
归属说明以及 AppGallery 政策结论。

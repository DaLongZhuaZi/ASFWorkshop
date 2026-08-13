# Steam 协议更新记录

| 日期 | 参考基线 | 已落地 | 未完成/门禁 |
|---|---|---|---|
| 2026-08-08 | ASF `a3b5c103427e33fdaf03fa6705aa91c9cfc7a0c7`；SteamKit2 3.4.0 源码与生成协议 | 十进制 uint64 varint/fixed64、静态 `ClientGamesPlayed` 编解码、Steam CM protobuf 帧、WSS `ClientHello`/登录顺序、登录请求/响应、`ClientSessionToken`、心跳、指数退避状态机、Steam TOTP、maFile/ASF JSON 导入、Simple/Complex 规划器 | 真实 WSS/TLS CM 登录、真实代理组合、掉卡通知、真实掉卡和 API26 实机长时验证 |
| 2026-08-08 | API26 SDK `@ohos.net.webSocket` 官方声明 | NGF WebSocket 门面检查 `Promise<boolean>` 连接结果；`entry` 增加二进制 `ArrayBuffer` 到 `Uint8Array` 的 CM wire 适配、WSS TLS 连接、系统/直连/HTTP/SOCKS5 配置传递 fake host 断言和宿主 scheduler/clock | 真实 WSS 连接、ClientHello/登录响应、SOCKS5 组合设备行为和设备端网络回归 |
| 2026-08-08 | ASF `ArchiWebHandler.Init`、`InventoryResponse`、`GetInventoryAsync` | `steam_core` 增加只读 Web transport/session 契约、inventory URL 游标构造、强类型 `assets`/`descriptions` 关联、`more_items`/`last_assetid` 解析、搜索/交易/市场过滤；`entry` 通过 NGF CookieJar 接入 `sessionid` 与 `steamLoginSecure` | 未完成 API26 HTTP/Cookie/代理实机验证、真实账号库存请求、徽章页同步和所有库存写操作 |

## 2026-08-09 CM 连接竞态屏障

- API26 WebSocket 声明允许连接 Promise 与 `open`/`close`/`error` 事件并行到达；NGF `WebSocketClientFacade` 现在为每个原生 socket 绑定连接代际，迟到的事件不能污染后续连接，且连接 Promise 在 socket 已关闭或报错时不会把状态提升为 `OPEN`。
- `steam_core` 的 `SteamCmClient` 与 `SteamCmAuthClient` 在 `wire.connect()` 返回前收到关闭、错误或用户断开时，会使当前连接尝试失效，不发送后续 Hello/Logon，并保留关闭/错误状态机结果。
- `SteamCore.test.ets` 新增 CM 与认证连接竞态 fake 用例；这些测试只证明异步状态边界，不代表真实 WSS/TLS、Steam 服务端认证或代理组合已通过。

## 2026-08-09 SteamKit2 CM endpoint 规范化

- 固定参考为 SteamKit2 `3.4.0` commit `1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7`：`SmartCMServerList.DefaultServerWebsocket` 为 `cmp1-sea1.steamserver.net:443`，`WebSocketContext.ConstructUri` 使用 `wss`、目标端口和 `/cmsocket/` 路径。
- `steam_core` 新增 `SteamCmEndpoint`，以强类型 host/port 解析 SteamKit2 的 `host[:port]` 形式，并兼容旧的 `wss://...` 配置输入；端口默认 `443`，64 位 SteamID 规则不受影响。
- HarmonyOS CM 适配器在连接边界把 endpoint 规范化为 `wss://<host>:<port>/cmsocket/`；运行时默认值已改为 `cmp1-sea1.steamserver.net:443`，不会把旧 `cm01` 地址继续作为默认回退。
- fake 测试覆盖 host:port、WSS 输入、括号 IPv6、无效 scheme/端口和适配器 URL 传递；仍未证明真实 DNS、TLS、CM 登录或代理组合已在 API26 设备上通过。

## 2026-08-09 SteamKit2 现代认证与 guard data

- 固定参考仍为 SteamKit2 3.4.0 commit
  `1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7`；新增 Steam RSA modulus/exponent
  十六进制 golden fixture，避免把大整数转换为 JavaScript `number`。
- Authentication Protobuf 编解码新增/复核二进制 `request_id`、guard data 和现代挑战字段；
  CM unified-message header 覆盖 `target_job_name`、`eresult`、`error_message`，auth
  job 只接受匹配的十进制 job ID，错误 job ID 会被忽略，超时和断线会拒绝 pending 请求。
- CM 登录 field 108 在同时存在 `refreshToken` 和 `accessToken` 时发送 refresh token，
  仅在缺失 refresh token 时回退 access token；现代认证挑战覆盖 `DuplicateRequest=29`、
  `new_client_id`、`new_guard_data` 和 refresh token 轮换。
- `guard_data` 被登记为 NGF 安全凭据种类，只能通过 `NGFSecureCredentialStore` 边界传递；
  不进入 `steam_core` 普通会话快照、状态 JSON、事件或日志。`steam_core` 的协议和认证
  实现仍可单独复制、测试和开源，不复制 SteamKit2 源码或二进制。
- API26 Hvigor 模块级测试：`steam_core 57/57`、`entry 33/33`，证明 fake transport、
  golden fixture 和 entry 安全边界通过；不替代真实 Steam 服务端认证或设备端网络验证。

## 2026-08-08 CM wire 记录

- `MsgHdrProtoBuf` 使用 little-endian `uint32` 消息号；protobuf 消息号设置 `0x80000000` 标志；随后是 little-endian `uint32` 的 protobuf header 长度、`CMsgProtoBufHeader` 和 body。
- `CMsgProtoBufHeader` 当前只编解码核心字段：`steamid` field 1 fixed64、`client_sessionid` field 2 int32、`jobid_source` field 10 fixed64、`jobid_target` field 11 fixed64。所有 64 位值在核心中保持十进制字符串。
- 已对齐消息号：`ClientHeartBeat=703`、`ClientLogOnResponse=751`、`ClientLoggedOff=757`、`ClientGamesPlayedWithDataBlob=5410`、`ClientLogon=5514`。
- 已对齐 `ClientSessionToken=850`；SteamKit2 `CMsgClientSessionToken` 的 body 只有 field 1 `uint64 token`，核心以十进制字符串解码，并把它限定为 CM client 的内存态 transient 值。断开、登出、传输错误和新连接开始时清理，不进入 `SteamSessionSnapshot`、事件、状态存储或普通日志。
- 已对齐物品公告消息号：`ClientItemAnnouncements=5576`、`ClientRequestItemAnnouncements=5577`。公告 field 1 为 `count_new_items`；field 2 为重复 `unseen_items`，其条目包含 appid、context_id、asset_id、amount、fixed32 获得时间和 source_appid。
- `CMsgClientLogon` 当前编码字段与 SteamKit2 3.4.0 生成声明对齐：协议版本 `65581`、客户端包版本 `1771`、`client_language` 字符串、OS、记住密码标记、client supplied SteamID、账号名、密码、login key、邮箱码、设备名、二次验证码、速率限制响应标记和 access token。一次性验证码只存在于发送前的内存选项中；密码、login key 和 token 只存在于发送前的内存对象，不进入事件和快照。
- WSS CM 连接由 TLS/HTTP WebSocket 提供传输保护；SteamKit2 的 `ChannelEncryptRequest/Response/Result` envelope 仅属于 TCP/UDP `EnvelopeEncryptedConnection` 路径，本实现尚未把 TCP/UDP envelope 接入设备 runtime，不能将其标为 WSS 已完成能力。
- NGF `WebSocketClientFacade` 对 SOCKS5 WSS 组合保持显式不支持；拒绝时状态收敛到 `ERROR`，entry fake host 只验证代理参数传递，不把该组合标记为设备端可用。
- `CMsgClientGamesPlayed.GamePlayed` 使用 `game_id` field 2 fixed64、`game_extra_info` field 7 string；外层 `games_played` 为 field 1，`client_os_type` 为 field 2。
- Steam CM 登录结果已记录 `AccountLogonDenied=63`、`InvalidLoginAuthCode=65`、`AccountLoginDeniedNeedTwoFactor=85`、`TwoFactorCodeMismatch=88`、`Expired=27`、`LogonSessionReplaced=34`，并映射到核心会话状态。
- 登录成功后核心会发送空 body 的 `ClientRequestItemAnnouncements`；收到公告后发出 `SteamCmEventType.ITEM_ANNOUNCEMENT`，事件只包含非秘密库存标识和计数。

验证覆盖：`SteamCore.test.ets` 中 fixed64 round-trip、CM frame round-trip、SteamKit2 登录请求 golden frame、带 `client_sessionid`/SteamID/心跳字段的登录响应 golden frame、`ClientSessionToken` 最大 uint64 golden body、protobuf 登出 frame、登录/心跳/游戏状态 fake transport、token 清理、指数退避和多账号隔离测试已加入；`SteamArkNetworkAdapter.test.ets` 覆盖 WSS URL 与 system/direct/HTTP/SOCKS5 proxy 配置传递。本轮按用户要求未执行 Hvigor、设备安装或真实 Steam 连接。

## 2026-08-08 CM session token 与响应 fixture 记录

- SteamKit2 参考文件：`SteamKit2/SteamKit2/Steam/CMClient.cs` 的 `HandleSessionToken()`、`HandleLogOnResponse()`；`SteamKit2/SteamKit2/Base/Generated/SteamMsgClientServer.cs` 的 `CMsgClientSessionToken`；`SteamKit2/SteamKit2/Base/Generated/SteamMsgClientServerLogin.cs` 的 `CMsgClientLogonResponse`/`CMsgClientLoggedOff`。参考基线为 [SteamKit commit 1c7bc9c](https://github.com/SteamRE/SteamKit/commit/1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7)。
- `OpenHarmonyASF/steam_core/src/main/ets/protocol/SteamClientSessionTokenCodec.ets` 使用静态 protobuf reader/writer，field 1 通过十进制 uint64 varint 处理，未引入 `number` 保存 64 位值。
- `SteamCmClient` 暴露的 `sessionToken` 仅用于同一 CM client 的短时内存消费；事件和 snapshot 不带 token，且所有 transport/登录终止路径会清理该值。核心 README 与开源边界继续声明不持久化秘密。
- `SteamCore.test.ets` 的固定报文验证了登录响应 header 长度、SteamID、`client_sessionid=42`、legacy/in-game heartbeat、extended result、session token 最大 uint64 和 `ClientLoggedOff` 的 `EResult=27`。
- 该 fixture 证明的是 SteamKit2 3.4.0 生成协议的字节布局，不替代 Steam 服务端实时响应。WSS TLS、HTTP Cookie、代理实际连通性、登录结果和后台稳定性仍须 API26 授权测试后确认。

## 2026-08-08 WSS proxy fake host 记录

- `entry/src/test/SteamArkNetworkAdapter.test.ets` 通过注入 `IWebSocketClient` fake host，确认 `wss://cm.example/cmsocket/`、User-Agent、system/direct/HTTP/SOCKS5 配置会按账号 CM wire 适配器原样传递。
- 生产 `WebSocketClientFacade` 仍将 SOCKS5 WSS 标记为不支持并显式抛出错误；fake host 测试只验证适配器契约，不把 SOCKS5 误报为设备端可用。

## 2026-08-08 Inventory read-only 记录

- ASF 参考实现使用 `steamLoginSecure` 值 `steamID||accessToken`，并向 Steam Community、Store、Help、Checkout 和 Web API 主机设置 `sessionid` / `steamLoginSecure` Cookie；HarmonyOS 适配器按同一行为建立 Cookie，Cookie 生命周期仍由注入的 NGF `IHttpSession` 负责。
- Steam Community inventory 请求路径为 `/inventory/{steamid}/{appid}/{contextid}`，查询参数至少包括 `l`、`count`，后续页使用 `start_assetid`。
- 响应的 `assets` 与 `descriptions` 按 `classid|instanceid` 关联；`assetid`、`classid`、`instanceid`、`last_assetid` 均以十进制字符串保存。
- `marketable`、`tradable` 支持布尔、数字和字符串形式；Trading Card 通过类型或 `tags.internal_name == item_class_2` 识别。Steam inventory JSON 通常不提供卡牌掉落可用状态，因此缺少显式字段时保留 `UNKNOWN`，不猜测为可掉落或已掉落。
- `SteamInventoryService` 只缓存非秘密库存页；没有 POST、交易、兑换、批量转移或其他库存写入口。

## 2026-08-08 API26 HTTP/Cookie 适配记录

- 本机 API26 `@ohos.net.http` 声明确认 `HttpResponse.cookies` 为字符串；NGF 会话将其交给独立 CookieJar 解析，响应 Cookie 不进入 `steam_core`。
- `sessionid` 和 `steamLoginSecure` 仅由 entry 宿主为 HTTPS Steam Web 主机建立；CookieJar 的 `Secure` 属性会阻止其出现在 HTTP 请求中，并按域名/路径筛选。
- `entry/src/test/SteamArkHttpAdapter.test.ets` 通过 fake session 验证 Cookie 跨请求更新、User-Agent、Accept、Referer、system/direct/HTTP/SOCKS5 配置传递和 `application/x-www-form-urlencoded` 特殊字符编码。测试摘要不包含请求正文，因此不会把认证秘密带入诊断文本。
- 该记录只证明 API 契约和适配器行为，不代表真实 Steam 认证、代理连通性、WSS TLS 或 API26 真机网络已通过。

## 2026-08-08 ClientGamesPlayed 自定义名称容量记录

- ASF `ArchiHandler.PlayGames()` 在存在自定义游戏名时，先发送空的
  `CMsgClientGamesPlayed`，随后把 Shortcut GameID
  `GameType.Shortcut + ModID:uint.MaxValue` 放在游戏列表首位。
- 当真实 AppID 将超过 32 个并行槽位时，ASF 移除首位 Shortcut 并继续发送真实
  AppID；因此自定义名称在达到容量上限时会被省略，而不会挤掉第 32 款真实游戏。
  没有自定义名称时，超过上限在发送前失败。
- `OpenHarmonyASF/steam_core/src/main/ets/cm/SteamCmClient.ets` 以十进制字符串保持
  Shortcut ID `18446744070488326144`，并过滤 `0` AppID；`stopGames()` 通过同一
  协议发送空列表。
- `SteamCore.test.ets` 固定了 32 款、自定义名称、33 款拒绝和空列表停止的行为。
  这些测试仍只证明 ASF/SteamKit2 参考行为和 fake wire 编码，不代表真实 Steam
  服务端接受或 API26 设备网络已验证。

## 维护规则

- `steam_core` 只记录协议行为和测试向量，不复制 ASF/SteamKit2 源文件。
- Steam 认证、CM 消息和 Web API 变化必须先新增 fixture 与协议说明，再修改
  解码器或状态机。
- 任何无法由 fake transport 验证的行为都不能标记为稳定实现。
- 参考提交、依赖版本和本地实测结果与 HAP 版本独立记录。

## 2026-08-08 ASF 命令与手动挂卡状态记录

- 已复核 ASF `Commands.cs` 与 `wiki/Commands.md`：`play` 会切换到手动挂卡，
  `reset` 恢复手动前的 playing 状态，`resume` 也承担恢复入口；`pause~` 和
  `pause&` 属于不同的临时暂停语义，不能直接当作永久 `pause`。
- `OpenHarmonyASF/steam_core/src/main/ets/commands/SteamCommandRouter.ets` 新增强类型命令
  解析、前缀校验、账号上下文、AppID 数量上限和执行结果契约；当前只实现
  `start`、`stop`、`pause`、`resume`、`status`、`play`、`reset`，未落地命令
  会返回解析失败，不执行隐式库存写入。
- `FarmingCoordinator` 新增独立手动模式，持久化当前手动 AppID、游戏名和
  前一自动状态；`tick` 不会覆盖手动列表，`reset/resume` 会恢复前一状态。
- `entry` 的 `SteamArkFarmingService.executeCommand()` 负责账号隔离和 runtime
  路由；核心命令类型仍可脱离 NGF/HarmonyOS 单独开源，状态 JSON 不含凭据。
- `SteamCore.test.ets` 覆盖命令前缀、账号目标、AppID/游戏名解析以及自动挂卡
  到手动挂卡再 reset 的恢复；`SteamArkFarmingService.test.ets` 覆盖 entry 路由和
  手动状态 JSON round-trip。

该记录仍只代表 fake transport 和静态对照结果，不代表真实 Steam 命令通道、
API26 设备后台稳定性或 ASF 所有命令已经完成。交易、兑换、移动确认和自动
资产转移继续保持关闭。

## 2026-08-09 只读命令与高风险命令边界

- `OpenHarmonyASF/steam_core/src/main/ets/commands/SteamCommandRouter.ets` 新增 `inventory`/`inv`
  和 `2fa`/`twofactor` 解析；两者通过 `ISteamReadOnlyCommandExecutor` 独立于挂卡
  执行器，分别返回库存页或非秘密的认证挑战快照。
- `trade` 和 `redeem` 现在可以被识别，但核心路由在执行前返回
  `HIGH_RISK_DISABLED`，不会触发 HTTP、CM、交易报价、兑换或库存写入。
- `SteamArkFarmingService` 的 `executeCommand` 只把 `inventory` 和 `2fa` 导向
  只读服务；库存使用现有 `SteamArkStateService.syncInventory` 的默认只读查询，
  认证命令只读取待处理挑战，不生成或记录 Steam Guard 秘密。
- API26 模块级 fake 测试重新通过：`steam_core 58/58`、`entry 33/33`。该结果只
  证明命令契约和注入边界，不代表真实 Steam 服务或设备端网络请求通过。

## 2026-08-09 HTTP CookieJar 生命周期与 API26 回归

- NGF `IHttpSession` 的 CookieJar 现在区分 host-only 与显式 domain Cookie，按请求 URL
  计算默认 path，并按 domain、path、Secure 属性筛选请求 Cookie；同一路径下按更具体路径优先排序。
- 响应 Cookie 解析支持包含 `Expires` 逗号的组合 `Set-Cookie` 记录，并按 `Max-Age` 优先于
  `Expires` 的规则处理过期和删除；构造请求头前会清理已过期记录，旧版安全存储记录仍可读取。
- `entry/src/test/SteamArkHttpAdapter.test.ets` 新增跨域、默认路径、组合响应、过期优先级和清理
  用例；API26 模块级测试 `entry 36/36`、`steam_core 58/58` 通过。
- 本轮 HAP 已在 API26 目标设备完成低风险启动、页面导航和高风险命令禁用回归，但没有真实
  Steam Cookie、HTTP 登录或库存请求；Cookie 与代理的真实设备网络门禁仍未完成。

## 2026-08-09 SteamKit2 CM UnifiedMessages 生产入口对齐

- SteamKit2 3.4.0 的现代认证行为继续以 [SteamKit commit 1c7bc9c](https://github.com/SteamRE/SteamKit/commit/1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7)
  为准：登录流程在 CM WebSocket 上通过 Unified
  Messages 发送 RSA 公钥、登录开始、Challenge poll 和 refresh token 请求，不以 HTTP 登录表单
  代替 CM 会话。
- HarmonyOS 生产组装入口已切换为 `SteamCmAuthClient` + `SteamCmAuthService` +
  `HarmonySteamCmWireTransport`，默认 CM endpoint 统一为 SteamKit2 参考值
  `cmp1-sea1.steamserver.net:443` 的规范化 WSS 地址；每账号的 WebSocket、HTTP Cookie
  会话和代理配置保持隔离。
- HTTP transport 仍用于独立协议和 header/Cookie 测试，不能被解释为生产认证入口；SOCKS5 WSS
  仍是显式宿主能力边界，不能在 HarmonyOS 侧伪装为已支持。
- API26 fake fixture、HAP 构建和低风险 UI 回归均通过，但本记录不证明 Steam DNS/TLS、真实 CM
  登录响应、代理连通性、真实 Cookie 会话或后台稳定性；真实凭据和真实 Steam 请求仍未使用。

## 2026-08-09 SteamCmAuth 持久化 SteamID 刷新路径

- 参考基线：SteamKit2 `3.4.0`，固定源码提交
  `1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7`；本次没有改变 Steam 协议字段编码。
- 变更：`SteamCmAuthService` 构造时可接收账户元数据中的 `accountId` 和 SteamID64，初始化
  `knownSteamIds`；生产工厂从 `SteamAccountProfile` 注入这两个非秘密字段。
- 原因：应用重启后认证服务实例不再拥有上一进程临时登记的 SteamID，refresh token 虽在安全存储中
  仍无法绑定到 `CAuthentication_AccessToken` 请求的 SteamID。
- 验证：fake 核心测试新增“服务重建后使用持久化 SteamID 刷新”用例；`steam_core 59/59`、
  `entry 36/36`，API26 HAP 构建和目标真机低风险 UI 回归均通过。
- 边界：没有使用真实 token、没有连接真实 CM/WSS；真实登录过期、refresh token 轮换、TLS、Cookie
  和代理组合仍需在独立授权测试账号与网络门禁中验证。

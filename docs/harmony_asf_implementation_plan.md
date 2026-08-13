# ASF工坊实施计划补充

> 对外产品名称统一为“ASF工坊 / ASF Workshop”。`SteamArk*` 类型、`pages/steamArk` 路径和
> `steam_ark_*` 持久化键是已有兼容标识，必须保留，不能作为产品更名的一部分替换。

## 独立 ASF 核心是发布门禁

ASF/Steam 的底层逻辑必须可以从 ASF工坊中剥离并单独开源。实现上以
`steam_core` 为硬边界：它是无平台依赖的 ArkTS HAR，只包含模型、协议、导入、
服务契约、挂卡算法和 fake transport 测试。

`steam_core` 禁止依赖 `ngf_framework`、HarmonyOS `@kit.*`、ArkUI、RDB、
AssetStore、通知、后台任务和应用上下文。密码、refresh/login key、shared
secret、identity secret、Cookie 和代理密码不能进入核心快照、RDB、普通 JSON
导出或普通日志；由 `entry` 的适配器通过显式接口注入。

## ASF工坊产品界面替换门禁

原有 NGF 页面、演示内容和旧产品导航不得继续作为 ASF工坊的用户可见界面。
必须完整替换 `entry` 当前用户可见的 NGF 页面体系，重新设计 ASF工坊的工作台、
账号、库存、网络、挂卡、设置和诊断页面；NGF 只保留为底层框架能力和开发验证依赖，
不保留旧 NGF 演示入口与旧页面内容在产品导航中并存。

新页面的设计语言必须同时满足以下约束：

- 以 HarmonyOS 7 的 HDS 组件、沉浸式顶栏、动态安全区、系统材质、主题和响应式布局为基础。
- 视觉和信息组织尽量贴近 Steam 客户端的工作台感：深色中性底色、Steam 蓝色强调、
  紧凑的账号/游戏/库存信息密度、清晰的在线状态和操作反馈；不复制 Steam 客户端代码或资产。
- 优先服务重复操作和状态扫描，不做营销式首页、巨大装饰性区域或与 Steam 工作流无关的框架演示卡片。
- 所有用户可见文案进入中英文资源，图标使用系统 Symbol；页面必须支持加载、空状态、错误、
  未登录、权限不足和高风险操作关闭等状态。
- 验收必须检查旧 NGF 路由和旧页面内容已从产品默认导航移除，页面路由、标题栏、资源键、
  安全区、主题和交互均符合 ASF工坊视觉规范，并通过 API26 目标尺寸的静态/截图回归。

这项界面替换是产品发布门禁，不因底层 NGF 框架验证页面已有设备回归而视为完成；
框架验证应与 ASF工坊产品入口解耦。

### 页面替换落地任务

- M4-UI-01：以 `SteamArkHomePage` 作为唯一产品默认入口，建立独立 `SteamArkRouteName`，
  清理 `main_pages.json`、Ability manifest、系统快捷入口和其他外部启动点中的 NGF 演示页面。
- M4-UI-02：将工作台、账号、挂卡、库存、网络、设置和诊断页面迁移到产品目录，移除产品代码对
  `MainMenuPage`、`HdsDemoRoutes` 和 NGF 演示页面的运行时依赖；NGF 页面源码只能留在明确隔离的开发验证范围。
- M4-UI-03：建立产品层设计 token，统一深色中性底、Steam 蓝/青强调、状态色、系统材质、HDS 沉浸式顶栏、
  安全区、响应式密度、加载/空/错误/未登录和高风险关闭状态；禁止恢复旧 NGF 的 Framework/Features/Showcase/Device 导航。
- M4-UI-04：完成中英文资源、系统 Symbol、稳定控件 ID、页面路由和窗口 profile 的静态审计，并在 API26
  目标尺寸完成截图矩阵验收；在此之前 M4 的“原生界面完成”保持未完成。
- M4-UI-05：将桌面元服务卡片改造成 ASF工坊状态卡，仅通过 `EntryAbility` 打开产品工作台；移除旧
  NGF 多实例 Ability/页面启动链，并把保留的 NGF 验证源码隔离到 `pages/devNgf`。兼容旧路径只能渲染
  `SteamArkHomePage`，不得恢复旧演示内容。

## 敏感操作门控补充

M5 的库存写入、徽章制作、交易、移动确认、兑换和资产转移必须通过 entry 层统一的
`SteamArkSensitiveActionGate`。门控每次操作前检查设备认证能力，按需申请
`ACCESS_BIOMETRIC`，生成新的随机 challenge 并调用系统用户认证；成功结果不持久化、
不跨页面复用，也不能单独改变库存写操作的默认关闭策略。门控必须覆盖权限拒绝、认证失败、
设备无能力和并发重复触发，后续写操作还必须叠加完整资产清单、用户二次确认和审计记录。

二次确认的 entry 契约为 `SteamArkAssetConfirmationRequest`、
`SteamArkAssetConfirmationSnapshot` 和 `SteamArkAssetConfirmationService`：快照绑定账号上下文、
动作、十进制字符串资产 ID、应用/库存上下文、数量和短期过期时间，最多 500 条资产且禁止重复 ID。
它只产生不可执行的内存审查数据；门控仅把确认 ID 和资产数量关联到审计 DTO，不把清单、商品描述或任何秘密写入
普通设置存储、事件载荷或日志。实际写服务必须在调用 Steam 写接口前重新验证快照与账号、动作和有效期，并在本阶段
保持写操作默认关闭。

页面设计完成后，允许使用 API26 工具链编译并安装到已连接的验证设备
`5KLBB25A10203862`；真机测试任务由项目方执行。本阶段不因设备在线而自动安装或替项目方宣称
认证弹窗、交易、库存写入或长时后台能力已通过。

## 里程碑落地顺序

1. M0：API26 工具链、官方 API 能力、代理组合、后台限制和政策预审。
2. M1：`steam_core` 独立 HAR；NGF 提供通用 HTTP/Cookie/WebSocket/安全存储能力。
3. M2：核心认证契约、RSA/HMAC/AES 适配、maFile 导入、CM 会话和重连状态机。
4. M3：掉卡事件、Simple/Complex 调度、多账号隔离、后台任务和常驻通知。
5. M4：库存只读、Steam 工作台接入，并完整替换现有 NGF 用户可见页面和产品导航，
   落实 HarmonyOS 7/HDS 与 Steam 客户端工作台风格的统一设计语言。
6. M5-M6：先确认安全边界，再逐步加入库存写操作、命令面板和 ASF 内置高级能力。
7. M7：确认旧 NGF 页面已从产品入口清除，再进行 API26 真机 8/24 小时、网络切换、
   系统回收、日志脱敏、许可证和政策验收。

权限边界补充：握持感知是 ASF工坊的实际交互能力，保留 `DETECT_GESTURE` 和
`ACTIVITY_MOTION`，用于 HDS 导航和高频操作的手持方向适配。`DETECT_GESTURE` 按 API26
权限模型由系统预授权/安装能力决定，应用不把它作为普通用户授权弹窗入口；`ACTIVITY_MOTION`
和 `ACCESS_BIOMETRIC` 在实际能力触发时由用户主动申请或确认，拒绝后保留明确的降级状态。
`ACCESS_BIOMETRIC` 同时作为敏感隐私操作的设备身份验证能力。定位、加速度计等没有产品消费者
的演示权限不得恢复。

每个里程碑都必须同时满足两个条件：核心模块仍可独立构建/测试；应用层仍只
通过契约调用核心，不能把平台实现倒灌到 `steam_core`。

## Steam 账号登录方案与安全门禁

### 登录通道

- 密码登录采用 SteamKit2 3.4.0 对齐的 CM WebSocket UnifiedMessages：先获取
  RSA 公钥，再用 RSA PKCS#1 v1.5 加密密码，随后执行
  `BeginAuthSessionViaCredentials`、Steam Guard 更新和轮询；不把密码放进 URL，
  不通过自建中继转发。
- 二维码登录采用 `BeginAuthSessionViaQR`，应用只展示 Steam 返回的短期
  `challenge_url`，由用户使用 Steam 手机端扫描并在手机端确认；应用按服务端间隔轮询。
  QR 轮询结果没有可靠的 SteamID64，完成后通过一次性 CM 登录解析服务端返回的
  `ClientLogonResponse` SteamID64，解析失败不得报告登录成功。
- 登录挑战必须覆盖 Steam Guard 邮件码、移动确认、设备 TOTP，以及登录过期、重复请求、
  网络断线和二维码超时。挑战快照最多恢复 15 分钟，恢复时必须重新从安全存储读取秘密。

### Steam API Key 结论

当前账号登录、CM 会话、挂卡和库存只读流程不需要申请 Steam Web API Key，也不应在
HAP 中硬编码任何 Key。它们使用 Steam 账号认证服务、CM WebSocket 和带 Cookie 的
Steam Community Web 会话。只有未来明确接入 Steam Web API 的公开数据接口时，才单独
评估用户提供的 API Key、接口范围、限流和 Valve/Steam 政策；API Key 不能替代账号登录，
也不能用于获取或保存密码、refresh token、Cookie 或移动确认秘密。

### 权限与系统能力

- 登录和只读同步的必要网络权限是 `ohos.permission.INTERNET`。
- 二维码由应用展示，不需要相机权限；应用不默认读取摄像头或扫描用户设备上的二维码。
- 后台挂机和常驻进度通知另受 `KEEP_BACKGROUND_RUNNING`、后台模式、通知授权和系统回收
  约束，不能把它们当作登录成功的前提。
- `DETECT_GESTURE`、`ACTIVITY_MOTION` 用于产品握持适配，`ACCESS_BIOMETRIC` 用于隐私和
  高风险操作的设备身份验证；拒绝时必须降级。定位、加速度计等无产品消费者权限不申请。

### 凭据存储与数据分层

- 账号元数据、SteamID64、会话状态、二维码挑战的非秘密标识、配置和迁移报告写入现有
  NGF 状态/数据库门面；SteamID64 和资产 ID 全部使用十进制字符串。
- 密码、refresh/access token、login key、shared secret、identity secret、device ID、
  guard data、Cookie/CSRF 和代理密码只能写入 NGF `NGFSecureCredentialStore` 的
  AssetStore 安全边界。登录成功后其他功能从该边界按账号读取，不从普通 JSON 或页面状态
  恢复秘密。
- 普通状态 JSON、ASF 导出、诊断日志、事件和 `SteamAuthPendingSnapshot` 均不得出现上述
  秘密。挑战快照只保留 client/request 标识、SteamID64、轮询间隔、过期时间和二维码 URL，
  且过期或格式错误时直接失效。
- 登录失败、注销、账号删除和安全存储写入失败必须有明确状态；日志只能记录阶段、错误码和
  脱敏消息，禁止记录密码、验证码、QR token、Cookie 或完整请求体。

### 发布门禁

在真实测试账号和单独授权网络环境可用前，只允许 fake transport、协议 golden fixture、
API26 构建和无凭据公开网络探针；不宣称真实 Steam 登录、真实二维码确认、后台挂机或
库存写操作已通过。真实验证完成后仍需进行凭据擦除、进程重启恢复、网络切换、代理失败、
系统回收和 AppGallery/Steam 政策预审。

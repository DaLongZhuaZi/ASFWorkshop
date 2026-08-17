# ASF工坊全局审计矩阵

本矩阵用于把设计文档中的规划、当前实现、源码入口、测试证据和发布门禁绑定起来。状态只表示当前仓库已经有的证据，不把 fake transport、静态检查或低风险页面回归等同于真实 Steam 服务验证。

功能推进的总体顺序与阶段划分见 `docs/feature_roadmap.md`；本矩阵只登记里程碑证据与门禁。

## 审计目标

1. 每个用户可见操作都能追溯到页面控件、entry 服务、核心契约和持久化/网络副作用。
2. 登录、注销、账号删除、代理切换和挂卡停止都能在成功、失败、中断、超时和重启后收敛到明确状态。
3. 设计文档规划的能力要么有完整实现和测试，要么明确标记为关闭、未实现或受发布门禁限制，不能以按钮或假状态冒充完成。
4. 密码、令牌、Cookie、CSRF、Guard data 和代理密码只经过安全存储边界，不能进入普通状态、事件、日志和测试摘要。
5. 核心 `steam_core` 保持可脱离 NGF、HarmonyOS 和 ArkUI 独立测试/发布。

## 里程碑矩阵

| 目标 | 规划/验收要求 | 主要源码与资源 | 当前状态 | 证据/剩余门禁 |
|---|---|---|---|---|
| M0 | API26 工具链、官方 API、网络/代理、后台限制和政策预审 | `build-profile.json5`、`ngf_framework/src/main/ets/network/`、`.local-rules/` | 部分完成 | API26 编译和低风险页面证据已记录；真实 WSS/TLS、HTTP Cookie、代理组合、后台稳定性和政策仍待授权门禁 |
| M1 | 可剥离 `steam_core`；NGF 提供 HTTP/Cookie/WebSocket/安全存储 | `OpenHarmonyASF/steam_core/`、`ngf_framework/src/main/ets/network/`、`ngf_framework/src/main/ets/security/` | 基本完成 | 依赖边界与 fake 测试已有；需继续防止 entry 业务逻辑倒灌核心 |
| M2 | 密码/二维码认证、Guard challenge、CM 会话、重连和错误收敛 | `OpenHarmonyASF/steam_core/src/main/ets/auth/`、`OpenHarmonyASF/steam_core/src/main/ets/cm/`、`entry/src/main/ets/steamServices/SteamArkStateService.ets`、`SteamArkAccountsPage.ets` | 修复已落地待真机验证 | 2026-08-16 静态复核：P0/P1 修复项（错误详情链、删除编排、凭据替换、QR 轮询、代理切换）已在工作树实现并有 `SteamArkStateService.test.ets` 51 用例覆盖；真实服务端仍未验证 |
| M3 | 掉卡事件、Simple/Complex 调度、多账号隔离、后台任务/通知 | `OpenHarmonyASF/steam_core/src/main/ets/farming/`、`entry/src/main/ets/steamServices/SteamArkFarmingService.ets`、`HarmonySteamFarmingRuntimeFactory.ets` | 部分完成 | fake runtime/事件已有；生产 runtime 现为默认启用（`HarmonySteamFarmingRuntimeFactory` 选项 `enabled` 默认 true，`EntryAbility.ets:145` 以默认参数装配，2026-08-16 修正本行早先"默认关闭"的过时表述），真实 WSS/TLS 与后台稳定性仍属 M0/M7 授权门禁；账号删除时 runtime 和持久化状态清理尚未闭环（见 P0） |
| M4 | 工作台、账号、库存、网络、设置、诊断页面和产品导航完整替换 | `entry/src/main/ets/pages/steamArk/`、`entry/src/main/resources/base/profile/main_pages.json`、三套 `string.json` | 部分完成 | 产品入口和页面导航已有 API26 低风险回归；需要逐页面审计按钮闭环、空/错/未登录状态、资源和不可用能力提示 |
| M5 | 库存只读、徽章同步、敏感操作门控和二次确认 | `SteamArkInventoryPage.ets`、`SteamArkSensitiveActionGate.ets`、`SteamArkSensitiveActionConfirmation.ets`、核心 inventory/badge | 只读部分完成 | 只读 inventory/badge fake 覆盖；交易、兑换、移动确认、库存写入和资产转移必须继续关闭并明确展示 |
| M6 | ASF 命令、手动挂卡和高级能力 | `OpenHarmonyASF/steam_core/src/main/ets/commands/SteamCommandRouter.ets`、`SteamArkWorkspacePage.ets` | 部分完成 | 已实现命令必须逐项验证执行链；未实现命令不能静默映射；`pause~`/`pause&`、交易/兑换等高级语义保持关闭 |
| M7 | 8/24 小时后台、网络切换、系统回收、脱敏、许可证/政策验收 | 本矩阵、`.local-rules/device-hdc.local.md` | 未完成 | 需要项目方授权设备、测试账号和网络环境；本轮不能宣称通过 |

## 本轮修复门禁

| 优先级 | 问题 | 必须落地的行为 | 验证方式 | 状态（2026-08-16 静态复核） |
|---|---|---|---|---|
| P0 | 认证失败信息丢失 | 保留错误码、服务端消息、错误类型和阶段；错误结果不得继续当作 pending challenge | 核心 poll fake、状态服务测试、页面状态映射静态检查 | 已落地：`recordAuthFailure` 全字段入会话快照；AccountsPage 结构化错误行；测试 `retainsCodeChallengeAfterTransientFailureForRetry` 等 |
| P0 | 账号删除/注销无统一入口 | 先停止挂卡和后台任务，再关闭库存/认证会话，清理内存缓存、挂卡状态、安全凭据，最后删除普通账号记录；任一清理失败保留记录并给出原因 | fake runtime、fake credential store、删除失败和重试测试 | 已落地：`removeAccountInternal` + `stopAccountActivity` 编排与回滚；测试 `restoresAccountWhenSecureRemovalIsRejected` 等 5 例 |
| P1 | 导入凭据采用增量写入 | ASF JSON/maFile 导入按完整替换语义删除输入中缺失的旧安全字段；认证结果仍保持增量合并 | credential store 调用断言和旧字段清除测试 | 已落地：`replaceImportedCredentials` 全 kind 替换（空值删除）；测试 `rollsBackPartialImportedCredentialWrites` 等 |
| P1 | QR 轮询只有单账号/错误状态混淆 | 只对当前有效 QR challenge 轮询；终态错误、过期、取消和成功立即停止 timer；页面展示结构化错误 | 页面静态检查、状态服务 fake 测试 | 已落地：`pollAuthenticationIfCurrent` + 页面 challenge 身份/代际守卫；测试 `skipsAStaleQrTimerWithoutPollingOrReplacingTheActiveChallenge` 等 |
| P1 | 代理切换会话残留 | 代理保存前可靠关闭库存/认证宿主会话，失败时不丢失旧状态；保存后重新创建服务使用新配置 | proxy fake、session close 顺序测试 | 已落地：`saveProxyInternal` 先停会话再保存，失败回滚/前滚恢复；测试 `doesNotMutateProxyWhenAuthenticationCleanupFails` 等 |
| P2 | 页面/设置/诊断功能链断裂 | 对每个按钮确认有服务方法、状态更新、错误/加载/空状态和本地化资源；未实现能力显示关闭原因 | 逐页源码矩阵和资源引用扫描 | 已登记：`docs/page_function_chain_registry.md` |

## 证据边界

- fake transport、golden protocol fixture、静态 ArkTS 检查只能证明本地契约和状态边界。
- API26 编译、HAP 安装和低风险导航只能证明构建与基础页面可达，不能证明 Steam 登录成功。
- 没有使用真实密码、refresh token、Cookie、代理密码或真实库存写操作。
- 真实 CM/WSS/TLS、HTTP Cookie、二维码确认、代理组合、系统回收和长时后台必须在独立授权环境重新验证。

## 交付检查

- [x] P0 认证错误和账号生命周期闭环完成并有测试（2026-08-16 静态复核：代码与测试用例在库；本轮未运行测试与构建）
- [x] P1 凭据替换、QR timer 和代理切换完成并有测试（同上）
- [x] P2 页面功能链逐项登记，未实现能力明确关闭（`docs/page_function_chain_registry.md`）
- [ ] 三套资源、路由、日志脱敏和 ArkTS 类型复核完成
- [x] 更新本矩阵与 `CHANGELOG.md`，记录实际命令/测试结果及未验证边界（本轮仅静态复核，测试与 Hvigor 构建未运行）

# 鸿蒙“应用快启（HyperStartup / HyperSnap）”可行性分析与实施计划

> 应用：ASF工坊 / ASF Workshop（bundleName: com.dlzz.harmonyasf）
> 基线：targetSdkVersion / compatibleSdkVersion = 26.0.0（HarmonyOS 7.0 / 鸿蒙内核）
> 日期：2026-08（探测基于本机 DevEco Studio 26 SDK 声明 + 华为官方公开资料 + 开发者确认）
> 状态：**结论可行，API 公开开放、无需申请**，可直接进入适配开发（API 26 真机已具备）

---

## 1. 结论摘要

| 层面 | 结论 | 说明 |
|------|------|------|
| API / SDK | ✅ 可用 | `@ohos.app.ability.hyperSnapManager` 自 **API 24** 声明（`@since 24`），公开 API（`isSystemApi=false`），**自由使用、无预约/申请门槛**；本机 API 26 SDK 白名单中 phone/tablet/2in1/tv/car/wearable 设备能力均于 **26.0.0** 起可用 |
| 系统 / 设备 | ✅ 可用 | 需鸿蒙内核设备（HarmonyOS 7.0 及以后；部分 HarmonyOS 6.1.x 机型已有 HyperSnap 支持）；**API 26 鸿蒙内核真机已具备**。注：华为开发者论坛流传的“预约”为直播课程预约，早已结束，与功能准入无关 |
| 应用侧 | ⚠️ 需适配 | 本项目当前**没有 AbilityStage**，无法接收快启恢复回调；快照恢复后网络长连接、同步、后台任务、悬浮窗等需要补偿逻辑（详见 §4） |

系统策略：满足兼容性要求的应用**默认启用**快启；系统最终按“应用兼容性 + 资源可用性 + 系统策略”决定是否抓取/使用快照。应用可在出问题时通过 API 一键关闭回退标准冷启动。

---

## 2. 功能与 API 事实（SDK 声明实测）

### 2.1 原理

“应用快启”（HyperStartup，又名 HyperSnap）是鸿蒙内核（HarmonyOS 7.0）首创的启动加速技术：系统在适当时机对应用进程创建**内存快照**，后续启动直接从快照恢复进程，绕过完整冷启动序列，显著缩短启动耗时（社区实测冷启动可优化至约 1.2 秒级）。

### 2.2 API 清单（本机 SDK 26 声明，`@ohos.app.ability.hyperSnapManager.d.ts`）

| API | 签名 | 说明 |
|-----|------|------|
| 启用/禁用 | `hyperSnapManager.setHyperSnapEnabled(enableFlag: boolean): void` | 上报应用与快启的兼容意愿；`true` 表示兼容（系统按策略择机应用）；`false` 禁用并回退标准冷启动。**设置跨重启持久化**。满足兼容性要求的应用**默认启用** |
| 重建快照 | `hyperSnapManager.requestRebuildHyperSnap(): void` | 请求销毁现有快照进程并在系统空闲期重建，用于解决快照兼容性问题（多数应用无需调用） |
| 错误码 | `BusinessError 16000150` | 向系统服务发送请求失败 |

约束：`@syscap SystemCapability.Ability.AbilityRuntime.Core`、`@stagemodelonly`（仅 Stage 模型）、`@since 24`、公开 API 无需系统权限申请。

### 2.3 AbilityStage 新增回调（`@ohos.app.ability.AbilityStage.d.ts`，均 `@since 24`）

| 回调 | 触发时机 |
|------|----------|
| `onLaunchFromHyperSnap(): void` | **仅快启启动流程**执行（从快照恢复进程时）；**正常冷启动不执行**。用于快启恢复补偿（重连、重调度、刷新） |
| `onAboutToCreateAbility(): void` | AbilityStage 即将创建第一个 Ability 前 |

### 2.4 设备支持（本机 `api-white-list.json` 实测）

`hyperSnapManager`：`isSystemApi=false`、`since=24`、phone/tablet/2in1/tv/car/wearable 全部 deviceType 的 `since=26.0.0` —— 与本项目 26.0.0 基线完全匹配。

### 2.5 官方资料

- 开发指南：应用快启（Ability Kit / 应用框架）
  https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hyperstartup-application
- API 参考：@ohos.app.ability.hyperSnapManager（应用快启管理）
  https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/js-apis-app-ability-hypersnapmanager
- 官方示例：HarmonyOS_Samples/HyperStartup（gitcode，含 HyperStartup Checker 排查插件 / CLI 动态采集快启失效事件）
  https://gitcode.com/HarmonyOS_Samples/HyperStartup
- 华为开发者论坛帖（“预约”实为直播课程预约，已结束；功能 API 开放自由使用，与本计划无关）
  https://developer.huawei.com/consumer/cn/forum/topic/0203219668112121266

---

## 3. 收益评估（为什么值得做）

ASF工坊是“多账号 + 多 Steam 长连接 + 大量缓存 + 后台挂卡”型应用，进程冷启动成本高：

- 冷启动需要完整走：NGF bootstrap → 服务工厂装配 → 设置存储 → 状态服务初始化 → 同步协调器启动 → 首页加载 → 账号会话/缓存重建。
- 快启直接从快照恢复进程内存：账号会话、缓存、页面栈、服务单例全部延续，仅需补偿外部失效资源（网络连接等）。
- 预期收益：**启动耗时大幅下降 + 启动后可用状态更快恢复**（挂卡/消息/库存立即可用）。

---

## 4. 应用侧适配分析与风险点（ASF工坊特有）

### 4.1 现状（代码勘察）

- **无 AbilityStage**：`entry/src/main/module.json5` 未配置 `srcEntry`（AbilityStage），全仓无 AbilityStage 文件 → **必须先新增**。
- 启动链路：`EntryAbility.onCreate` 做 NGF bootstrap、Steam 服务工厂装配、通知 want 捕获；`onWindowStageCreate` 初始化设置存储、状态服务、同步协调器并加载 `SteamArkHomePage`。
- 网络：HTTP 会话（`HarmonySteamWebSessionFactory` / `NGFHttpSession`）、CM 长连接（`SteamCmClient` WSS，经 `HarmonySteamCmWireTransport`）、社交运行时（`HarmonySteamSocialRuntime`）。
- 后台：`ngfSystem.submitTask`（保活锁 + 常驻通知）、`KEEP_BACKGROUND_RUNNING`（dataTransfer）、卡片（EntryFormAbility）、悬浮窗（`steamArkFloatingWindowCoordinator`）、多窗口（SteamArkPageWindowSupport）。
- 凭据：密码/token/shared_secret 等只进 NGF 安全凭据存储或调用内存（仓库红线）。
- ⚠️ 真实挂卡当前被门控：`CM_CONNECTION_GATE_REASON`（“Real Steam farming is disabled until … API26 connection verification are complete”，默认 `enabled=false`）→ 当前快启风险窗口可控，但**真挂卡开启后必须同步完成重连适配**。

### 4.2 快照恢复失效点（需补偿）

| # | 失效点 | 影响 | 补偿方案 |
|---|--------|------|----------|
| 1 | TCP/WSS/HTTP 连接全部失效（内核 socket 不随快照恢复） | 社交 CM 长连接、Web 会话、同步请求全部断链 | 恢复协调器统一重连：CM 重连 + 消息游标续传；WebSession 重建；立即触发一次增量同步 |
| 2 | 定时器/调度状态 | 同步协调器 5–15 分钟周期任务、后台任务续跑 | 恢复后重建调度器 + 立即静默同步一次 |
| 3 | 后台任务/保活锁/常驻通知 | 挂卡任务保活状态与系统后台任务管理器脱节 | 恢复后重新 `submitTask`（保活锁 + 常驻通知重建） |
| 4 | 悬浮窗/多窗口 | 窗口服务状态与快照进程不一致 | 恢复后由 `steamArkFloatingWindowCoordinator` 重建/重新 attach |
| 5 | ArkWeb（浏览器页） | WebView 渲染进程与快照进程关系需实测 | 恢复后校验会话并刷新页面（华为社区已有“ArkWeb 应用是否值得接入快启”讨论） |
| 6 | 通知跳转 want | 快启路径下 want 参数传递方式待官方文档确认 | 在恢复协调器中重放 pending 通知启动请求 |
| 7 | 半初始化快照 | 系统可能在应用任意时刻抓快照 | 启动链路幂等化；恢复后按“能力探测 → 增量补偿”而非“全量重初始化” |
| 8 | 凭据/安全 | 内存中 token 随快照延续；快照内存保护策略属华为侧 | 不新增明文落盘；失效 token 走既有“结构化终态认证失败才标记重登”机制；灰度期重点观察账号状态正确性 |
| 9 | 版本/设备差异 | HarmonyOS 6.1.x 部分机型与 7.0 行为差异 | 仅对鸿蒙内核设备启用；以系统默认策略为准 |

### 4.3 兼容性红线（不因快启而破坏）

- 多账号状态按稳定账号 ID 隔离；快启恢复不得让旧账号任务回写新账号（沿用现有代际机制）。
- 凭据不进入普通状态/缓存/日志/快照业务数据；快启补偿逻辑不得旁路 NGF 安全凭据存储。
- 页面订阅/监听按生命周期成对注册；恢复后 UI 刷新必须校验账号与代际。

---

## 5. 实施计划（分阶段）

### 阶段 0：前置确认（预计 3–5 天，可并行）

- [ ] P0-1 ~~预约~~ **无需任何预约/申请**：API 公开开放（此前流传的“预约”为直播课程预约，已结束）。直接确认官方指南口径即可。
- [x] P0-2 测试设备：**API 26 鸿蒙内核真机已具备**。
- [ ] P0-3 复核官方指南：通读《应用快启》开发指南最新版，确认快启时 Ability 生命周期、want 传递、快照时机与禁用条件（本计划基于 SDK 声明 + 公开资料，实施前须以官方指南为准）。
- [x] P0-4 SDK 基线（已就绪）：26.0.0，本机 DevEco Studio 26 SDK 白名单含 `hyperSnapManager`。

### 阶段 1：基础适配（开发里程碑 M1）

- [x] M1-1 新增 `entry/src/main/ets/entryability/AbilityStage.ets`，在 `module.json5` module 节点配置 `srcEntry`；实现：
  - `onLaunchFromHyperSnap()`：调用恢复协调器（日志打点 `SteamArkLog.startup`）。
  - `onAboutToCreateAbility()`：预留（日志打点）。
  - 2026-08 完成：`AbilityStage.ets` + `srcEntry` 已落地。
- [x] M1-2 新增 `entry/steamServices/SteamArkHyperSnapRecoveryCoordinator`（恢复编排）：
  - 能力探测（状态服务是否已初始化）→ 增量补偿而非全量重初始化；快照在初始化中途抓取时由 `notifyServicesReady()` 兜底重试。
  - 当前补偿动作：社交重连（`connectLoggedOnAccounts`）→ 静默同步一次（`requestSilentSync('hyper_snap_recovery')`）→ 卡片协调器幂等续跑（`widget start()`）。
  - 挂卡恢复 / 悬浮窗重建 / 通知 want 重放 / UI 刷新（代际校验）留待 M2。
  - **快启安全性审查（2026-08）**：`SteamArkSocialService.connectLoggedOnAccounts()` 自带 `runtimeConfigurationGeneration` 配置代际守卫 + `syncTasks` 并发去重 + 只连接 `LOGGED_ON` 账号，与同步协调器的连接不会重复；factory 未装配（半初始化快照）时抛异常被恢复协调器 `.catch` 安全记录。结论：M1-2 调用链在快启场景安全。
- [x] M1-3 设置页新增“应用快启”卡片（开关 + 重建快照）：
  - `SteamArkHyperSnapManager` 门面封装 `hyperSnapManager.setHyperSnapEnabled` / `requestRebuildHyperSnap`（失败分类 + 日志）；
  - 开关偏好持久化（`steam_ark_hyper_snap_enabled`，默认跟随系统声明兼容）；重建走 AlertDialog 二次确认；
  - 文案已进 `string.json`（base / en_US / zh_CN 共 13 键）。
- [x] M1-4 启动链路幂等化：`EntryAbility.initializeSteamServices` 成功后调用 `steamArkHyperSnapRecoveryCoordinator.notifyServicesReady()`，覆盖快启恢复时状态服务未初始化（半初始化快照）场景；快照恢复不重跑 onCreate 的路径由 AbilityStage 回调接管。
- [x] M1-5 构建验证：`assembleHap`（官方命令，完整文件权限，勿在 DSH 沙箱下运行 hvigor）。
  - 2026-08-15 19:13：**BUILD SUCCESSFUL 9.2s（exit 0）**，产出 `entry/build/default/outputs/default/entry-default-signed.hap`（14,990,189 B，签名完成）。
  - 产物验证：`resources.index` 含 13 条 `steam_settings_hyper_snap` 文案；包内 `module.json` 含 `"srcEntry": "./ets/entryability/AbilityStage.ets"`；`modules.abc` 字节级确认含 `SteamArkHyperSnapManager`、`SteamArkHyperSnapRecoveryCoordinator`、`SteamArkAbilityStage`、`onLaunchFromHyperSnap` 全部符号。
  - 历史：首次构建失败于签名校验阶段（`hap-sign-tool` JVM native OOM，内存压力），重试成功；残留 `hs_err_pid25236.log` 已清理。
- **M1 全部完成（2026-08-15）**。下一步：M2 服务层恢复适配（M2-1~M2-6，按预分析推进）→ M3 真机验证（API 26 鸿蒙内核真机已具备）。

### 阶段 2：服务层恢复适配（开发里程碑 M2）

- **M2 预分析（2026-08，代码勘察）**：
  - `SteamArkFloatingWindowCoordinator`（页面层单例）持有系统 `window.Window` 实例与 prepared 标志；快照恢复后系统窗口服务状态可能已销毁这些窗口 → 需要“窗口校验/重建”钩子。因架构边界（steamServices 不得依赖 pages），计划在 EntryAbility 或页面层注册恢复回调，由协调器调用。
  - `HarmonySteamFarmingRuntime` 持有 `SteamCmClient`（WSS 长连接）与调度器；真实挂卡当前被 gate 关闭（`CM_CONNECTION_GATE_REASON`），恢复适配可在 gate 开启前完成，风险窗口可控。
  - 通知 want 在快启路径的传递方式待真机验证（官方指南正文未获取），M2-6 的“want 重放”按 pending 请求重放实现。
- [ ] M2-1 社交运行时：CM WSS 断线重连（消息游标续传、会话状态恢复），复用/扩展既有重连机制。
- [ ] M2-2 同步协调器：恢复后立即触发一次静默同步并重建周期调度（库存/徽章/资料/库/社交新鲜度）。
- [ ] M2-3 挂卡服务：恢复后按既有运行时工厂重建（真实挂卡门控开启后生效）。
- [ ] M2-4 卡片/悬浮窗/多窗口：`steamArkWidgetStateCoordinator` 刷新、`steamArkFloatingWindowCoordinator` 重建。
- [ ] M2-5 ArkWeb：浏览器页会话校验与刷新策略（真机验证多进程兼容性）。
- [ ] M2-6 后台任务：恢复后重新 `submitTask`（保活锁 + 常驻通知）。

### 阶段 3：真机验证（验收里程碑 M3，API 26 真机已就绪）

- [ ] M3-1 冷启动 vs 快启耗时对比（hilog 时间戳 / 启动帧数据），目标：启动耗时显著下降。
- [ ] M3-2 快照命中率与快启失效事件采集（HyperStartup Checker 插件 / CLI 动态采集）。
- [ ] M3-3 功能回归矩阵：多账号切换、挂卡、消息收发与游标续传、市场/库存、浏览器登录态、通知跳转、悬浮窗、后台常驻、深色模式/语言切换。
- [ ] M3-4 安全回归：账号状态不被错误标记重登；凭据不落普通存储/日志。
- [ ] M3-5 稳定性：连续运行监控（faultlog/crashAnalytics），异常时通过设置开关一键禁用回退。

### 阶段 4：灰度发布（里程碑 M4）

- [ ] M4-1 随版本发布，默认启用（跟随系统默认），设置开关可回退。
- [ ] M4-2 灰度范围：先鸿蒙内核机型小范围（真机 + 邀请用户），再扩大。
- [ ] M4-3 监控：快启失效事件、启动耗时对比、崩溃率、账号异常率；出现问题时 `setHyperSnapEnabled(false)` 远程/本地关闭并 `requestRebuildHyperSnap()`。

---

## 6. 下一步

1. 确认无误后，从 **M1 基础适配**开始实施：新增 AbilityStage（`onLaunchFromHyperSnap`）+ `SteamArkHyperSnapRecoveryCoordinator` + 设置页快启开关。
2. 真机验证顺序建议：先“默认启用 + 观察冷启动/快启是否触发（hilog）”，再逐步接入补偿逻辑，最后做回归矩阵。
3. 若快照恢复出现账号/会话异常，优先用 `setHyperSnapEnabled(false)` 关闭并 `requestRebuildHyperSnap()` 排查，不要改凭据存储逻辑。

## 7. 参考链接

- 应用快启开发指南：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hyperstartup-application
- hyperSnapManager API：https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/js-apis-app-ability-hypersnapmanager
- 官方示例：https://gitcode.com/HarmonyOS_Samples/HyperStartup
- 社区适配经验：https://ost.51cto.com/posts/50805 、 https://www.ihonker.com/thread-35498-1-1.html

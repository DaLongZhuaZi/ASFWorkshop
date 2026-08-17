# ASF工坊功能推进路线图

本文件是功能落实的总体路线图：先补全已有功能的缺少项，再创建新的功能点；全程只读优先，
敏感写操作默认交接到已登录应用内浏览器（`SteamArkBrowserPage`）。状态随每阶段完成回写，
证据与门禁仍以 `harmony_asf_audit_matrix.md` 为准。

推进原则：

- 协议/解析代码先进 `OpenHarmonyASF/steam_core`（独立子模块仓库提交后回本仓库更新 gitlink）。
- 用户可见文案进入 `entry/src/main/resources/base/element/string.json` 与 `en_US/element/string.json`。
- 新页面复用 HDS 导航、`SteamArkTheme` 材质、`SteamArkPageWindowSupport` 窗口策略与 `SteamArkRoutes` 路由。
- 凭据只进 NGF 安全存储；未知数值不得显示为 `0`；加载/空/错误/未登录/权限不足状态必须可见。
- 构建验证默认静态复核；`hvigorw.bat assembleHap --no-daemon --stacktrace` 仅在明确要求或构建排障时运行。

## 阶段 0：基线对齐 — 已完成（2026-08-16）

- [x] 修正审计矩阵 M3 行漂移：生产 runtime 现为默认启用（此前误记"默认关闭"）。
- [x] 建立本路线图文档并从审计矩阵链接。

## 阶段 1：P0/P1 缺陷修复（已有功能·稳定性）

对应审计矩阵"本轮修复门禁"P0/P1 项，先于一切新能力。
2026-08-16 静态复核结论：1.1–1.5 均已在当前工作树实现并有 `SteamArkStateService.test.ets`
（51 用例）等测试覆盖，属文档滞后而非代码缺口；本轮未运行测试与构建。

| # | 任务 | 状态 |
|---|---|---|
| 1.1 | P0 认证错误详情链：StateService 保留错误码/服务端消息/类型/阶段，不折叠为 pending challenge；AccountsPage 结构化展示 | 已核实落地（`recordAuthFailure` + 页面错误行 + 测试） |
| 1.2 | P0 账号删除统一编排：停挂卡与后台任务→关库存/社交/认证会话→清缓存/挂卡状态/徽章报告/全部凭据 kind→删记录；失败保留记录并给原因 | 已核实落地（`removeAccountInternal`/`stopAccountActivity` + 5 例测试） |
| 1.3 | P1 导入凭据完整替换语义：ASF JSON/maFile 导入删除输入中缺失的旧安全字段 | 已核实落地（`replaceImportedCredentials` 全 kind 替换 + 测试） |
| 1.4 | P1 QR 轮询收敛：仅对当前有效 challenge 轮询，终态立即停 timer，页面结构化错误 | 已核实落地（`pollAuthenticationIfCurrent` + 页面守卫 + 测试） |
| 1.5 | P1 代理切换会话残留：保存前可靠关闭库存/认证宿主会话，保存后按新配置重建 | 已核实落地（`saveProxyInternal` 停会话→保存→回滚/前滚 + 测试） |
| 1.6 | P2 页面功能链登记：逐页"按钮→服务方法→状态→本地化"清单入 docs | 已完成（`docs/page_function_chain_registry.md`） |

## 阶段 2：已有功能能力补全（只读）

2026-08-16 实施完成（静态复核；测试用例入库但本轮未运行，Hvigor 构建未运行）。

| # | 任务 | 状态 |
|---|---|---|
| 2.1 | steam_core CM 原生好友通道：ClientFriendsList(767)/ClientPersonaState(766)/ClientPlayerNicknameList(5587) codec 与客户端处理；SocialRuntime presence 实时化，Web API 降为兜底 | 已完成：`SteamClientFriendsCodec.ets`（新）、`SteamCmClient` 事件、`SteamCmEvent` 载荷扩展、`HarmonySteamSocialRuntime` 缓存/请求/事件、`SteamArkSocialService.FRIEND_PRESENCE_CHANGED` 合并；3 个 codec 测试 |
| 2.2 | CARD_DROP 实时化：ItemAnnouncement 命中挂卡 app 即合成掉卡事件；富通知 | 已完成：`SteamFarmingBridge.applyAnnouncedCardDrops`、`CARD_DROPPED` 事件贯通、`HarmonySteamFarmingNotificationPublisher`（LONG_TEXT + open_farming 路由）、i18n 三套 |
| 2.3 | ASF 命令面板增强 | 已完成：`2fa` 生成 TOTP；多账号（逗号/all/`a..e`）；`pause~`/`pause& N`/`resume~`；`balance/stats/version/help/owns/fb/fq` 只读命令；`fbadd/fbrm/fqadd/fqrm` 本地列表命令；coordinator 暂停模式（PERMANENT/TEMPORARY/TIMED，掉卡/到时自动恢复）；3 个新测试 |
| 2.4 | 惰性配置激活 + 设置 UI | 已完成：SKIP_UNPLAYED_GAMES 规划过滤、GamesPlayedWhileIdle 完成后空闲挂机、SHUTDOWN_ON_FARMING_FINISHED 完成即停、SEND_ON_FARMING_FINISHED 本地通知；设置页新增优先队列/黑名单编辑器（`saveFarmingLists` 全替换语义）；`AUTO_UNPACK_BOOSTER_PACKS`/`ENABLE_RISKY_CARDS_DISCOVERY`/`SKIP_REFUNDABLE_GAMES` 维持关闭（写操作/数据源缺失） |
| 2.5 | 钱包余额 UI + WalletInfoUpdate codec | 已完成：`SteamClientWalletInfoCodec`（EMsg 5528）实时推送入会话快照；页面展示链路工作树已有（`applyWalletFacts` + 账号卡余额行）；1 个测试 |
| 2.6 | 市场浏览（只读）页面 | 已完成：`SteamArkMarketPriceService.browse`（search/render norender=1，限流/代理/回退复用）+ `SteamArkMarketBrowsePage`（搜索/过滤/分页/浏览器交接）+ 库存页入口 + 路由 `steam.ark.market.browse` |

## 阶段 3：新功能域（只读优先）

| # | 任务 | 状态 |
|---|---|---|
| 3.1 | 确认中心+令牌增强：steam_core confirmations 模块（identity_secret 时间签名、列表 GET 拉取解析）；ConfirmationService + 确认中心页面（交易/登录/市场确认、过期倒计时）；执行=浏览器交接 | 已完成（2026-08-16）：`SteamConfirmations.ets`（签名+HTML解析，不实现 accept/cancel）、`HarmonySteamConfirmationClient`、`SteamArkConfirmationService`、`SteamArkConfirmationCenterPage`（社交页入口；交易确认跳 tradeoffer 页）；签名防泄漏与解析 2 个测试。倒计时暂以 Steam 相对时间文本展示 |
| 3.2 | 商店+愿望单（只读）：CM unified StoreQuery.Query/SearchSuggestions（回退商店搜索 HTML）；档案 wishlist 页解析；商店搜索页 + 库页愿望单入口；购买=交接 | 已完成（2026-08-16，实现取简化路径）：公开 storesearch API 替代 CM unified（无鉴权依赖、行为等价，后续可切 StoreQuery）；`SteamWishlistParser.ets`（steam_core）解析档案 wishlist HTML（登录 cookie 会话，私有单可见）；`SteamArkStoreService` + `SteamArkStorePage`（搜索/愿望单双分区，库页入口）；解析器 1 个测试 |
| 3.3 | 好友动态+新闻聚合（只读）：CM unified UserNews.GetUserNews → 社交页动态分区；聚合已拥有游戏 ISteamNews → 新闻卡片 | 未开始（下一步：需要 UserNews codec，模型在 SteamMsgUserNews.cs） |
| 3.4 | 群组列表与群聊：CM unified ChatRoom 服务 + ClientClanState(822)；SocialService 群组会话；社交页群组分区；发送与单聊同风险级 | 未开始（依赖面最大：ChatRoom 全套模型 + SocialRuntime 扩展） |

### 明确不做（保持交接或关闭）

档案编辑、头像上传、购买/购物车、`addlicense`/`redeempoints`/`loot`/`transfer`/`unpack`、
广播观看（交接链接）、语音通话、远程下载（SteamKit 仅消息模型无会话编排，列远期实验轨道）、
创意工坊（交接）。原生移动确认/交易/市场写操作维持 M5 门禁关闭，待安全审批后单独规划。

## 阶段 4：收尾与门禁

- 每阶段完成后回写本文件、审计矩阵与 `CHANGELOG.md`，如实登记未验证边界。
- steam_core 新 codec 全部带 golden fixture 测试（照 `SteamCore.test.ets` 模式，固定假凭据/示例 SteamID）。
- 非官方端点（market search render、wishlist HTML、miniprofile）解析全部夹具化。
- M7 真机验证保持项目方授权门禁。

## 顺序与依赖

阶段 1（地基）→ 2.1+2.2（协议独立可并行）→ 2.3+2.4（coordinator 改动集中）→ 2.5+2.6 →
3.1 → 3.2+3.3（可并行）→ 3.4 → 阶段 4。

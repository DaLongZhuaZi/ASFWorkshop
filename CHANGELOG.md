# Changelog

## Unreleased

- 建立功能推进路线图 `docs/feature_roadmap.md`：先补全已有功能缺少项（P0/P1 修复、惰性配置激活），再创建新功能域（确认中心、商店/愿望单、好友动态、群组），写操作维持浏览器交接。
- 修正审计矩阵 M3 行漂移：生产挂卡 runtime 现为默认启用（`HarmonySteamFarmingRuntimeFactory` 选项默认 true），此前"默认关闭"表述过时；真实 WSS/TLS 与后台稳定性仍属授权门禁。
- 阶段 1 静态复核：审计矩阵 P0/P1 修复项（认证错误详情链、账号删除统一编排、导入凭据完整替换、QR 轮询收敛、代理切换会话清理）均已在工作树实现并有 `SteamArkStateService.test.ets` 等测试覆盖，矩阵与交付检查已回写；本轮未运行测试与 Hvigor 构建。
- 新增 `docs/page_function_chain_registry.md`：逐页登记"控件→服务方法→状态覆盖"功能链与浏览器交接边界（P2 门禁）。
- 阶段 2（已有功能补全，只读）：
  - CM 原生好友通道：`SteamClientFriendsCodec`（FriendsList/PersonaState/NicknameList）+ `SteamCmClient` 事件 + SocialRuntime 实时 presence（Web API 降为兜底）。
  - 掉卡实时化：ItemAnnouncement 命中挂卡游戏即合成 CARD_DROP；`CARD_DROPPED` 事件贯通至 NGF 富通知（LONG_TEXT，open_farming 跳转工作台）。
  - ASF 命令面板：`2fa` 生成 TOTP、多账号语法（逗号/all/范围）、`pause~`/`pause& <秒>`/`resume~`、`balance/stats/version/help/owns/fb/fq` 只读命令、`fbadd/fbrm/fqadd/fqrm` 本地列表命令。
  - 惰性配置激活：SKIP_UNPLAYED_GAMES 过滤、GamesPlayedWhileIdle 完成后空闲挂机、SHUTDOWN/SEND_ON_FARMING_FINISHED；设置页新增优先队列/黑名单编辑器（完整替换保存）。
  - 钱包：`SteamClientWalletInfoCodec`（EMsg 5528）实时余额推送接入会话快照（页面展示链路复用既有实现）。
  - 市场浏览（只读）：`SteamArkMarketBrowsePage` + `market/search/render?norender=1`，搜索/分页/AppID 过滤，买卖维持浏览器交接；库存页新增入口。
- 阶段 3（新功能域，只读，2026-08-16）：
  - 确认中心：steam_core `SteamConfirmations`（identity_secret 签名 + mobileconf 列表页解析，不实现接受/拒绝）+ `HarmonySteamConfirmationClient`（cookie 会话 GET）+ `SteamArkConfirmationService` + 确认中心页面（交易/市场/登录分类，交易跳 tradeoffer 页，其余仅展示）；社交页交易分区新增入口。
  - 商店与愿望单：公开 storesearch API 只读搜索 + steam_core `SteamWishlistParser`（档案 wishlist HTML）+ `SteamArkStoreService` + `SteamArkStorePage`（搜索/愿望单双分区，库页新增入口）；购买/加购/愿望单管理全部浏览器交接。
- 以上新增协议 codec 均附 golden fixture 测试（steam_core 测试文件），非官方端点解析带失败分类；本轮未运行测试与构建。

## 1.0.0 - 2026-08-13

- 产品统一更名为 ASF工坊 / ASF Workshop。
- 首次发布多账号认证、持久化会话、maFile 合并与 Steam Guard 令牌能力。
- 接入库存、卡牌、徽章、价格、挂卡、消息、好友、聊天、通知和网络诊断基础链路。
- 应用内浏览器承接 Steam 社区、商店、市场、交易与高风险写操作。
- 将平台无关 Steam/ASF 核心拆分为 OpenHarmonyASF Git 子模块。

# ASF工坊页面功能链登记表

对应审计矩阵 P2 门禁：对每个用户可见操作登记"页面控件 → entry 服务方法 → 状态覆盖"。
本表只登记源码可追溯的事实（2026-08-16 静态复核），不宣称真实 Steam 服务端验证通过。
行号以当前工作树为准，随页面演进更新。

状态覆盖缩写：L=加载中，E=空态，F=失败/错误，N=未登录/不可用，I=进行中/部分成功。

## 主入口

### SteamArkHomePage（@Entry 主页，8 Tab）
| 控件/区块 | 服务方法 | 状态 |
|---|---|---|
| 总览卡片（actions/accounts/assets/farming/social/security，可在设置显隐） | `stateService.getSnapshot/getSelectedAccount/getInventorySummary/getCachedDefaultInventoryPages`、`farmingService.getSnapshot/getBadgeSyncReport`、`socialService.getSnapshot` | L/E/F/N |
| 站点连通探针（store/community/api/help/checkout/cm，仅探测） | NGF 网络探测（复用 `HarmonySteamNetworkProbe` 链路） | L/F |
| Tab 切换 | Navigation 路由（`SteamArkRoutes`） | — |

### SteamArkWorkspacePage（工作台/挂卡 Tab）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 开始/停止/暂停/恢复挂卡按钮 | `farmingService.start/stop/pause/resume` | L/F/N（未登录/未就绪门控 `isFarmingReady`） |
| 集卡与徽章分组列表 | `farmingService.getBadgeSyncReport/getSnapshot`、`stateService.getCachedDefaultInventoryPages` | L/E/F |
| ASF 命令输入行 | `farmingService.executeCommand`（前缀取 `globalConfig.commandPrefix`） | F（错误码回显） |

## 账号

### SteamArkAccountsPage
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 密码登录（RSA+CM） | `stateService.signInWithPassword` | L/F（结构化错误行：类型/阶段/码/HTTP/messageType/header/frame 字节数/服务端消息） |
| 二维码登录/取消 | `stateService.beginQrSignIn`、`cancelAuthentication`；轮询走 `pollAuthenticationIfCurrent`（challenge 身份+代际守卫，终态停 timer） | L/F/N |
| 挑战提交（邮箱码/TOTP/移动确认） | `stateService.completeAuthChallenge`、`refreshAuthentication`、`pollAuthentication` | L/F |
| ASF JSON / maFile / ASF global 导入 | `stateService.importAsfBotJson/importMaFile/importAsfGlobalJson`（凭据完整替换+回滚） | L/F（迁移报告） |
| 删除账号（统一编排入口） | `stateService.removeAccount`（停挂卡→关库存/认证→清凭据/缓存→删记录；失败保留记录） | L/F（失败原因展示） |
| 注销/选择账号 | `stateService.signOut`、`selectAccount` | L/F |

### SteamArkTokenPage（令牌 Tab）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| TOTP 动态码 + 复制 | `stateService.getCredentials`（sharedSecret → `SteamTotp`） | N（无凭据提示）、F |

## 资产

### SteamArkInventoryPage（库存 Tab）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 同步/刷新 | `stateService.syncInventory`、`syncCoordinator.requestAccountSync` | L/F/N |
| 搜索、仅可交易/可市场过滤、集卡状态 | 本地过滤（`getCachedInventory/getCachedDefaultInventoryPages` 缓存） | E |
| 批量价格加载 | `new SteamArkMarketPriceService().loadBatch`（限流+缓存） | L/F |

### SteamArkInventoryDetailPage（物品详情）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 市场价格卡 + 价格历史图 | `SteamArkMarketPriceService.fetchOne/fetchPriceHistory`（实例化） | L/F（失败保留上次成功值，不显示 0） |
| 徽章掉落进度 | `farmingService.getBadgeSyncReport` | L/E |
| 关联游戏成就/时长 | `gameLibraryService.fetchGameDetail/getSnapshot` | L/E/F |
| 打开商店页/市场挂单页/社区物品页 | 浏览器交接（`SteamArkBrowserPage`，steamLoginSecure cookie 注入） | — |

### SteamArkBadgeDetailPage（徽章详情）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 徽章进度/合成跳转 | 进度来自 badge report；"合成徽章""游戏卡牌页"按钮 = 浏览器交接（badgeUrl/gamecards 页） | L/E |

### SteamArkLibraryPage / SteamArkGameDetailPage（库 Tab）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 游戏列表/排序/收藏 | `gameLibraryService.sync/getSnapshot/restore` | L/E/F/N |
| 游戏详情（成就/新闻/时长） | `gameLibraryService.fetchGameDetail`（信息/新闻/成就独立容错） | L/E/F |
| 打开商店页/新闻原文 | 浏览器交接 | — |

## 消息与社交

### SteamArkMessagesPage（消息 Tab）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 5 分类刷新/同步 | `stateService.syncMessages`、`syncCoordinator.requestAccountSync` | L/F/N |
| 标记已读/全部已读/隐藏 | `stateService.markMessageRead/markAllMessagesRead/hideMessage` | F |
| 交易通知"在浏览器打开" | 浏览器交接（tradeoffer 页，弹窗声明不在应用内执行） | — |

### SteamArkSocialPage（社交）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 好友列表/在线状态 | `socialService.connectAndSync(IfStale)/getSnapshot/restore` | L/E/F/N（CM 失败降级 Web API+缓存） |
| 聊天会话/发送/已读/回应/举报/忽略通知 | `socialService.sendMessage/loadConversation/acknowledge/updateReaction/reportMessage/dismissSessionNotice` | L/F |
| 表情面板 | `socialService.loadEmoticons/getEmoticons` | L/E |
| 好友档案页、网页版聊天 | 浏览器交接 | — |

### SteamArkChatFloatingPage / SteamArkFriendsFloatingPage（悬浮窗）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 悬浮聊天收发 | 同社交服务子集（subscribe/restore 成对注册） | L/F/N；降级=浏览器打开 `/chat/` |

## 系统

### SteamArkSettingsPage（设置 Tab）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 挂卡设置（enabled/maxGames/dropHours/priorityQueueOnly） | `stateService.saveFarmingSettings`（保存后提示需重启 runtime 生效；优先队列空时警告） | L/F |
| 区域设置（AUTO/CN/…/BR） | `stateService.saveRegion` | F |
| 握持感知权限、外观背景开关、HyperSnap 开关/重建 | NGF facade（`ngfUserAuthenticationFacade`/`ngfHoldingAwarenessFacade`/`SteamArkHyperSnapManager`） | F |
| 法律/开源清单 | Sheet 展示 | — |

### SteamArkNetworkPage（网络，设置内嵌）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 代理保存（SYSTEM/自定义，host/port/账号/密码） | `stateService.saveProxy`（先停会话后保存，失败回滚/前滚恢复） | L/F |
| 站点探针 | 网络探测 | L/F |

### SteamArkDiagnosticsPage（诊断）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 账号/资产统计 | `stateService/farmingService.getSnapshot` | N |
| 敏感操作门控审计（10 类写操作逐项 GRANTED/DENIED/UNSUPPORTED） | `SteamArkSensitiveActionGate/Audit/Confirmation` 演练 | 结果即展示 |

### SteamArkBrowserPage（内嵌浏览器）
| 控件 | 服务方法 | 状态 |
|---|---|---|
| 已登录页面加载（4 域白名单 + steamLoginSecure cookie 注入） | `stateService.getCredentials/getSelectedAccount` | F（无凭据/非白名单拒绝） |

## 明确关闭/交接的能力（不得以按钮冒充）

- 原生执行：交易接受/拒绝/取消、市场买卖、徽章合成、兑换码、库存写入、资产转移、移动确认执行——一律浏览器交接或"关闭+原因"展示。
- 命令面板：`trade`/`redeem` 被核心硬门禁拒绝（HIGH_RISK_DISABLED），页面显示拒绝原因。

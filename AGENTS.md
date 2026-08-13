# AGENTS

本文件是 ASF工坊仓库的统一代理规范。用户明确指令优先于本文件；子目录如有
更深层 `AGENTS.md`，则更深层规则优先。

## 1. 项目定位

- ASF工坊是 HarmonyOS NEXT API 26 应用，产品名为“ASF工坊”，英文名为
  “ASF Workshop”。
- `entry` 是产品 HAP；`ngf_framework` 是通用 HarmonyOS 运行框架；
  `OpenHarmonyASF/steam_core` 是独立 Git 子模块中的平台无关 Steam/ASF HAR。
- 保留 `com.dlzz.harmonyasf`、`SteamArk*` 类名、路由与 `steam_ark_*` 持久化键，
  这些是兼容标识，不是待批量重命名的用户文案。
- 用户可见内容统一使用 ASF工坊 / ASF Workshop，不冒充 Valve、Steam 客户端
  或 ArchiSteamFarm 官方产品。

## 2. 开始任务前

1. 使用 UTF-8 读取本文件与 `.rules/README.md`，并完整阅读命中的规则文件。
2. 检查 `git status`，保留用户已有改动，不使用 `reset --hard`、`checkout --`
   或 `clean` 清理工作树。
3. 核对 `build-profile.json5`、`AppScope/app.json5`、`entry/src/main/module.json5`
   和相关模块的 `oh-package.json5`。
4. 初始化核心子模块：`git submodule update --init --recursive`。
5. 涉及 HarmonyOS API、导入、编译、运行或弃用迁移时，先查最新官方文档和
   SDK 声明，再分析源码。

## 3. 架构边界

依赖方向固定为：

```text
OpenHarmonyASF/steam_core <- entry/steamAdapters <- ngf_framework / HarmonyOS APIs
                                           ^
                                           `- entry/steamServices / pages
```

- `steam_core` 不得导入 `ngf_framework`、`@kit.*`、ArkUI、HarmonyOS 上下文、
  文件、通知、安全存储或平台网络 API。
- Steam 协议、认证状态、导入、挂卡算法、静态编解码和只读解析优先进入
  OpenHarmonyASF 仓库；本仓库通过更新子模块提交消费。
- `entry/steamAdapters` 负责 HTTP、WebSocket、Cookie、加密、文件、通知、
  后台任务和平台生命周期适配。
- `entry/steamServices` 负责编排账户、会话、同步、缓存、社交与业务状态；页面
  不得直接重写协议或持久化秘密。
- `ngf_framework` 只沉淀可复用通用能力，禁止加入 Steam 专属业务规则。

## 4. 账户与安全

- 账户列表只保存已完成认证的正式账号；二维码临时挑战不得提升为账号。
- 多账号状态按稳定账号 ID 隔离，切换、注销、删除、应用销毁和启动恢复必须
  避免旧异步任务回写新账号。
- 只有结构化的终态认证失败才能把有效账号标记为需要重新登录；网络断开、
  页面销毁或服务关闭不能覆盖持久化有效会话。
- maFile 按 SteamID64 优先、账号名次级合并；不得复制同一账号。
- 密码、Cookie、access token、refresh token、验证码、二维码挑战、
  `shared_secret`、`identity_secret` 和代理密码只能进入 NGF 安全凭据存储或
  当前调用内存，不得进入普通状态、缓存、事件、日志、截图或测试夹具。
- 测试必须使用明显的固定假凭据和示例 SteamID。
- 库存写入、交易、市场买卖、兑换、资产转移和移动确认默认不实现原生执行；
  通过明确提示交接到已登录应用内浏览器。

## 5. ArkTS 与 UI

- 禁止 `any`、`unknown`、动态对象索引、普通对象扩展合并和危险空值访问。
- 使用明确 class/interface、显式泛型和稳定列表键；对象字面量必须有类型上下文。
- 日志使用 `SteamArkLog`（产品层）或 `logger`（NGF 框架层），禁止 `console`。
- 用户可见文案必须写入 `entry/src/main/resources/base/element/string.json` 与
  `en_US/element/string.json`，页面通过 `$r()` 引用。
- 页面优先复用 HDS 导航、NGF 材质、主题、握持、窗口、通知与任务门面。
- 所有按钮必须连接真实服务、导航或明确能力门控；不能只显示“成功”提示。
- 加载、空态、缓存、刷新、部分成功、权限不足和结构化失败都必须可见；未知
  数值不得显示为 `0`。
- 订阅和监听在页面生命周期内成对注册/取消；异步回调必须校验账号与生命周期
  代际后才能更新 UI。

## 6. 文件与编辑

- 文件读写显式使用 UTF-8，手工修改使用 `apply_patch`。
- 不提交 `local.properties`、`.local-rules/*.local.md`、构建产物、测试缓存、
  设备日志、签名证书、profile、私钥或密码。
- 资源和配置优先复用现有结构，不进行与任务无关的大规模格式化或重构。
- 如果目标文件已有用户修改，基于现状合并，不回退或覆盖无关内容。

## 7. 验证与提交

- 普通修复默认只做静态复核；只有用户明确要求或任务属于构建排障时才运行
  Hvigor。当前项目发布门禁使用 API 26：

```text
hvigorw.bat assembleHap --no-daemon --stacktrace
```

- 不自动安装、启动、连接真实 Steam 或执行设备测试，除非用户明确授权。
- 提交前执行依赖边界、敏感数据、资源 JSON、`git diff --check` 和待提交文件
  清单检查。
- 更新核心子模块时，先在 OpenHarmonyASF 独立提交并验证，再在本仓库提交新的
  gitlink；两个仓库的版本和变更记录分别维护。

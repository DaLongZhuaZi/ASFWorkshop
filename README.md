# ASF工坊

ASF工坊（ASF Workshop）是一款面向 HarmonyOS NEXT 的 Steam 多账号、资产、
挂卡与社交伴侣。应用以原生 ArkUI 呈现账号、令牌、库存、卡牌、徽章、挂卡、
消息、好友和网络诊断，并通过已登录的应用内浏览器承接交易、市场与社区等
高风险或尚无稳定原生接口的操作。

## 当前能力

- 二维码、密码、邮件码和 Steam Guard 登录，多账号持久化与启动恢复；
- maFile/ASF JSON 导入，同账号按 SteamID64 合并，敏感凭据进入安全存储；
- Steam Guard 动态令牌（需要用户拥有并导入对应 `shared_secret`）；
- 资料、头像、头像框、迷你资料背景、库存、卡牌、徽章与市场估值缓存；
- 按游戏分类的库存与卡牌、徽章页、只读社区详情和应用内浏览器；
- Simple/Complex 挂卡规划、手动游戏、掉卡事件、后台任务与通知链路；
- 好友列表、聊天缓存、链接和 Steam 表情解析、消息中心与应用内浮窗；
- Steam 商店、社区、登录、CDN、市场与 CM 网络诊断和历史记录；
- 可配置卡片式首页，未登录时提供网络状态和完整新手引导。

功能仍在持续核查中。真实 Steam 协议、后台连接和不同账号权限可能受网络、
Steam 服务端变化与 HarmonyOS 后台策略影响；页面会保留缓存并展示结构化失败
原因，不应把未知数据显示为 `0`。

## 仓库结构

```text
ASFWorkshop/
|- entry/                         # ASF工坊 HAP、页面、服务与 HarmonyOS 适配器
|- ngf_framework/                 # 通用 NGF HAR 运行框架
|- OpenHarmonyASF/                # 独立 Git 子模块
|  `- steam_core/                 # 平台无关 Steam/ASF ArkTS HAR
|- docs/                          # 实施计划、审计矩阵与协议记录
`- .rules/                        # 仓库代理开发规则
```

底层核心单独维护于
[OpenHarmonyASF](https://github.com/DaLongZhuaZi/OpenHarmonyASF)。克隆时请包含子模块：

```text
git clone --recurse-submodules https://github.com/DaLongZhuaZi/ASFWorkshop.git
```

已有克隆可执行：

```text
git submodule update --init --recursive
```

## 构建

使用 DevEco Studio API 26 SDK 打开仓库。首次克隆或更新子模块后，先在仓库根目录
安装全部本地 HAR 与开发依赖：

```text
ohpm install --all
```

随后执行命令行构建：

```text
hvigorw.bat assembleHap --no-daemon --stacktrace
```

公开仓库不包含签名证书、profile、私钥或本机密码。需要安装签名 HAP 时，请在
DevEco Studio 中创建你自己的调试/发布签名配置；未配置签名时仍可完成 ArkTS
编译和未签名 HAP 打包。

## 安全边界

- 不提交或分享密码、Cookie、Token、验证码、二维码挑战、maFile、
  `shared_secret` 或 `identity_secret`。
- 原生库存写入、交易执行、市场买卖、兑换、资产转移和移动确认默认关闭，
  相关操作交给已登录的 Steam 页面。
- 二维码或密码登录通常只产生会话，不会导出已有手机令牌的共享密钥。
- 本项目不是 Valve、Steam 或 ArchiSteamFarm 的官方产品。

详细边界见 [实施计划](docs/harmony_asf_implementation_plan.md)、
[审计矩阵](docs/harmony_asf_audit_matrix.md) 和 [安全政策](SECURITY.md)。

## 许可证

ASF工坊应用与内置 NGF 框架按 [MIT License](LICENSE) 发布；独立
OpenHarmonyASF 子模块按其仓库中的 Apache License 2.0 发布。

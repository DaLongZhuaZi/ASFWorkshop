# Security Policy

## 报告安全问题

请使用 GitHub Security Advisory 私下报告漏洞。不要在公开 Issue、截图或日志中
粘贴账号、密码、Cookie、access token、refresh token、验证码、二维码挑战、
maFile、`shared_secret` 或 `identity_secret`。

## 仓库安全约束

- 公开仓库不保存签名证书、profile、私钥和本机签名密码。
- Steam 秘密只允许进入 NGF 安全凭据存储，不进入普通状态、缓存或日志。
- 测试只能使用明显的固定假凭据与示例 SteamID。
- 交易、市场、兑换、库存转移和移动确认保持浏览器交接，不提供未经审查的
  原生写操作。
- 安全日志请先脱敏账号标识，并删除完整 URL 查询、Token、Cookie 和验证码。

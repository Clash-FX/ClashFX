### New Features

- **Subscription Status in Tray Menu** — Each remote config now shows its remaining traffic and expiry next to its name in the Configs submenu. Data comes from the standard `Subscription-Userinfo` HTTP header, with fallback parsing of subscription metadata embedded in proxy entries.

---
### 新功能

- **菜单栏订阅状态** — 每个远程配置在 Configs 子菜单里现在会显示剩余流量和到期时间。数据来自标准的 `Subscription-Userinfo` 响应头，没有头时会从订阅里嵌入的元信息条目兜底解析。

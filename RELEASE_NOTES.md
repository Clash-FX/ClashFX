### New Features

- **Subscription Status at Top of Tray Menu** — When the active config is a remote subscription with traffic / expiry data, a dedicated row at the very top of the menu shows the config name, remaining traffic, and expiry. The row hides itself when no subscription metadata is available, so the menu shape is unchanged for users without remote configs.
- **Subscription-Userinfo Parsing** — ClashFX now reads the standard `Subscription-Userinfo` HTTP response header (`upload`, `download`, `total`, `expire`) when refreshing remote configs, with fallback parsing of metadata embedded in subscription bodies (e.g. `剩余流量`, `套餐到期`).

---
### 新功能

- **菜单栏顶部订阅状态行** — 当前激活的远程订阅有流量/到期信息时，状态栏菜单顶部会显示一行专用条目：配置名 + 剩余流量 + 到期。没有订阅信息时整行自动隐藏，菜单形态不变。
- **Subscription-Userinfo 解析** — 刷新远程配置时会读取标准 `Subscription-Userinfo` 响应头（`upload`、`download`、`total`、`expire`），同时支持从订阅正文里的元信息条目（如 `剩余流量`、`套餐到期`）兜底解析。

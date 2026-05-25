### New Features

- **Lab Update Channel** — ClashFX now ships Stable and Lab updates from the same Sparkle feed. Stable remains the default, while `Settings → Debug → Update Channel → Lab (Experimental)` opts into 4-segment Lab builds that receive fixes earlier and show a small orange badge on the app icon.
- **Lab Feedback Toolkit** — The Help menu now includes Lab-oriented feedback and diagnostics actions so testers can open a pre-filled GitHub issue, copy redacted diagnostic info, open crash logs, or follow the manual rollback guide without anonymous telemetry.
- **Bypass Common Chinese Apps Toggle** — Enhanced Mode can inject the `Clash-FX/cn-apps-direct` `PROCESS-NAME` rule-provider so common Chinese apps such as WeChat, QQ, DingTalk, Feishu, and Bilibili go direct. The list updates automatically every 24 hours and defaults to off.
- **Hidden Proxy Groups Now Honored** — Proxy groups marked `hidden: true` in YAML are filtered from the status bar menu while still participating in speed tests and rule routing internally.
- **App Icon Refresh** — The bundled app icon set was refreshed for better visual consistency, and the default app icon padding now matches the built-in alternatives.

### Bug Fixes

- **Proxy Provider Subscription Status** — Local custom YAML files that use remote `proxy-providers` now show subscription usage in the menu by reading provider response metadata.
- **Localhost TUN Exclusions** — Enhanced Mode route exclusions now accept valid hostnames such as `localhost`, preventing local services from being forced through Fake-IP routing.
- **Sparkle DMG Metadata** — Release appcasts now publish DMG enclosures as `application/x-apple-diskimage`, matching the GitHub release asset type and Sparkle expectations.
- **Web View Cache Cleanup** — Web resource cleanup now clears only disk and memory cache, preserving local storage and IndexedDB data.
- **Menu Visibility Settings** — The menu display preferences now include the newly added Advanced TUN Settings and Bypass Common Chinese Apps actions.
- **Current Icon in Alerts** — About, alert, and notification fallback windows now use the currently selected app icon instead of a stale bundled icon.
- **Status Bar Restart Cleanup** — Restarting ClashFX from the menu no longer leaves a duplicate old status bar icon behind.
- **Launch Crash Under macOS 26 SDK Fixed** — `WKWebsiteDataStore` calls were moved back to the main queue for compatibility with stricter WebKit main-thread checks.

### Contributors

- Thanks to `ayangweb` for PRs #95, #96, and #98.

---

### 新功能

- **Lab 更新通道** — ClashFX 现在通过同一个 Sparkle feed 提供 Stable 与 Lab 两个更新通道。Stable 仍是默认通道；在 `设置 → 调试 → 更新通道 → Lab (实验性)` 中切换后，可收到 4 段版本号的 Lab 构建，并在应用图标右上角显示小橙点。
- **Lab 反馈工具** — Help 菜单新增面向 Lab 测试的反馈与诊断入口，可打开预填好的 GitHub issue、复制已脱敏的诊断信息、打开崩溃日志，或查看手动回退说明；不包含匿名遥测。
- **国内 App 直连开关** — 增强模式可注入 `Clash-FX/cn-apps-direct` 维护的 `PROCESS-NAME` rule-provider，让微信、QQ、钉钉、飞书、哔哩哔哩等常用国内 App 绕过代理直连。名单每 24 小时自动更新，开关默认关闭。
- **隐藏代理组现在生效** — YAML 中标记 `hidden: true` 的代理组会从菜单栏隐藏，对齐 mihomo 文档语义；隐藏的组在内部仍参与测速和规则路由。
- **应用图标刷新** — 内置应用图标组完成视觉一致性更新，默认应用图标留白也已与内置替换图标对齐。

### 修复

- **Proxy Provider 订阅状态** — 使用远程 `proxy-providers` 的本地自定义 YAML 现在也能在菜单中显示订阅流量信息。
- **Localhost TUN 排除** — 增强模式路由排除现在接受 `localhost` 等合法 hostname，避免本地服务被错误送入 Fake-IP 路由。
- **Sparkle DMG 元数据** — Release appcast 中的 DMG enclosure 现在使用 `application/x-apple-diskimage`，与 GitHub Release 资源类型和 Sparkle 预期一致。
- **WebView 缓存清理** — Web 资源清理现在只清除磁盘/内存缓存，保留 localStorage 与 IndexedDB 数据。
- **菜单显示设置补全** — 菜单显示偏好中已补上新增的 Advanced TUN Settings 与 Bypass Common Chinese Apps 动作开关。
- **弹窗使用当前图标** — About、Alert 与通知 fallback 弹窗现在使用当前选中的应用图标，不再显示过期的内置图标。
- **重启后状态栏不再残留旧图标** — 从菜单重启 ClashFX 不会再出现新老两个图标并存、老图标卡在 “Quitting…” 的问题。
- **macOS 26 SDK 下启动崩溃修复** — `WKWebsiteDataStore` 调用移回主线程，兼容 WebKit 更严格的主线程检查。

### 贡献者

- 感谢 `ayangweb` 提交 PR #95、#96 和 #98。

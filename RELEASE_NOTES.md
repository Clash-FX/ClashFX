### New Features

- **Profile Mixin for Runtime Configs** — The Config menu now includes a Profile Mixin editor backed by `~/.config/clashfx/.profile_mixin.yaml`. ClashFX applies that mixin at runtime for reloads and Enhanced Mode without rewriting subscription files, so custom proxy groups/rules can survive profile updates. (#129)
- **Turn Off All Proxy Modes** — A new tray menu action can disable both System Proxy and Enhanced Mode at once, with a tray-menu visibility setting so users can show or hide the shortcut. (#130)
- **Use Custom Enhanced Mode Config As-Is** — Advanced TUN Settings now has an opt-in switch that starts Enhanced Mode from the selected/runtime config without injecting ClashFX's generated TUN/DNS settings. Users who maintain their own complete `tun`, fake-IP DNS, `external-controller`, and `allow-lan` config can run it directly. (#118)

### Bug Fixes

- **Profile Mixin Has Its Own Tray Menu Visibility Toggle** — The new Profile Mixin menu item now has an independent show/hide switch under Configs instead of sharing the Config Editor visibility setting. (#129)
- **Menu Bar Speed Display Is More Compact and Stable** — The menu bar upload/download speed now uses a short formatter and fixed-width numeric rendering, reducing wasted menu bar space while preventing nearby icons from jumping as speeds change. (#122, #127)

### Contributors

- @qzxwj — Reported the menu bar status item occupying too much width (#127)
- @SJH21408 — Requested a one-click way to turn off proxy modes (#130)
- @ymeng98 — Requested persistent custom profile mixins (#129)
- @nmmsb666 — Requested custom Enhanced Mode configs to be used as-is (#118)

---

### 新功能

- **运行时 Profile Mixin** — Config 菜单现在提供 Profile Mixin 编辑入口，对应 `~/.config/clashfx/.profile_mixin.yaml`。ClashFX 会在 reload 和 Enhanced Mode 启动时运行时叠加 mixin，不改写订阅原文件，因此自定义策略组 / 规则可以在订阅更新后继续保留。(#129)
- **一键关闭所有代理模式** — 托盘菜单新增 Turn Off All Proxy Modes，可同时关闭 System Proxy 和 Enhanced Mode，并提供菜单显示开关，方便按需隐藏或展示。(#130)
- **Enhanced Mode 可直接使用自定义配置** — Advanced TUN Settings 新增默认关闭的 Use Custom Config as-is 开关；开启后，Enhanced Mode 会直接使用当前选择 / 运行时配置启动，不再注入 ClashFX 生成的 TUN/DNS 设置。适合已自行维护完整 `tun`、fake-IP DNS、`external-controller` 与 `allow-lan` 配置的用户。(#118)

### 修复

- **Profile Mixin 现在有独立的托盘菜单显示开关** — 新增的 Profile Mixin 菜单项现在会在 Configs 分组下提供独立显示 / 隐藏按钮，不再复用 Config Editor 的显示设置。(#129)
- **菜单栏速度显示更紧凑且稳定** — 上传 / 下载速度现在使用更短的菜单栏专用格式和固定宽度数字渲染，减少菜单栏占用，同时避免速度变化时带动旁边图标跳动。(#122, #127)

### 贡献者

- @qzxwj — 反馈菜单栏状态项占用宽度偏大的问题 (#127)
- @SJH21408 — 建议增加一键关闭代理模式 (#130)
- @ymeng98 — 建议支持持久的 Profile Mixin (#129)
- @nmmsb666 — 建议 Enhanced Mode 支持直接使用自定义配置 (#118)

<!-- Previous release notes -->

---

### Bug Fixes

- **Enhanced Mode Now Respects Your `tun.stack` Setting** — The generated `.enhanced_config.yaml` previously hardcoded `stack: mixed`, silently overriding a user-configured `tun.stack`. If your config set `system` (or `gvisor`), the dashboard showed `mixed` and reverting it never stuck. ClashFX now reads `tun.stack` from your source config, validates it against `system`/`gvisor`/`mixed` (case-insensitive), and only falls back to `mixed` when it is unset or invalid. Both the embedded and external core paths use the same resolved value so they never diverge. (#115)
- **Dashboard Theme & Column Settings Now Persist** — In Enhanced Mode the external controller was assigned a random port on every launch, so the Yacd dashboard origin (`127.0.0.1:PORT`) changed each time and its per-origin `localStorage` (theme, custom columns) appeared to reset. ClashFX now pins a stable controller port (`19090`) and only falls back to a random free port if that port is already taken, keeping the dashboard origin — and your saved preferences — stable across launches. (#115)
- **Enhanced Mode Startup Is More Resilient** — Enabling Enhanced Mode now automatically retries once when the external core fails to bind (e.g. a transient port race or a leftover `mihomo_core` process holding the controller port). Each retry regenerates the config with a fresh port instead of failing outright, so toggling Enhanced Mode on is far less likely to error out and require a manual retry.
- **Reopening ClashFX Reveals the Menu Bar Icon** — When ClashFX is already running and you launch it again from Finder, Spotlight, Launchpad, or the Dock, it now pops open the menu bar menu so you can locate the icon — helpful when the menu bar is crowded and the icon is hidden. Thanks @hangox for the suggestion. (#114)

### Contributors

- @hangox — Suggestion to reveal the menu bar item when reopening an already-running app (#114)

---

### 修复

- **增强模式现在会尊重你的 `tun.stack` 设置** — 之前生成的 `.enhanced_config.yaml` 硬编码 `stack: mixed`，会静默覆盖用户配置的 `tun.stack`。如果你配置了 `system`（或 `gvisor`），控制台却显示 `mixed`，改回去也不生效。现在 ClashFX 会从源配置读取 `tun.stack`，按 `system`/`gvisor`/`mixed`（不区分大小写）校验，仅在未设置或非法时才回退到 `mixed`。内置核心与外部核心两条路径使用同一个解析结果，不会再不一致。(#115)
- **控制台主题与列设置现在能持久保存** — 增强模式下外部控制器每次启动都分配随机端口，导致 Yacd 控制台的 origin（`127.0.0.1:端口`）每次都变，其按 origin 隔离的 `localStorage`（主题、自定义列）看起来被重置。现在 ClashFX 固定使用稳定的控制器端口（`19090`），仅当该端口被占用时才回退到随机空闲端口，从而让控制台 origin —— 以及你保存的偏好 —— 在多次启动间保持稳定。(#115)
- **增强模式启动更稳健** — 开启增强模式时，若外部核心绑定失败（例如瞬时端口竞争，或残留的 `mihomo_core` 进程仍占用控制器端口），现在会自动重试一次。每次重试都会用新端口重新生成配置，而不是直接报错，因此开启增强模式更不容易失败、无需手动重试。
- **重新打开 ClashFX 时会弹出菜单栏图标** — 当 ClashFX 已在运行、你又从访达 / Spotlight / 启动台 / Dock 再次打开它时，现在会自动弹出菜单栏菜单，方便你定位图标 —— 在菜单栏拥挤、图标被隐藏时尤其有用。感谢 @hangox 的建议。(#114)

### 贡献者

- @hangox — 建议在重复打开已运行的 app 时显示菜单栏项 (#114)

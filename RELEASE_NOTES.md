### Bug Fixes

- **Web Dashboard No Longer Shows a White Top Bar in Full Screen** — The Dashboard menu window now uses a standard content layout instead of a transparent full-size titlebar with an empty macOS toolbar, and removes the old 28px dashboard padding patch. This keeps the Web dashboard navigation visible when the window enters full screen. (#129)

### Contributors

- @a51095 — Continued verification of the Web dashboard full-screen header issue. (#129)

---

### 修复

- **Web 控制台全屏时不再出现白色顶栏遮挡导航** — “控制台”菜单窗口现在改用标准内容布局，不再使用透明全尺寸标题栏和空 macOS toolbar，并移除了旧的 28px 顶部避让 CSS；进入全屏后 Web dashboard 顶部导航会正常显示在内容区内。 (#129)

### 贡献者

- @a51095 — 持续验证 Web 控制台全屏顶部遮挡问题。 (#129)

<!-- Previous release notes -->

---

### Bug Fixes

- **Dashboard Header No Longer Gets Covered in Full Screen** — The native dashboard now uses an in-window header instead of a macOS toolbar, so the Recent/Active Connections switcher and search field stay visible when the dashboard enters full screen. (#129)
- **Profile Mixin iCloud Sync Uses a Visible File and Reloads Cleanly** — When iCloud config storage is enabled, ClashFX now migrates the local or legacy hidden mixin into a visible `Profile Mixin.yaml` file in iCloud Documents, filters it out of normal config lists, refreshes the config menu, watches the iCloud-selected config, and reloads it without requiring an app restart. (#129)
- **Subscription Rules Editor Keeps Profile Buckets Out of Normal Configs** — The visual Rules editor now keeps the rule bucket selector disabled on normal subscription configs and only exposes `profile.prepend-rules` / `profile.append-rules` when editing Profile Mixin, avoiding accidental edits to Profile-only rule buckets from the config editor. (#129)

### Contributors

- @a51095 — Continued verification for Profile Mixin, iCloud sync, and dashboard full-screen regressions. (#129)

---

### 修复

- **控制台全屏时顶部不再被遮挡** — 原生控制台现在使用窗口内容内的顶部栏，不再依赖 macOS toolbar；进入全屏后，“最近连接 / 活动连接”切换和搜索框会保持可见。 (#129)
- **Profile Mixin 的 iCloud 同步改为可见文件并会正确重载** — 开启 iCloud 配置存储后，ClashFX 会把本地或旧版隐藏 mixin 迁移为 iCloud Documents 中可见的 `Profile Mixin.yaml`，同时从普通配置列表中过滤该文件，刷新配置菜单，监听 iCloud 当前配置并自动重载，无需重启 App。 (#129)
- **订阅规则编辑器不再暴露 Profile 专属规则项** — 普通订阅配置的可视化 Rules 编辑器现在会禁用规则项下拉，只保留 `rules`；只有编辑 Profile Mixin 时才显示 `profile.prepend-rules` / `profile.append-rules`，避免从配置编辑器误改 Profile 专属规则桶。 (#129)

### 贡献者

- @a51095 — 持续验证 Profile Mixin、iCloud 同步和控制台全屏遮挡问题。 (#129)

<!-- Previous release notes -->

---

### Bug Fixes

- **Profile Mixin Visual Editor Opens the Right Rule Bucket** — When a Profile Mixin only contains `profile.prepend-rules` or `profile.append-rules`, switching from source view to visual mode now automatically selects the non-empty Profile rule bucket instead of showing an empty top-level `rules` table. (#129)
- **Profile Mixin and Config Editor Can Open Side by Side** — Opening Config Editor while the Profile Mixin editor is already visible now opens or focuses the selected profile editor instead of silently reusing the existing Profile Mixin window. The config picker also includes a Profile Mixin entry for direct navigation. (#129)
- **Profile Mixin Follows iCloud Config Storage** — When iCloud config storage is enabled, the Profile Mixin file now resolves to the iCloud Documents container as well, so custom mixin rules stay with the rest of the synced configuration set. (#129)
- **ClashFX Networking Is Direct in Enhanced Mode** — Enhanced Mode now prepends a built-in `PROCESS-NAME,ClashFX Networking,DIRECT` rule before subscription rules so the networking helper is not accidentally routed by a provider rule. (#129)
- **iCloud Settings Toggle Reflects the User Choice** — The iCloud checkbox now stays responsive to the saved user preference even when iCloud availability temporarily prevents syncing, instead of immediately snapping back based on the effective runtime state.

---

### 修复

- **Profile Mixin 可视化编辑器会自动打开正确规则项** — 当 Profile Mixin 只包含 `profile.prepend-rules` 或 `profile.append-rules` 时，从源码切换到可视化模式会自动选中有内容的 Profile 规则项，不再显示空的顶层 `rules` 表格。 (#129)
- **Profile Mixin 与配置编辑器可以同时打开** — 已打开 Profile Mixin 编辑器时，再点配置编辑器会打开或聚焦当前配置编辑器，不再静默复用已有的 Profile Mixin 窗口。左上角配置下拉也新增 Profile Mixin 入口，便于直接切换。 (#129)
- **Profile Mixin 跟随 iCloud 配置存储** — 开启 iCloud 存储配置后，Profile Mixin 文件也会解析到 iCloud Documents 容器，自定义 mixin 规则会和其他配置文件一起同步。 (#129)
- **Enhanced Mode 会直连 ClashFX Networking** — Enhanced Mode 现在会在订阅规则前插入内置 `PROCESS-NAME,ClashFX Networking,DIRECT`，避免网络子进程被订阅规则错误代理。 (#129)
- **iCloud 设置开关会反映用户选择** — iCloud 勾选框现在绑定保存的用户偏好；即使 iCloud 暂时不可用导致运行时未启用，也不会在点击后立刻按有效状态弹回。

<!-- Previous release notes -->

---

### Bug Fixes

- **Profile Rule Buckets Show in the Visual Editor** — The Rules visual editor now lets you switch between top-level `rules`, `profile.prepend-rules`, and `profile.append-rules`, so Profile Mixin rule directives added in source view are visible and editable without falling back to raw YAML. ClashFX also expands config-embedded `profile.prepend-rules` into runtime rules before subscription rules, and warns when PROCESS rules need Enhanced Mode to match. (#129)

---

### 修复

- **可视化编辑器现在会显示 Profile 规则项** — 规则可视化编辑器新增 `rules`、`profile.prepend-rules`、`profile.append-rules` 切换项；通过源码添加的 Profile Mixin 规则指令现在可以直接查看和编辑，不必退回纯 YAML。ClashFX 也会把配置内的 `profile.prepend-rules` 在运行时展开到订阅规则前面，并在 PROCESS 规则需要 Enhanced Mode 才能命中时写入提示日志。 (#129)

<!-- Previous release notes -->

---

### Bug Fixes

- **Profile Mixin Rule Directives Now Work** — ClashFX now understands `profile.prepend-rules` and `profile.append-rules` in Profile Mixin files, translating them into real runtime `rules` before loading mihomo. Prepended rules are inserted before the existing rule list so DIRECT/process exclusions are not hidden behind `MATCH`.

---

### 修复

- **Profile Mixin 规则指令现在会生效** — ClashFX 现在会识别 Profile Mixin 中的 `profile.prepend-rules` 和 `profile.append-rules`，并在加载 mihomo 前转换为真正的运行时 `rules`。其中 prepend 规则会插到现有规则列表前面，避免 DIRECT / 进程排除规则被 `MATCH` 吃掉。

<!-- Previous release notes -->

---

### Bug Fixes

- **Proxy Recovers After Wake From Sleep** — After macOS wakes from lid-close sleep, ClashFX now delays recovery until the network interface is ready, checks whether the mihomo API is still healthy, and restarts the active proxy mode when needed. This should avoid the state where proxy traffic stays broken until the app is manually restarted. (#142)
- **Menu Bar Speed Font Restored** — The menu bar upload/download speed text now uses the original ClashFX menu font again, preserving the latest macOS 26 custom drawing optimization while reverting the visual font regression.

### Contributors

- @ayangweb — Reported proxy failure after lid-close sleep/wake (#142)

---

### 修复

- **睡眠唤醒后代理会自动恢复** — macOS 合盖睡眠后唤醒时，ClashFX 现在会等待网络接口就绪，再检查 mihomo API 是否仍健康；如果 core 已无响应，会按当前代理模式走现有恢复路径重启，避免必须手动重启 App 才能恢复代理的问题。 (#142)
- **菜单栏网速字体已恢复** — 菜单栏上传 / 下载速度文字重新使用 ClashFX 原有菜单字体，同时保留 macOS 26 的自绘优化，回退字体观感回归。

### 贡献者

- @ayangweb — 反馈合盖睡眠唤醒后代理失效的问题 (#142)

<!-- Previous release notes -->

---

### Bug Fixes

- **Custom Enhanced Mode Now Applies macOS DNS Override** — When `Use Custom Config as-is` is enabled, ClashFX still keeps the selected config file untouched, but Enhanced Mode now runs the same TUN verification and temporary macOS DNS override as the generated-config path. This prevents system DNS from staying on the router DNS while the custom TUN core is running. (#139)

### Contributors

- @mumaxiaozi — Reported that Enhanced Mode with `Use Custom Config as-is` left macOS DNS on the router DNS (#139)

---

### 修复

- **自定义 Enhanced Mode 现在也会接管 macOS DNS** — 开启 `Use Custom Config as-is` 时，ClashFX 仍会保持所选配置文件原样，但 Enhanced Mode 会执行与生成配置路径一致的 TUN 校验和临时 macOS DNS 接管，避免自定义 TUN core 已运行时系统 DNS 仍停留在路由器 DNS。 (#139)

### 贡献者

- @mumaxiaozi — 反馈开启 `Use Custom Config as-is` 的 Enhanced Mode 后 macOS DNS 仍停留在路由器 DNS (#139)

<!-- Previous release notes -->

---

### Bug Fixes

- **Menu Bar Speed Indicator Is Compact Again** — The menu bar upload/download speed display now uses compact units such as `999KB/s`, a lighter fixed-width font, and competitor-aligned 4pt icon-to-text spacing, reducing the worst-case status item width by about 9pt while keeping the stable-width rendering path. (#137)

### Contributors

- @mumaxiaozi — Reported the 1.1.4.6 menu bar icon and speed display taking more space than 1.1.4.4 (#137)

---

### 修复

- **菜单栏网速显示重新变紧凑** — 菜单栏上传 / 下载速度现在恢复为 `999KB/s` 这类紧凑单位，改用更细的等宽字体，并将图标与文字间距收紧到接近竞品的 4pt；在保持稳定宽度渲染的同时，最宽状态项约减少 9pt。(#137)

### 贡献者

- @mumaxiaozi — 反馈 1.1.4.6 菜单栏图标与网速显示相比 1.1.4.4 占用更宽的问题 (#137)

<!-- Previous release notes -->

---

### Bug Fixes

- **Menu Bar Speed Text Looks More Balanced** — The menu bar upload/download speed now uses the macOS monospaced-digit menu font, uppercase units, and a space between the number and unit, so labels like `186 B/S` and `1.2 KB/S` no longer look cramped or visually mismatched.
- **Turn Off All Proxy Modes Is Localized** — The tray-menu shortcut for disabling System Proxy and Enhanced Mode now has localized text and tooltip strings across English, Simplified Chinese, Traditional Chinese, Japanese, and Russian instead of falling back to English in non-English menus.

---

### 修复

- **菜单栏网速文字更协调** — 菜单栏上传 / 下载速度现在使用 macOS 等宽数字菜单字体、全大写单位，并在数字与单位之间加入空格，例如 `186 B/S`、`1.2 KB/S`，避免大小写割裂和数字单位粘连的问题。
- **“关闭所有代理模式”已补齐多语言** — 用于同时关闭 System Proxy 和 Enhanced Mode 的托盘菜单快捷项，现在在英文、简体中文、繁体中文、日文、俄文下都有对应菜单文字和 tooltip，不再在非英文界面回退显示英文。

<!-- Previous release notes -->

---

### Bug Fixes

- **Enhanced Mode Disable Restores Manual Proxy Selection** — Turning Enhanced Mode off now reapplies ClashFX's remembered proxy-group selections after the built-in core reloads, so selector groups no longer fall back to the config default such as Auto Select. (#134)

### Contributors

- @ljssafe — Reported proxy selection falling back to Auto Select after disabling Enhanced Mode (#134)

---

### 修复

- **关闭 Enhanced Mode 后会恢复手动选择的节点** — 关闭 Enhanced Mode 并重载回内置 core 后，ClashFX 现在会重新应用已记住的策略组节点选择，因此不会再回到配置默认项（例如“自动选择”）。(#134)

### 贡献者

- @ljssafe — 反馈关闭 Enhanced Mode 后节点回到自动选择的问题 (#134)

<!-- Previous release notes -->

---

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

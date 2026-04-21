## ClashFX 1.0.13

### Bug Fixes / 问题修复

- **Fixed double-encoded share-link subscriptions** — Some providers (e.g. sub.cucloud.top) return a base64 payload where each individual proxy URI is itself base64-encoded a second time, so lines look like `c3M6Ly9...` instead of `ss://...`. ClashFX now detects and decodes these correctly, generates a valid Clash config with `Auto` (url-test) and `Proxy` (select) groups, and no longer shows "cannot unmarshal !!str" errors.

- **Fixed domestic site access in Rules mode** — When generating a config from share-link subscriptions, the rules section previously only contained `MATCH,Proxy`, routing all traffic through the proxy including Chinese domestic sites (Baidu, etc.). `GEOIP,private,DIRECT` and `GEOIP,CN,DIRECT` rules are now added before `MATCH,Proxy` so local and domestic traffic bypasses the proxy.

- **Fixed blank speed display in menu bar** — The upload/download speed text in the status bar was invisible on first launch. The initial draw call occurred before Auto Layout resolved the view bounds (height = 0), and subsequent updates were silently dropped if the speed values hadn't changed. Fixed by overriding `layout()` to re-trigger `needsDisplay` once bounds are non-zero.

- **Fixed settings tab gray block on macOS 15 Sequoia** — `NSTabViewController` with `.toolbar` style renders as a large gray block on macOS 15 due to toolbar layout changes. The settings window now uses `.segmentedControlOnTop` style on macOS 15+ for a clean appearance, while retaining `.toolbar` with proper SF Symbol icons on macOS 11–14.

---

### 改进

- **修复双层 base64 订阅解析** — 部分机场（如 sub.cucloud.top）返回的 base64 内容中每行代理链接本身也经过了一次 base64 编码，导致每行看起来像 `c3M6Ly9...` 而非 `ss://...`。ClashFX 现在能正确识别并解码，自动生成包含 `Auto`（url-test）和 `Proxy`（select）分组的合法 Clash 配置，不再出现 "cannot unmarshal !!str" 错误。

- **修复 Rules 模式下国内网站无法访问** — 由订阅链接生成的配置规则原先只有 `MATCH,Proxy`，导致所有流量（包括百度等国内网站）都走代理。现在在 `MATCH,Proxy` 之前添加了 `GEOIP,private,DIRECT` 和 `GEOIP,CN,DIRECT` 规则，本地及国内 IP 直连。

- **修复菜单栏网速显示空白** — 状态栏的上传/下载速度文字在首次启动时不可见。原因是初始绘制调用在 Auto Layout 确定视图尺寸（高度为 0）之前就执行了，后续流量更新如果速度值未变化则被静默丢弃。通过覆写 `layout()` 在布局完成后触发重绘修复。

- **修复 macOS 15 Sequoia 设置窗口标签大灰块** — macOS 15 对 `NSTabViewController` 的 `.toolbar` 样式布局做了大幅调整，导致设置标签区域显示为大灰块。macOS 15+ 现在改用 `.segmentedControlOnTop` 样式呈现简洁的分段控件，macOS 11–14 仍使用带 SF Symbol 图标的 `.toolbar` 样式。

---

[![Download ClashFX](https://a.fsdn.com/con/app/sf-download-button)](https://sourceforge.net/projects/clashfx/files/1.0.13/)

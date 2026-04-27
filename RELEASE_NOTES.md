## ClashFX 1.0.17

### New Features / 新功能

- **Upgraded generated compatibility configs to geosite template** — Share-link subscriptions (base64 SS/VMess) now generate configs with `geodata-mode: true`, geosite/geoip CN direct routing, DNS fallback (domestic 223.5.5.5 / foreign 1.1.1.1), and comprehensive private-network IP-CIDR rules. Existing generated configs auto-upgrade on first launch.

### Bug Fixes / 问题修复

- **Restored parent group Switch in tray menu settings** — Parent group rows (e.g. "Proxy Actions", "General Settings") now show a Switch again. Toggling it off collapses all child items with a smooth animation; toggling it back on expands them. Fixes #41.
- **Hide parent menu item when all children are off** — If every sub-item in a tray menu group (Configs, Help) is toggled off, the parent menu item now hides automatically instead of showing an empty shell. Fixes #44.
- **Fixed Catalina menu bar speed rendering** — Added `wantsLayer` backing for the custom speed text view, ensuring the upload/download speed display renders correctly on macOS 10.15 Catalina.

### Improvements / 改进

- **Upgraded mihomo core from v1.19.21 to v1.19.24** — Three patch releases of bug fixes and protocol improvements.
- **Updated subscription User-Agent to mihomo/1.19.24** — Matches the actual core version to avoid provider misclassification.

---

### 新功能

- **生成的兼容配置升级为 geosite 模板** — 分享链接订阅（base64 SS/VMess）现在生成的配置包含 `geodata-mode: true`、geosite/geoip 国内直连规则、DNS 分流回退（国内 223.5.5.5 / 国外 1.1.1.1）以及完整的私有网络 IP-CIDR 规则。已有的生成配置在首次启动时会自动升级。

### 问题修复

- **恢复托盘菜单设置中父级分组的 Switch** — 父级分组行（如「代理控制」、「通用设置」）重新带有 Switch 开关。关闭时子项以动画折叠隐藏，开启时恢复展开。修复 #41。
- **所有子项关闭时自动隐藏父级菜单项** — 如果托盘菜单中某个分组（配置管理、帮助）的所有子项都被关闭，父级菜单项也会自动隐藏，不再显示空壳。修复 #44。
- **修复 Catalina 菜单栏速度显示渲染** — 为自定义速度文本视图添加 `wantsLayer` 支持，确保上传/下载速度在 macOS 10.15 Catalina 上正确渲染。

### 改进

- **mihomo 内核从 v1.19.21 升级至 v1.19.24** — 包含三个补丁版本的 bug 修复和协议改进。
- **订阅请求 User-Agent 更新为 mihomo/1.19.24** — 与实际内核版本一致，避免部分机场误判客户端类型。

---

### Contributors / 贡献者

- **@ayangweb** — reported issues #41 and #44

[![Download ClashFX](https://a.fsdn.com/con/app/sf-download-button)](https://sourceforge.net/projects/clashfx/files/1.0.17/)

## ClashFX 1.1.11.13 (Lab)

### Improvements

- **Show the Selected Proxy Group by Default** — If Netflix selects Proxies and Proxies selects Japan 27, the outer menu now shows Proxies, matching the submenu checkmark. Directly selected nodes still show their own names.
- **Choose Final-Node Display in Settings** — Enable “Show Final Node in Proxy Menu” in General settings to display the resolved final node. The preference is saved and existing menu rows update immediately.
- **Keep Route Details Available** — Route tooltips and accessibility help retain the full selection path. Automatic-selection and manual-priority labels remain visible; benchmark evidence continues to follow the core-resolved route.

Validation: 45 focused AppKit/menu tests passed and the app built locally. Source CI runs the isolated regression suite, universal package compatibility checks and existing Helper/core/TUN gates before tagging. Local checks used Xcode 27 with a command-line macOS 12 deployment override; the source still targets macOS 10.14. Runtime testing on macOS 10.14 is outside demonstrated coverage.

---

### 改进

- **默认显示实际选择的策略组** — 例如 Netflix 选择 Proxies、Proxies 再选择 Japan 27 时，外层菜单显示 Proxies，与子菜单勾选一致；直接选择节点时仍显示节点名。
- **在设置中选择显示最终节点** — 通用设置新增“代理菜单显示最终节点”，默认关闭。偏好会保存，切换后现有菜单行即时更新。
- **保留完整路径说明** — 悬停与辅助功能说明仍展示完整选择路径；自动选择／手动优先标记保留，测速证据仍跟随核心解析出的实际路径。

验证：45 项 AppKit／菜单专项测试及本地 App 构建通过。打标签前，源码 CI 运行完整隔离回归、通用包兼容性检查及既有 Helper／核心／TUN 验收。本地使用 Xcode 27，并仅在命令行将部署目标覆盖为 macOS 12；源项目仍支持 macOS 10.14。未覆盖 macOS 10.14 实机运行。

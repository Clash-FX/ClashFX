## ClashFX 1.1.11.15 (Lab)

### 中文

- 修复首次启动重载订阅失败后的处理：有限重试，保留脱敏后的核心错误，并明确区分回滚到启动初始配置还是完整订阅。
- 统一增强模式退出和失败重试：释放自身旧监听后按配置启动；完整订阅恢复失败时明确停核，避免初始直连配置继续接管流量。
- 保留停核前的完整检查点，禁止从停止的核心重新捕获；监听就绪失败也统一验证完整订阅后才恢复回调，防止重复回调造成重复恢复。
- 修复更改 IPv6 偏好后旧检查点误拦正常恢复，以及配置恢复后的可选刷新不回调导致一直处于切换中的问题。
- 改进 Remote→Local 切换与运行状态保护；避免运行时修改已签名 App 的图标资源导致签名失效。

本版本为实验性 Lab。最低系统要求保持 macOS 10.14（Apple Silicon 为 macOS 11）。已完成隔离回归与独立源码复查；完整交互 GUI／授权弹窗及 macOS 10.14 实机运行仍未完成验收。

### English

- Retry first-start profile reloads within a bounded budget, retain sanitized core errors, and distinguish rollback to startup configuration from a verified full profile.
- Share Enhanced Mode exit and failed-retry handling: release owned listeners before configured startup and stop incomplete recovery instead of leaving the bootstrap DIRECT configuration active.
- Preserve frozen checkpoints while stopped. Validate the full profile before resuming callbacks after listener-readiness failure and keep recovery one-shot.
- Align restored IPv6 expectations with the fresh core session and prevent optional metadata refresh from leaving mode switching pending indefinitely.
- Harden Remote→Local transitions and avoid invalidating signed app bundles through runtime icon persistence.

Experimental Lab release. Minimum macOS remains 10.14 (macOS 11 for Apple Silicon). Isolated regressions and independent source review are complete; full interactive GUI/authorization-dialog and macOS 10.14 runtime acceptance remain unverified.

## ClashFX 1.1.11.16 (Lab)

### 中文

- 修复睡眠唤醒后增强模式 DNS 监听可能静默失效的问题：先原地重载已确认的配置，仍无响应才重建增强模式，避免争抢 DNS 端口。
- 新增唤醒后代理路径健康检查：最多采样 3 个当前选中的节点。采样节点全部失败时（例如订阅里的 DNS 已过期），区分节点域名无法解析、节点不可达和原因不明，并根据每次探测结果决定是否清理 DNS 缓存、重载配置、稍后复测或发出通知。通知只在探测仍失败时发出，30 分钟内最多一次。
- 系统再次进入睡眠时放弃尚未完成的唤醒恢复，避免在睡眠过渡期继续清理缓存、重载或弹出通知。
- 增强诊断日志：端口冲突时记录占用进程，记录增强模式关闭交接的时间线和监听端口采样，以及唤醒后 DNS 探测结果。
- 新增提示已本地化（简体中文、繁体中文、英文、日文、俄文）。

已知问题：启动或切换增强模式时 7890/7891 端口可能短暂冲突，通常几秒内自动恢复，早于本版本，仍在排查。

本版本为实验性 Lab。最低系统要求保持 macOS 10.14（Apple Silicon 为 macOS 11）。已完成隔离回归、单元测试和真机睡眠唤醒验证；macOS 10.14 与 Intel 实机运行、完整交互 GUI／授权弹窗验收仍未完成。

### English

- Fix the Enhanced Mode DNS listener silently failing after wake: reload the confirmed configuration in place first and rebuild Enhanced Mode only if the listener stays silent, avoiding a race for the DNS port.
- Add a post-wake proxy path check that samples up to 3 selected nodes. If all sampled nodes fail (for example, because the subscription DNS is stale), distinguish hostname resolution failures, unreachable nodes, and unknown causes. Each probe result determines whether to clear the DNS cache, reload the configuration, retry after a short wait, or notify. Notifications are sent only when probes still indicate failure, at most once every 30 minutes.
- Abandon unfinished wake recovery when the system goes back to sleep, so it no longer flushes, reloads or notifies during the sleep transition.
- Improve diagnostics: name the process holding a conflicting port, log a timeline and listener sampling for the Enhanced Mode close handoff, and log wake DNS probe results.
- Localize the new notifications (Simplified and Traditional Chinese, English, Japanese, Russian).

Known issue: ports 7890/7891 can briefly conflict during startup or Enhanced Mode handoff and normally recover within seconds. This predates this release and is still under investigation.

Experimental Lab release. Minimum macOS remains 10.14 (macOS 11 for Apple Silicon). Isolated regressions, unit tests and real-hardware sleep/wake validation are complete; macOS 10.14 and Intel runtime testing and full interactive GUI/authorization-dialog acceptance remain unverified.

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

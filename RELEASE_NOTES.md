## ClashFX 1.1.11.19 (Lab)

### 中文

- 修复关闭增强模式或启动本地核心时的代理端口冲突。ClashFX 会等待启动配置和所选配置实际使用的代理端口可重新绑定，每次交接的端口等待总上限为 45 秒。macOS 仍保留旧核心的 TCP 连接（TIME_WAIT）时，等待可能持续约 30 秒。
- 端口等待超时后可重试。交接失效时会取消等待，本地模式会在核心确认完整配置已生效后就绪。

本版本为实验性 Lab。已在 Apple Silicon 真机验证增强模式的开启、关闭和重新开启。最低系统要求为 macOS 10.14（Apple Silicon 为 macOS 11）。macOS 10.14 和 Intel 实机运行仍未验证。

### English

- Fix proxy port conflicts when turning off Enhanced Mode or starting the local core. ClashFX waits for the proxy ports used by the startup and selected configurations to become bindable, with a shared 45-second limit per attempt. When macOS keeps old TCP connections in TIME_WAIT, the wait can take around 30 seconds.
- A port timeout leaves the operation retryable. ClashFX cancels stale handoffs and marks Local ready after the core confirms the full configuration.

Experimental Lab release. Turning Enhanced Mode on, off, and back on passed on Apple Silicon hardware. The minimum macOS version is 10.14 (11 on Apple Silicon). macOS 10.14 and Intel runtime testing remain unverified.

---

## ClashFX 1.1.11.18 (Lab)

### 中文

- 修复退出时「恢复 DNS」与「恢复系统代理」同时写入系统网络偏好、互相抢锁，导致退出清理失败（`Preferences update currently in progress`）的问题：Helper 现在让所有系统网络偏好写入依次执行，并在锁被外部程序短暂占用时有限次退避重试。需要更新并重新安装 Helper 才生效。
- 退出清理未能完成时，不再弹出可能被其他窗口遮住的提示框而看起来像卡死：现在会把 ClashFX 切到前台，并提供「重试」「仍然退出」「保持 ClashFX 运行」三个选项。选择「仍然退出」后，ClashFX 会在下次启动时继续恢复 DNS 和代理设置。

本版本为实验性 Lab。已完成针对锁重试逻辑和退出选项的单元测试；退出时抢锁的真机复现、macOS 10.14 与 Intel 实机运行仍未验证。

### English

- Fix quit-time cleanup failing with "Preferences update currently in progress": restoring DNS and restoring the system proxy both write system network preferences at the same time and raced for the lock. The helper now runs these writes one at a time and retries for a bounded time when an outside program briefly holds the lock. The helper must be updated and reinstalled for this to take effect.
- When quit-time cleanup cannot complete, ClashFX no longer shows a dialog that may be hidden behind other windows and looks like a hang. It now comes to the front and offers Retry, Quit Anyway, or Keep ClashFX Open. After Quit Anyway, ClashFX continues restoring DNS and proxy settings on the next launch.

Experimental Lab release. Unit tests cover the lock-retry logic and the quit choices; reproducing the quit-time lock race on real hardware, macOS 10.14 and Intel hardware are still unverified.

---

## ClashFX 1.1.11.17 (Lab)

### 中文

- 修复重启后自动恢复增强模式时的连锁失败：系统 DNS 缓存刷新超时不再导致增强模式整体回滚。DNS 已写入并通过校验后，缓存刷新改为尽力而为，失败只记录日志；Helper 刷新命令的超时也从 2 秒放宽到 5 秒。
- 修复回退到内置核心时被刚退出的外部核心留下的 TCP 连接挡住、无法重新绑定代理端口（EADDRINUSE）的问题：恢复内置核心前先等待端口可绑定，超时则保留可重试状态，不会停止或改动其他进程和端口。
- 修复增强模式自动恢复在内置核心已停止时只重复报「重启内置核心失败」、从不尝试恢复的问题：现在每次重试都会先等待端口释放，再恢复内置核心并继续恢复增强模式。
- 修复 Lab 升级弹窗只显示「See release notes on GitHub」的问题：更新说明现在同时显示中文和 English，并随发布流程自动生成。

本版本为实验性 Lab。最低系统要求保持 macOS 10.14（Apple Silicon 为 macOS 11）。已完成单元测试和更新说明格式的回归测试；重启后自动恢复增强模式的真机复现、macOS 10.14 与 Intel 实机运行仍未验证。

### English

- Fix a cascading failure when Enhanced Mode is restored automatically after a restart: a timeout while refreshing the system DNS cache no longer rolls back the whole Enhanced Mode start. Once DNS is written and verified, the cache refresh is best-effort and a failure is only logged; the helper's refresh command timeout is also raised from 2 to 5 seconds.
- Fix a fallback to the built-in core being blocked by TCP connections left by the external core that had just exited, which prevented rebinding the proxy port (EADDRINUSE). The app now waits for the port to become bindable before resuming the built-in core; on timeout it stays retryable and never stops or changes other processes or ports.
- Fix the automatic Enhanced Mode restore repeating "Failed to restart built-in core" without ever trying to resume the stopped built-in core. Each retry now waits for the port, resumes the built-in core and then continues restoring Enhanced Mode.
- Fix the Lab update dialog showing only "See release notes on GitHub". Update notes now appear in both Chinese and English and are generated automatically by the release workflow.

Experimental Lab release. Minimum macOS remains 10.14 (macOS 11 for Apple Silicon). Unit tests and a regression test for the update-notes format are complete; reproducing the post-restart Enhanced Mode restore on real hardware, and macOS 10.14 and Intel runtime testing, remain unverified.

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

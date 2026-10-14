## ClashFX 1.1.11.11 (Lab)

### Improvements

- **Reliable Startup and Restart** — Confirm helper-managed core shutdown before handing off listeners, publish a ready enhanced core before runtime requests, and cancel stale startup retries after recovery succeeds.
- **Claude Lock Keeps Your Proxy Settings** — Disabling Claude lock preserves Enhanced Mode and System Proxy. Re-enabling and restarting restore the protected runtime without silently disabling the enhanced-mode preference after a failed restore.
- **DNS Listener Lifecycle Synchronization** — Serialize DNS listener publication and shutdown, wait for startup acknowledgement, and protect resolver-service updates to prevent races during immediate suspension or reload.
- **Safer DNS Recovery and Helper Updates** — Persist bounded per-service recovery journals, preserve newer external DNS changes, verify UDP/TCP DNS takeover, and restrict privileged execution to an approved root-owned core with validated client identity.
- **Cleaner Benchmark Menus** — Choose Quick or Complete testing in Settings, defaulting to Quick. Remove verbose menu summaries and manual prefixes, and use a compact old-result marker with details on hover.
- **Current Wi-Fi APIs and Useful Diagnostics** — Remove the obsolete airport fallback, skip SSID reads when auto-suspend is unused, and recheck after location authorization changes. Routine helper refresh and listener warm-up no longer appear as failures; interface warnings target the core's own TUN device.

Validation: 402 isolated XCTest cases (4 skipped, zero failures), 39 production Claude-lock flow checks and local App/Helper builds passed. Live Xcode checks covered helper update, lock disable/re-enable, app restart, DNS/proxy requests and sleep/wake recovery. Release CI rebuilds universal cores from source and checks packaged architectures and declared minimum OS versions. macOS 10.14 runtime testing remains outside demonstrated coverage. Subscription YAML errors are outside this release's changes.

---

### 改进

- **启动与重启恢复更可靠** — 核心交接前确认 helper 管理的旧任务已退出；新增强核心就绪后及时发布运行状态，并取消过期启动重试。
- **Claude 锁定保留代理设置** — 停用锁定保留增强模式和系统代理；重新开启和重启恢复受保护运行状态，恢复失败时不再悄悄关闭增强模式偏好。
- **DNS 监听生命周期同步** — 串行发布和关闭监听，等待启动确认并保护解析服务更新，消除立即暂停或重载时的数据竞争。
- **DNS 恢复与 Helper 更新更安全** — 按网络服务持久保存有大小限制的恢复记录，保留用户后续修改的 DNS，验证 UDP/TCP 接管；特权执行仅使用经验证、由 root 保管的批准核心。
- **测速菜单更简洁** — 快速／完整测速放入设置，默认快速；移除冗长菜单说明和手动前缀，旧结果使用简短标记并保留悬停详情。
- **Wi-Fi 接口与日志更新** — 移除旧 airport 回退，未使用自动暂停时不读取 SSID，定位授权变化后重新检查。正常 helper 刷新、端口等待使用合适日志级别，仅对当前核心的 TUN 接口提示异常。

验证：402 项隔离 XCTest（4 项跳过、0 失败）、39 项生产锁定流程检查及本机 App/Helper 构建通过。Xcode 实机验证覆盖 helper 更新、锁定取消／重新开启、App 重启、DNS／代理访问和睡眠唤醒恢复。发布 CI 从源码重新生成通用核心，检查最终包架构及最低系统版本声明；未完成 macOS 10.14 实机运行验证。订阅 YAML 错误不在本次修改范围。

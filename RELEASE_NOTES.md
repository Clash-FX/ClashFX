## ClashFX 1.1.11.14 (Lab)

### 中文

- 修复启动清理遗漏旧核心造成缓存数据库锁超时，以及测试核心缺少 gVisor 时卡在核心切换的问题。
- 等待 DNS 监听协程完成清理后再确认停止，修复快速启停时端口仍短暂占用的问题。
- 统一启动与重载的端口复用、冲突检查和 DNS 引用处理，补强 IPv6 与自定义配置校验；按实际绑定地址检查端口，避免无关 IPv6/LAN UDP 服务误拦回环启动。
- 配置切换采用事务校验与回滚；自动恢复保留节点选择，失败时不静默绕过代理。
- 补强 Selector 并发、provider 节点移除与恢复、快速启停和 API/PATCH 失败处理，并修复重载与 HTTP 连接读取认证器之间的并发竞争。
- 修复自动组换路后的测速展示，避免历史、失败与不同节点或 URL 的结果互相覆盖。
- 配置切换后保留 Claude 节点锁定；修复就绪检查中的后台 AppKit 访问。

本版本为实验性 Lab。最低系统要求保持 macOS 10.14（Apple Silicon 为 macOS 11）。

### English

- Fix stale-core cleanup missing a trailing-slash home path and leaving the cache database locked; verify gVisor capabilities before building or accepting an enabled TUN configuration.
- Wait for DNS cleanup owners to finish before confirming shutdown, preventing brief port retention during rapid restart.
- Align startup and reload port reuse, conflict checks and DNS references, including IPv6 and custom configurations. Probe the actual bind address so unrelated IPv6/LAN UDP services do not reject a loopback-only startup.
- Validate configuration changes transactionally with rollback. Preserve automatic-recovery selections and never silently fall back to bypass mode after failure.
- Harden Selector concurrency, provider removal/reinsertion, rapid lifecycle operations and API/PATCH failure handling; synchronize authenticator replacement with HTTP connection reads during reload.
- Keep benchmark displays scoped to the current path, node and URL as automatic groups change routes.
- Preserve Claude lock across configuration changes and keep Helper acquisition on the main queue during readiness checks.

Experimental Lab release. Minimum macOS remains 10.14 (macOS 11 for Apple Silicon).

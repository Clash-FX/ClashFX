# ClashFX 1.1.11.10 (Lab)

### Fixes

- **Proxy Lock** — Save lock preferences only after runtime and system proxy changes succeed. Roll back failed changes to the previous runtime and per-service proxy checkpoint; reject recursive dialing dependencies.
- **Runtime ownership and recovery** — Prevent a second ClashFX process from competing for the helper, core or system proxy. Coalesce recovery events, verify actual state and limit retries; quarantine unconfirmed helper writes and bound Rule-mode recovery.
- **Node selection** — Distinguish manual selection, automatic routing and manual priority. Show the core's actual route; automatic groups support a preferred node and Restore Auto without optimistic checkmarks.
- **Latency tests and diagnostics** — Remove duplicate test menus and move test options and display order to Settings. Separate current failures/timeouts from historical measurements; add copyable single-node diagnostics with controlled failure reasons.
- **Interaction consistency** — Coordinate selection, memory restoration, reloads, Lock and recovery. Reject stale replies across reloads and controller changes; bind diagnostics to the measured node and core scope.
- **App icon** — Use a fixed bitmap representation when saving custom icons and the Lab badge.

### Validation

349 isolated XCTest cases passed (4 real-core cases skipped there and passed separately), 4 isolated Mihomo integration cases passed, and 30 production-method checks passed. A disposable GitHub-hosted Mac passed 43 real Helper/TUN assertions covering startup/restart, invalid-config and proxy-write rollback, proxy/DNS restoration and fixture cleanup. [Backend acceptance run](https://github.com/Clash-FX/ClashFX/actions/runs/38252765807).

No running local ClashFX was changed during validation. Full GUI startup, SMJobBless authorization, physical display/power hot-plug and runtime testing on macOS 10.14 are outside this demonstrated coverage. The earlier HY2-69 API 503 does not identify its underlying cause; diagnostics now make future failures inspectable.

---

### 修复

- **Proxy Lock** — 核心与系统代理均成功后才保存锁定设置；失败恢复旧运行配置和逐服务代理检查点，拒绝循环拨号依赖。
- **运行控制与自动恢复** — 阻止第二个 ClashFX 副本争抢 Helper、核心和系统代理；合并恢复通知、读回实际状态并限制重试。未确认 Helper 写入隔离，Rule 模式恢复也有重试上限。
- **节点选择** — 区分手动选择、自动选路与手动优先，显示核心实际使用的选路；自动组支持优先节点及“恢复自动”，勾选等待核心确认。
- **测速与诊断** — 移除重复测速菜单，测速选项和显示顺序移至设置；分开显示本轮失败/超时和历史测量，补齐可复制的单节点失败原因诊断。
- **交互一致性** — 协调选择、记忆恢复、配置重载、Lock 和自动恢复；重载或控制实例变化后拒绝旧回复，诊断绑定节点身份与核心作用域。
- **应用图标** — 保存自定义图标和 Lab 标记时采用固定 bitmap 表示。

### 验收结果

隔离 XCTest 349 项通过（其中跳过的 4 项真实核心用例已单独通过）；独立 Mihomo 集成 4 项、生产方法探针 30 项通过。独立 GitHub macOS 环境真实 Helper/TUN 验收 43 项通过，覆盖启动/重启、无效配置及代理写入失败回滚、代理/DNS 恢复和夹具清理。[后端验收记录](https://github.com/Clash-FX/ClashFX/actions/runs/38252765807)。

验证没有改变本机正在运行的 ClashFX。完整 GUI 启动、SMJobBless 授权、物理外屏/电源热插拔和 macOS 10.14 实机运行尚未覆盖。旧 HY2-69 的 API 503 仍不足以判定底层原因；新增诊断用于分析后续失败。

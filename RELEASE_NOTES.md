# ClashFX 1.1.11.9 (Lab)

### Improvements and Fixes

- **Predictable benchmark modes** — Quick testing uses 2.5 seconds and Complete testing uses 5 seconds. Menus show progress and a visible completion summary; core timeouts remain distinct from failed nodes.
- **Retry failed Selector nodes** — Retry only matching failed or core-timeout targets from the latest run, keeping successful measurements. Switching to Complete gives slow nodes more time. Automatic groups still use core-controlled whole-group tests and fresh selection.
- **Stable latency display** — Choose configuration order or latency order; sorting applies when the menu reopens. Green, yellow and orange represent successful delays below 300 ms, 300–799 ms and 800 ms or more. Sorting does not change routing or configured fallback order.
- **Consistent benchmark scheduling and settings** — Equivalent targets are deduplicated with fixed 10-request concurrency. Settings expose HTTPS URL presets and measurement-method choices applied to runtime configuration without rewriting subscriptions. Existing saved URLs and inherited measurement behavior are preserved; new installs default to Cloudflare HTTPS and unified delay.
- **Reliable core recovery** — Helper tasks, launch/stop operations and listener checks are bounded and respect launch identity. Startup will not take over ports while old-core cleanup is unconfirmed; sustained API failures can recover even while traffic still flows.
- **Safe cache and delay-history access** — Embedded-core suspend/resume safely closes and reopens the cache database. Fixes upstream cache lifecycle and delay-history queue races during concurrent testing and selection.

Validation: 213 ordinary XCTest cases and two isolated real-core tests passed. Full Go tests and three race-detection runs passed; a fresh core App/Helper Debug build passed. Release CI separately verifies universal App/Helper/core architecture and minimum-system requirements. Local builds used a command-line macOS 12 override because Xcode 27 no longer supports the project's deployment floor; the project retains macOS 10.14 support. Full macOS 10.14 runtime and live GUI/Helper/TUN restoration remain outside the demonstrated coverage.

---

### 改进与修复

- **可预测的测速模式** — 快速测速为 2.5 秒，完整测速为 5 秒；菜单直接显示进度和完成统计，核心超时与节点失败分别统计。
- **仅重测失败的 Selector 节点** — 只重测最近一次运行中身份和测试条件匹配的失败或核心超时节点，保留成功结果；可切换完整模式延长测试时间。自动组仍由核心整组测试，并以新鲜选路状态为准。
- **稳定的延迟显示** — 可选择配置顺序或延迟顺序，重新打开菜单时才排序；成功延迟低于 300 ms、300–799 ms、800 ms 及以上分别显示绿、黄、橙色，不改变配置回退顺序或实际选路。
- **一致的调度与测速设置** — 等价目标去重，默认固定 10 并发。新增 HTTPS 地址预设和测量方式选择，只修改运行配置，不改写订阅；保留既有测速地址和继承行为，新安装默认使用 Cloudflare HTTPS 与统一延迟。
- **可靠的核心恢复** — Helper 任务、启动停止和监听检查均有时间上限及启动身份校验；旧核心清理未确认时不接管端口；持续 API 故障不会被仍有流量无限掩盖。
- **安全的缓存与历史访问** — 内置核心挂起和恢复时正确关闭、重新打开数据库；修复上游缓存生命周期及测速、选路并发访问历史队列的竞态。

验证：213 项普通 XCTest、2 项隔离真实核心测试、Go 全套测试及连续三轮竞态检测通过，新核心 App/Helper Debug 编译通过。发布 CI 另行检查通用架构及最低系统版本。本地 Xcode 27 使用命令行 macOS 12 覆盖进行验证，项目仍保留 macOS 10.14 支持；macOS 10.14 实机与完整 GUI/Helper/TUN 恢复尚未验证。

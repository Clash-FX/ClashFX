### Bug Fixes

- **Enhanced Mode Startup Readiness Hardened** — Enhanced Mode now waits until `/configs` reports a usable `mixed-port` or `port` before treating the external mihomo core as ready, avoiding the misleading "Ports Open Fail" popup when mihomo is already listening. (#75)
- **Transient Port-Zero Retry** — ClashFX now retries `/configs` responses that temporarily report `port=0`, and reissues the request if the active API/config context changes during the retry window. (#75)
- **Enhanced Mode Tray Highlight** — The menu bar icon now lights up when Enhanced Mode is active, even if the system proxy toggle is off. (#75)

---
### 修复

- **增强模式启动就绪判断加固** — 增强模式现在会等待 `/configs` 返回可用的 `mixed-port` 或 `port` 后才认为外部 mihomo core 已就绪，避免 mihomo 已经监听端口时仍误弹“端口打开失败”。（#75）
- **临时 port=0 自动重试** — ClashFX 现在会对 `/configs` 短暂返回 `port=0` 的情况进行退避重试；如果重试期间 API/配置上下文发生变化，会自动按最新上下文重新请求。（#75）
- **增强模式图标高亮** — 菜单栏图标现在会在增强模式启用时变亮，不再必须开启“系统代理”才高亮。（#75）

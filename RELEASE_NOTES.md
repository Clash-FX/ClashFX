### Bug Fixes

- **Selected Subscription Restored on Relaunch** — ClashFX now keeps the selected remote subscription/config visible after restart instead of temporarily falling back to `config` while the core is stopped. (#75)
- **Enhanced Mode Startup Recovery Hardened** — Startup cleanup now targets only ClashFX-owned stale `mihomo_core` processes and avoids killing unrelated mihomo processes on the system. (#75)
- **Quit Menu Remains Responsive** — During quit-time proxy/Enhanced Mode cleanup, the menu bar item now shows a disabled “Quitting…” menu instead of appearing unresponsive. (#75)

---
### 修复

- **重启后保留已选订阅** — ClashFX 重启后会继续显示已选中的远程订阅/配置，不再因为核心尚未运行而临时回退到 `config`。（#75）
- **增强模式启动恢复更安全** — 启动清理现在只会处理 ClashFX 自己遗留的 `mihomo_core` 进程，避免误杀系统中的其他 mihomo 进程。（#75）
- **退出清理时菜单保持可反馈** — 退出期间等待代理/增强模式清理时，状态栏菜单会显示不可点击的“Quitting…”提示，不再表现得像没有响应。（#75）

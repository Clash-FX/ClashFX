### Bug Fixes

- **Legacy Config Fallback Rule Repair** — On launch, ClashFX now repairs already-written generated share-link compatibility configs that still contain `MATCH,Auto`, rewriting their fallback rule to `MATCH,Proxy` so manual proxy selections take effect for fallback traffic without waiting for the next remote refresh. Runs once per user, only on ClashFX-generated configs. (Thanks @YangYongAn — #59)
- **Restored Selection Connection Cleanup** — When saved proxy selections are automatically restored on config reload, existing connections are now closed once after all selections are applied so new traffic uses the restored route immediately. (#59)

---
### 修复

- **旧生成配置兜底规则修复** — 启动时会自动修复已落盘的 ClashFX 生成兼容配置中残留的 `MATCH,Auto`，把兜底规则改为 `MATCH,Proxy`，让手动选择的节点立即对兜底流量生效，不必等下一次远程刷新。每用户只跑一次，仅作用于带 ClashFX 生成标记的配置。（感谢 @YangYongAn — #59）
- **恢复记忆选择后清理连接** — 配置重载时自动恢复已保存的代理选择后，会在所有选择恢复完成后统一关闭一次现有连接，让新流量立刻走恢复后的路由。（#59）

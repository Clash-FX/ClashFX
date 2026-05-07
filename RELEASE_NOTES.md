### Bug Fixes

- **WireGuard Proxy Loading Fixed** — Configs containing WireGuard proxies failed to load with `create WireGuard device: gVisor is not included in this build, rebuild with -tags with_gvisor`. The embedded mihomo core was built without the `with_gvisor` build tag required by mihomo's userspace WireGuard implementation; the standalone `mihomo_core` binary already had it, but the c-archive linked into the main app process did not. Thanks @DareYouS. (#70, #71)

---
### 修复

- **修复 WireGuard 代理加载失败** — 含 WireGuard 节点的配置加载失败，报错 `create WireGuard device: gVisor is not included in this build, rebuild with -tags with_gvisor`。内嵌的 mihomo 核心在编译时缺少 `with_gvisor` 标签（mihomo 用户态 WireGuard 实现所必需）；独立的 `mihomo_core` 二进制本就带了这个标签，但链接进主进程的 c-archive 没带。感谢 @DareYouS。（#70, #71）

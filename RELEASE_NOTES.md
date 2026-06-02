### Bug Fixes

- **Enhanced Mode No Longer Times Out All Nodes on Startup** — When Enhanced Mode (TUN) was enabled, the external `mihomo` core's own outbound connections — proxy server handshakes and rule-provider HTTP fetches (YouTube, ChinaMax, DMM, SteamCN, Bahamut, etc.) — were being re-captured by the TUN device and routed back through the rules engine, hitting `MATCH/<proxy-group>` before any session could be established. This caused a self-bootstrapping loop where every node reported `context deadline exceeded` and all rule-providers failed with EOF. The root cause was that no rule in the generated `.enhanced_config.yaml` excluded the `mihomo` process itself from TUN interception. Fixed by prepending `PROCESS-NAME,mihomo,DIRECT`, `PROCESS-NAME,mihomo-bin,DIRECT`, and `PROCESS-NAME,mihomo_core,DIRECT` ahead of all user rules in the generated config so the core's own traffic always exits directly without re-entering the tunnel. Thanks @JackeyLov5 for the detailed log and patient follow-up. (#75)
- **Enhanced Mode No Longer Silently Exposes Proxy to LAN** — The generated `.enhanced_config.yaml` was inheriting `bind-address: "*"` from the source config, causing the proxy listener to accept connections from all network interfaces even when `allow-lan` was not explicitly set. On shared networks this meant other devices on the same LAN could route traffic through your proxy without any indication in the UI. The generated config now enforces `allow-lan: false` and `bind-address: 127.0.0.1` by default; if the source config explicitly declares `allow-lan: true`, the original value is preserved. Thanks @JackeyLov5 for reporting both issues together. (#75)
- **Help Menu Lab Items Now Have Individual Visibility Toggles** — "Send Feedback…", "Copy Diagnostic Info…", and "Open Crash Log Folder" can now be individually shown or hidden from the tray menu display settings, matching every other menu item. The "Roll Back to Stable…" toggle correctly appears only on Lab builds where that menu item actually exists; Stable users no longer see a non-functional toggle. The separator above the Lab Help block is also hidden automatically when all items in the group are hidden. Thanks @ayangweb for the contribution. (#112)

### Contributors

- @ayangweb — Help menu Lab item visibility toggles (#112)
- @JackeyLov5 — Detailed Enhanced Mode log and reproduction that pinpointed both the node-timeout and LAN-exposure bugs (#75)

---

### 修复

- **增强模式启动不再导致节点全部超时** — 开启增强模式（TUN）后，外部 `mihomo` 核心自身发出的连接——向代理服务器握手、拉取 rule-provider（YouTube、ChinaMax、DMM、SteamCN、Bahamut 等）——会被 TUN 设备重新截获，经规则引擎命中 `MATCH/<代理组>`，在任何 session 建立成功之前形成自举死循环，导致所有节点 `context deadline exceeded`、所有 rule-provider 报 EOF。根本原因是生成的 `.enhanced_config.yaml` 中没有任何规则将 `mihomo` 进程自身排除在 TUN 拦截之外。修复方式：在生成配置的所有用户规则之前插入 `PROCESS-NAME,mihomo,DIRECT`、`PROCESS-NAME,mihomo-bin,DIRECT`、`PROCESS-NAME,mihomo_core,DIRECT`，确保核心自身出站流量始终直连、不重入隧道。感谢 @JackeyLov5 提供详细日志并耐心跟进。(#75)
- **增强模式不再静默将代理暴露给局域网** — 生成的 `.enhanced_config.yaml` 会继承源配置的 `bind-address: "*"`，导致即使未显式开启 `allow-lan`，代理监听端口也会绑定到所有网卡。在共享网络环境下，同局域网的其他设备可以在 UI 毫无提示的情况下将流量路由进你的代理。现在生成配置时默认写入 `allow-lan: false` 和 `bind-address: 127.0.0.1`；若源配置明确声明了 `allow-lan: true`，则保留原值不变。感谢 @JackeyLov5 同时报告了这两个问题。(#75)
- **Help 菜单 Lab 项现已支持独立显示/隐藏** — 「Send Feedback…」「Copy Diagnostic Info…」「Open Crash Log Folder」现在可以在菜单栏显示设置中单独控制，与其他所有菜单项一致。「Roll Back to Stable…」开关现在只在 Lab 构建中显示，Stable 用户不会再看到一个无任何效果的开关。当 Lab Help 块的所有子项均被隐藏时，上方的分隔线也会自动隐藏。感谢 @ayangweb 的贡献。(#112)

### 贡献者

- @ayangweb — Help 菜单 Lab 项独立显示/隐藏 (#112)
- @JackeyLov5 — 提供详细增强模式日志和复现步骤，准确定位了节点超时与 LAN 暴露两个 bug (#75)

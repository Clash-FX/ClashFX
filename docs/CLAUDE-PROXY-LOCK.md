# Claude Proxy Lock / Claude 专用代理锁定

Claude Proxy Lock pins supported Claude traffic to one concrete proxy node and fails closed when that route is unavailable. It is intended for a dedicated residential proxy or another node that must never fall back to a different exit.

Claude 专用代理锁定会把受支持的 Claude 流量固定到一个具体代理节点。指定线路不可用时，流量会被阻断，不会切换到其他出口。它适合专用住宅代理等禁止回落的使用场景。

## 使用方法

1. 在当前配置中加入可用的具体代理节点。该节点不能是 Selector、URLTest 等策略组，也不能是 `DIRECT` 或 `REJECT`。
2. 打开 ClashFX 菜单，选择 **Claude 专用代理锁定…**。
3. 选择代理节点，然后点 **启用锁定**。
4. ClashFX 会自动启用增强模式、规则模式和系统代理。Claude 桌面版（含 Claude Helper）、Claude Code 进程，以及 `claude.ai`、`claude.com`、`anthropic.com` 域名会优先匹配锁定规则。出口仍是锁定节点；连到该节点服务器的这一段，会经由当前 `MATCH` 规则选中的节点中转，避免本机直连住宅代理地址。
5. 更换节点时再次打开该菜单并点 **应用锁定**。需要关闭保护时，先点 **停用锁定**，再关闭增强模式或系统代理。

锁定启用期间，ClashFX 会阻止手动关闭规则模式、增强模式和系统代理。如果其他控制器改变规则模式或 macOS 系统代理，ClashFX 会尝试恢复。退出 ClashFX 时，系统代理会保持指向已停止的本地核心，使遵循系统代理的客户端断网；重新打开 ClashFX 可以恢复服务。若希望退出后恢复原来的系统代理，请先停用锁定。

## How to use it

1. Add a working concrete proxy node to the active configuration. A Selector, URLTest group, `DIRECT`, or `REJECT` cannot be selected.
2. Open the ClashFX menu and choose **Claude Proxy Lock…**.
3. Select the node and click **Enable Lock**.
4. ClashFX enables Enhanced Mode, Rule mode, and System Proxy. Rules cover Claude Desktop, including Claude Helper processes, the Claude Code process name, and the `claude.ai`, `claude.com`, and `anthropic.com` domains. The locked node remains the exit. The connection to that node's server is dialed through the proxy selected by the current `MATCH` rule, instead of directly from this Mac.
5. Reopen the menu and choose **Apply Lock** to change the node. Choose **Disable Lock** before turning off Enhanced Mode or System Proxy.

While the lock is active, ClashFX prevents those protected modes from being switched off and attempts to restore Rule mode or System Proxy after an external change. Quitting leaves System Proxy pointed at the stopped local core, so clients that honor it remain offline until ClashFX is reopened. Disable the lock first if the original System Proxy should be restored on quit.

## 保护边界 / Protection boundary

ClashFX can enforce the route while traffic is captured by Enhanced Mode or the macOS System Proxy. Browser extensions with their own proxy stack, manually configured per-app proxies, other VPN or Network Extension products, and software that ignores macOS networking settings can bypass that control. The process rule matches `Claude`, `claude`, and `Claude Helper` (including Renderer, GPU, and Plugin). Custom Claude Code gateways outside Anthropic domains depend on that process name; wrapper processes with a different executable name are not guaranteed to match.

ClashFX 能保护增强模式或 macOS 系统代理实际捕获到的流量。使用独立代理栈的浏览器扩展、应用内手动代理、其他 VPN/Network Extension 产品，以及忽略 macOS 网络设置的软件可能绕过控制。进程规则匹配 `Claude`、`claude` 和 `Claude Helper`（含 Renderer、GPU、Plugin）。Claude Code 使用非 Anthropic 自定义网关时依赖该进程名；若包装程序使用了不同的可执行文件名，无法保证命中。

# 2026-09-24 换网后增强模式故障诊断

## 结论
本机安装 1.1.11.6（1001011006），包含 c401a4cd 的 DNS 修复。已 fetch 远端，最新 origin/HEAD 与当前源码仅 appcast 有差异。现有证据指向：底层网络接口暂时不可用，触发 TUN 出口错误；日志恢复入口仍重建核心；核心启动未就绪及 Helper 重试异常后，恢复期间的零端口状态进入致命配置检查，产生误导性弹窗。不能依据该弹窗认定用户 YAML 缺少端口。

没有证据证明固定 DNS 端口改动直接导致此次启动失败。新进程停在何处仍未确定，失败进程的 sample 没有成功生成，不能将其武断归因于 DNS、缓存锁或系统问题。

## 本机证据（北京时间）
- 17:21:05，核心记录 default interface lost by monitor；该轮日志中约 31,563 行涉及网卡的 warning/error。
- 17:29:49，日志恢复入口记录 outbound-interface error storm；诊断快照 primaryInterface=none，随后重建增强模式。
- 17:29:52，截图中的 PID 86592 启动，仅输出 euid/uid，没有出现 Start initial configuration 或 API listening。
- 17:30:00，就绪重试耗尽；sample 失败；该进程约 20.286 秒后被 SIGTERM 终止。SIGTERM 是恢复流程的终止结果，不是崩溃证据。
- 17:30:14，Helper host restart 超时；随后 XPC invalidated/interrupted。
- 17:35:11，requestConfig 重试后仍为 0，setupData 发布 0,0；ClashStatusTool 触发 stale core cleanup。同一时段界面仍报告 Enhanced Mode recovery in progress。
- 17:43:02，另一次重建成功，API 19090、Mixed 7890、DNS 49595 就绪。
- 17:46–17:48，曾有 /configs 超时；17:49 日志报告 health recovered。
- 诊断期间实时请求：/version 返回 1.19.24；/configs HTTP 200，mixed-port=7890、socks-port=7891；/dns/query?name=example.com&type=A HTTP 200，两个 Answer。TCP 7890、19090 可连接。
- 生成配置中 DNS listen 与 proxy-server-nameserver 的 loopback 端口一致。7874 当时被占用，代码选择并改写备用端口；随机备用端口本身不等于旧缺陷复发。

运行进程与生成配置在诊断期间发生过变化，故实时通过仅代表采样时状态，不能证明故障不再发生。本次诊断未重启应用、未切换系统代理/DNS、未替换安装包。

## 源码定位
1. ClashFX/AppDelegate.swift:2359 recoverFromCoreLogFailure：出口网卡不可用与 TUN socket 关闭共用重建入口，未检查 primary interface。普通唤醒恢复路径在约 2417 行已有网卡检查，两者行为不一致。
2. ClashFX/General/ApiRequest.swift:300：零 HTTP 端口重试耗尽仍调用 completeHandler(config)，可发布临时状态。
3. ClashFX/General/Utils/ClashStatusTool.swift:15：只按 isEnhancedModeActive 跳过检查，未涵盖启动/重建/退出过程；会停止核心、重载配置，并将零端口明确归因为缺失字段，最后退出应用。
4. ClashFX/AppDelegate.swift:3670：就绪检查把 API 不可达、端口尚未创建、DNS 未就绪汇总为失败；需要分阶段诊断和尝试身份。
5. ClashFX/goClash/main.go:122：7874 不可用时选备用端口，并同步改写本机 DNS 引用；目前观察到的配置符合这项修复。

## 建议方案
P0：对 outboundInterfaceUnavailable 单独处理。没有物理主网卡/默认路由时进入“等待网络”；网络稳定后探测核心，再决定重建。closedTunSocket 仍保留真正故障恢复。避免离线时反复重启和刷日志。

P0：恢复状态统一到同一生命周期与 generation。启动/停止/重建期间不发布零端口为有效配置，不允许 ClashStatusTool 并行停止核心或弹出缺端口错误。只有对当前已就绪核心取得有效配置且确认确实没有可用端口，才报告配置错误。

P1：记录启动阶段、PID/launchID、API 状态、预期代理/DNS 端口；对新进程增加读取配置前后和解析阶段 breadcrumb。Helper 超时或旧回调不得继续写入新一轮状态。启动等待使用有界总时限，而非仅按快速连接失败次数耗尽。保留并改进失败诊断。

P1：保留上次 DNS 修复，明确记录 7874 被占用及备用端口选择；补充 TCP/UDP、端口占用和 loopback 改写验证。

## 验收
覆盖离线唤醒、办公室到家换网、Wi-Fi 关闭再开启、底层网络恢复较慢、核心启动迟缓、Helper 超时、旧回调到达、7874 占用。要求无重启风暴、无虚假的缺端口退出、无旧状态覆盖新会话，恢复后 API、Mixed 端口、DNS 和实际代理请求均通过。保持 macOS 10.14 兼容，完成定向自动化及真机换网验证后再发布 Lab。

## 当前使用建议
采样时已恢复，不必为了“端口缺失”修改订阅或降级。若再次持续失效，可在网络稳定后先关闭增强模式、使用普通系统代理模式恢复工作，再启用增强模式；这只是临时恢复路径。此次只完成诊断和方案，未修改生产代码或发布版本。


# 补充诊断：17:54–18:26 新日志（修订前述优先级）

**更正：不能再笼统说上次 Lab 改动与故障无关。** DNS 引用改写本身仍没有失配证据，但同一提交 c401a4cd 新增的“有流量则跳过所有 unhealthy 恢复”明确掩盖 TUN 失效；新增 DNS TCP 连通检查也会将其他进程监听的端口当成当前核心就绪。先前仅检查 API/Mixed/DNS 成功，不能据此断言增强模式整体健康。

## 新证据
| 时间 | 事实 | 意义 |
|---|---|---|
| 17:54:45 | en0 存在、utun8 有 IPv4；/configs 三次超时后重建 | 本轮不能只用“主网卡缺失”解释 |
| 17:55:54 | 应用判断启动超时；核心 17:55:58 开始监听 API/Mixed/DNS，17:55:59 TUN 建立 | 重试耗尽后进入诊断，核心后来就绪仍走回滚，缺少最终复查 |
| 17:56:13 | 重建成功，API TUN enable=true | TUN 起初确实建立 |
| 17:57:24–18:03:11 | 反复 TUN disabled，但 traffic still flowing; not rebuilding | 普通代理流量掩盖增强模式失效，延迟恢复约六分钟 |
| 18:03:24 | en0 存在，utun0–7 均无 IPv4，原 utun8 已不存在 | 不只是提示噪声，TUN 接口实际丢失 |
| 18:03:47 | 新核心 DNS TCP 与 UDP 的 7874 均 bind: address already in use | 有真实 DNS 监听失败 |
| 18:03:49 | 应用仍记录 API + listeners ready，Enhanced Mode started | TCP 可连接不足以确认本次启动拥有 DNS 监听 |
| 18:04:04 | 核心日志 API=51515，同轮诊断却检查 51294 | 控制端口/尝试身份发生错配 |
| 18:06:06–15 | 两组诊断、重试、生成配置和成功回调；PID98771 存活 0.094 秒即被终止，随后 PID98772 启动 | 重叠启动/旧回调是必须处理的高风险点，不能只增加重试次数 |

上述核心日志在 ~/.config/clashfx/.mihomo_core_logs 下，分别为 095547、095609、100346、100404、100612 开头的 launch。应用日志为 17-21-08 与 18-06-40 两个轮转文件。日志没有调用来源及 app PID 标识，不能完全排除多实例或其他 API 客户端参与；但当前源码确实缺少统一生命周期互斥及每次尝试的身份隔离。

## 源码缺口
- AppDelegate.swift:1802 对任何 unhealthy 使用总体流量保护，未区分 API 超时与明确的 TUN disabled。此判断是 c401a4cd 新增。
- AppDelegate.swift:3314 异步生成同一路径 .enhanced_config.yaml；goClash/main.go:1317 直接写文件。每次启动返回的端口与稍后进程读取的配置缺少绑定。
- AppDelegate.swift:3368 使用全局 expectedEnhancedDNSPort，waitForExternalCore 未验证 generation/launchID，旧流程可能读取新流程的预期值。
- AppDelegate.swift:3820 只 connect TCP；即使其他进程占有该端口，也返回 true。Go checkPortAvailable 同样只有预先 TCP 检查，不能消除检查与绑定之间的竞争，也未检查 UDP。
- ProxyConfigHelper.m:698 收到新 start 会终止当前任务并再启动；并行上层启动因此会互相干扰。
- AppDelegate.swift:3762 的 TUN 检查延迟两秒执行，未作为启动成功的必要条件。
- AppDelegate.swift:1414 与 ApiRequest.swift:351：普通配置重载可将 runtime/source 配置 PUT 到当前外部核心，未统一经过增强配置生成。它是 TUN 被关闭的一条源码风险路径，尚不能从现有日志确认就是本次关闭来源。

## 新方案（替代只加换网等待的方案）
1. **P0：统一增强模式生命周期。** 启用、关闭、唤醒、健康恢复、配置重载、退出都进入一个协调器。同一时刻仅允许一个切换事务；重复请求合并。每次事务/重试有 generation 与 launchID，所有 Helper 回复、网络回调、延时任务、DNS 恢复和回滚都校验身份。关闭或退出立即使旧事务失效。Helper start/stop 同样串行且按身份操作，避免旧停止请求误杀新进程。
2. **P0：每次启动使用独立不可变配置。** 包括 runtime patch 和 enhanced 配置；写临时文件后原子完成，不重复覆盖在途进程的输入。预期 API/DNS/代理端口保存在该尝试上下文中，禁止全局互相覆盖。完成后再清理过期文件。
3. **P0：健康分类。** 短暂 API 超时可以依据新鲜流量有限宽限；tun.enable=false 或期望 TUN 接口消失不能被总体流量抵消。用同一会话的短间隔复查排除切换瞬态后恢复。物理网络缺失进入等待网络，避免重建风暴。用户关闭增强模式不触发自动重启。
4. **P0：真实启动验收。** 同一 launch 的 API、代理监听、TUN enable及期望接口、DNS TCP/UDP 均就绪后才成功及应用系统 DNS。用 Helper 的进程身份和监听归属/当前启动日志核对 DNS，不凭端口可连通过关；再执行功能查询。明确绑定失败只对当前 launch 生效，选择备用端口同步改写后有界重试。停旧核心并确认退出后再选端口。
5. **P1：修正等待与回滚。** 使用可配置的有界总启动时限（建议先验证 20–30 秒），诊断耗时计入预算但不应冻结就绪观察；决定杀进程前复查当前 launch，避免慢启动已成功却被回滚。串行重试带退避，保留前轮零端口误报修复。
6. **P1：增强模式配置重载保持 TUN。** 所有重载走同一配置生成与事务；记录配置类型、hash、触发来源及 TUN 变更前后。当前日志不足以确定 TUN 最初为何被关闭，必须补足该证据。

## 验收重点
- 模拟 Mixed 仍有流量但 TUN disabled，确认不会无限跳过恢复。
- 其他进程占用 DNS TCP/UDP端口，确认不得宣告本核心就绪。
- 快速切换、自动恢复与配置刷新同时到达，只允许一个有效启动；旧回调、退出后的回调不得杀/启动新核心。
- 慢启动超过原先约五秒轮询窗口，在总预算内成功；诊断后不误杀已就绪核心。
- 逐尝试核对 API 端口与不可变配置、launchID 一致。
- 真机合盖、换 Wi-Fi、离线恢复及长期普通代理流量下 TUN 失效场景。通过后才发布 Lab，保持 macOS 10.14 兼容。

## 当前状态与独立问题
重新实测 /configs：mixed-port=7890，tun.enable=true，device=utun8；ifconfig 确认 198.18.0.1，DNS API 有两个 Answer。最新轮转日志截至 18:26 未发现新的增强模式健康失败/重建记录；这仅代表本次观测，不是问题已修复。

18:04:40 订阅更新另有 YAML 解析错误，响应开头像“请登…”而非配置；需要单独核对订阅服务响应，不应与上述生命周期问题混为同一根因。未访问订阅地址、未修改用户设置或安装包。本轮只修订方案。

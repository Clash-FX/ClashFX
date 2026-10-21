# 启动与 DNS 复查修复

这次修复针对复查发现的三个问题与两个优化点，并缩短旧测速结果的显示。

## 修复范围

- Helper 客户端鉴权必须验证签名；临时签名构建需要管理员安装时批准的代码身份。增强模式只能执行安装时批准、由 root 保管的核心。
- DNS 恢复日志保留前序事务身份。新日志已落盘但新 apply 请求未送达时，仍能恢复此前已应用的设置；后续无关事务继续阻止过期恢复。
- 配置中的普通 DNS 上游与原监听地址相同、且端口被代理或 API 占用时，拒绝该配置，避免把代理端口当作 DNS 服务。
- 配置读取与检查在暂停当前核心之前完成；准备阶段有截止时间，迟到结果不得发起新的启动。
- DNS 日志读写和 JSON 处理移到串行后台队列，日志限制为 1 MiB。
- 菜单旧测速结果显示为 `37 ms · 旧`，悬停说明保留；本轮新结果不加标记。

Helper 协议更新为 6。正式签名客户端先通过证书要求，再安装经 root 暂存副本完整签名验证的核心；临时签名客户端需要管理员批准的精确代码哈希。核心与信任凭据由 root 保管，设置为只读并带不可变标记。

升级旧 Helper 或临时签名 App 时，新客户端可能尚不能调用旧服务。存在 DNS 恢复凭据时，管理员安装脚本先验证暂存 App，运行暂存 Helper 的 `--restore-dns-json-stdin` 恢复入口，确认 DNS 读回成功后才卸载旧服务。该入口拒绝非 root 调用，限制 JSON 为 1 MiB，并保留原日志供新 Helper 再次验证、清理。

配置预检验证 YAML 结构、代理端口与自定义配置端点。Mihomo 的完整语义解析会修改核心共享状态，因此仍在新核心启动时执行。

## 验证边界

- XCTest：398 项，4 项跳过，0 失败。覆盖 DNS 事务、重复应用、迟到清理、签名信任策略、历史测速展示，以及新旧核心路径的归属判断。
- Go：端口冲突、监听地址别名、解析循环、节点解析引用与暂停监听相关测试通过。
- 独立核心 DNS 监听和真实核心菜单测试通过；临时 App/helper 构建通过，并使用重新生成的 Go 静态库。
- 管理员恢复入口的非 root 拒绝检查通过；生成的安装脚本通过 Bash 语法与输入管道检查。

验证使用独立核心、临时构建目录和不启动 GUI 的测试目标。没有替换 `/Applications/ClashFX.app`，没有安装 Helper，也没有切换这台电脑的系统代理、DNS 或 TUN。

真实登录冷启动、管理员安装后的权限链与 TUN 切换仍需在专门环境验证。支持 macOS 10.14 的源项目设置保持不变；本机新版 Xcode 的构建验证使用命令行部署目标覆盖。


## 2026-10-17：启动与重载的 DNS 端口引用

本机 Lab 1.1.11.13 的启动日志确认：源配置 `dns.listen: 0.0.0.0:7874`、`proxy-server-nameserver: [udp://127.0.0.1:7874]`，生成增强配置时监听变为 `127.0.0.1:49634`，节点解析引用仍停留在 7874。14:51:54 至 14:52:55 的独立核心日志记录 7755 条该端口的拒绝连接。配置重载后引用变为 49634，错误消失。再次开启增强模式产生同样的问题，直到重载才恢复。

启动端口分配和重载固定活动端口统一使用 Go 的 DNS 引用处理规则。IPv4 wildcard 监听与同端口的本机 IPv4 plain UDP/TCP 节点解析地址视为同一服务，端口移动时引用随之移动。普通上游、其他端口的本地解析器、DoH/DoT 和未证明属于该监听的地址保持原值；固定端口若撞上独立解析器引用则拒绝，避免引入解析循环。

重载通过新增的 cgo 入口 `clashRetargetEnhancedDNSConfig` 调用共享规则，移除 Swift 对所有 loopback 地址的正则替换。生成式增强配置和自定义增强配置的重载都使用这个入口。启动的监听所有权、UDP/TCP 协议就绪检查仍不等同于所有代理节点的出口可用性。

验证在临时 checkout、临时配置和独立测试进程中进行；不启动完整 GUI，不安装 Helper，不替换 `/Applications/ClashFX.app`，不更改本机代理、DNS 或 TUN。验证结果：

- Go DNS/Bootstrap/Retarget/Loopback 定向测试：43 个测试及子用例通过，0 失败、0 跳过。包括独立本地 Mihomo DNS 解析，分别验证 loopback/wildcard 源监听经过启动回退与重载固定端口后，节点解析仍能到达临时上游并得到预期答案。监听使用临时空闲端口，固定 49634/51188 的配置回归不绑定这些端口。
- 相关 XCTest：31 项，0 失败；另有 31 项既有测速回归通过。测试无主 App 宿主。移除的旧 Swift DNS 正则测试由 Go 的共享生产规则、临时文件及实解析回归取代，生命周期断言保留。
- 独立 Swift/cgo 调用通过：wildcard 配置迁移到 49634，再迁移到 51188，独立本地 DNS 与 DoH 地址保留；非法端口返回错误且文件字节不变。Go 文件回归另验证权限保留、冲突失败不修改原文件且不遗留临时文件。
- 从最终源文件重新生成 Go c-archive 与头文件，完整 App/Helper 隔离构建通过。工作区的忽略文件 `goClash.a` / `goClash.h` 同步为生成的 arm64 版本；未手改生成头文件。原工作区产物已备份到验证目录。
- 构建使用本机 Xcode 27，并仅在命令行覆盖部署目标为 14.0；仓库的 10.14 发布设置未改变。本轮没有做 10.14 实机或本机应用冷启动验证。
- 验证前后，安装的 App、Helper、核心文件 SHA-256，三个运行进程及启动时间，`scutil --proxy` 和 `scutil --dns` 输出均完全一致。

复跑定向 Go 测试：

```sh
python3 ClashFX/goClash/run_core_tests.py --run 'Test.*(DNS|Bootstrap|Retarget|Loopback)'
```

本轮日志、临时配置、构建与前后快照目录：`/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-startup-dns-fix-ngfxn32u`。没有提交、推送、安装或发布。


## 2026-10-17：独立子代理复查

使用两个未参与修复的新 Luna 子代理分别检查跨语言启动/重载调用链，以及 Go DNS 引用范围和回归覆盖。两者均只读审查，不运行或控制本机应用、核心、Helper 或网络设置。父代理另核对最终源码与原验证副本、生成 cgo 符号和既有日志；没有把旧测试日志当作新的实测。

结论：未发现本次共享引用改写新增的独立 resolver 误改。启动和两条重载路径使用同一套 scoped bootstrap 规则；普通上游、策略上游、不同端口的本地 resolver、DoH/DoT 不被这条规则整体改写。来源按 YAML 中监听与 resolver 的地址/端口对应关系推导，不是独立的生成来源标签；这属于本次规则的语义边界，不另列为已复现的新缺陷。

### P2：重载固定 DNS 端口缺少代理监听冲突校验（既有问题）

`retargetEnhancedDNSConfigFile` 取得完整配置后，只把 `dns` 子树传给 `retargetEnhancedDNSListen`。后者检查 resolver 引用冲突，却不检查完整配置的代理监听端口。启动生成路径则把代理端口与 API 端口作为 DNS 分配的保留端口。因此引用规则已统一，但启动与重载的监听端口预检尚未完全一致。此前 Swift 的无条件固定端口也有同一缺口；这不是本次新引入的问题。

父代理用隔离副本和临时 YAML 复现：配置 `port: 49634`、`dns.listen: 0.0.0.0:7874`、`proxy-server-nameserver: [udp://127.0.0.1:7874]`，调用文件改写函数固定 DNS 为 49634。函数成功返回，写出代理端口 49634 与 DNS 监听 `127.0.0.1:49634`。要求拒绝此配置的反例测试如预期失败，证明缺少拦截；没有真正启动这些监听或执行运行中核心的重载，实际监听失败行为未测试。

建议固定 DNS 端口前，对最终配置的所有代理监听端口和最终 API 端口做冲突检查，并覆盖普通/自定义重载路径。此次仅复查与记录，未修改生产代码或生成桥接文件。

复查证据目录：`/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-dns-independent-review-chvyk35p`，其中 `port-collision-probe.log` 是预期失败的反例，`before.json`/`after.json` 为运行状态对比，`source-before.json`/`source-after.json` 为本次涉及源码及桥接产物的哈希。最终对比均一致。没有替换、重启、发布或安装应用，没有更改系统代理、DNS 或 TUN。


## 2026-10-17：修复 P2 重载监听端口冲突

启动生成和重载固定 DNS 端口统一从最终运行配置收集保留端口：`port`、`socks-port`、`mixed-port`、`redir-port`、`tproxy-port`、`listeners[].port`，以及最终 `external-controller` / `external-controller-tls` 的有效 TCP 端口。生成启动在确定最终 API 地址后分配 DNS 端口；普通和自定义重载在 Swift 写好最终 API 地址之后，通过同一个 Go 文件改写入口验证，禁止把 DNS 固定到保留端口。

共用检查还拒绝 API 与代理、API 与 TLS API 的同端口配置。检查只查看配置数据，不探测或重新绑定正在运行核心的监听端口。冲突返回稳定的 `[port_conflict]` 分类和 `reason=reserved_listener`，在创建临时输出文件与提交配置之前退出；成功路径仍使用此前的 scoped bootstrap 引用改写与原子写回。

新增 `scripts/verify-enhanced-reload-port-conflicts.py` 通过生成的原生 Go 静态库和头文件编译一个独立 Swift 程序，对普通生成配置、自定义配置两种输入形态直接调用两条生产重载路径共用的 cgo 入口。14 个场景涵盖成功、DNS 对代理/自定义 listener/API/TLS，以及 API 对代理/TLS 的冲突。拒绝时断言文件字节和权限不变；成功时断言独立 DNS、DoH、API 地址保留。此脚本只操作自己的临时 YAML，不启动完整 App、核心或 Helper，也不绑定网络端口；它不等同于完整 AppDelegate UI 重载流程的动态测试。

```sh
python3 scripts/verify-enhanced-reload-port-conflicts.py --bridge-directory /path/to/generated/goClash
```

最终验证结果：

- 前轮已经失败的 P2 反例不修改测试即可在新实现通过：固定 DNS 端口与代理端口同为 49634 时正确拒绝。证据 `p2-green-test.log`；前轮红色结果保留在独立复查目录的 `port-collision-probe.log`。
- Go：30 个顶层测试、66 个测试及子用例，0 失败、0 跳过。其中本轮新增 8 个顶层回归测试，覆盖普通生成式/自定义重载、六种代理端口字段、API/TLS、有效/无效及重复端口、保留端口即使空闲也不得选取、成功引用迁移，以及拒绝时原文件字节/权限/目录不变。定向执行也保留上一轮的独立本地 DNS 实解析回归。
- 最终原生 Go c-archive、完整 App/Helper 的隔离构建，以及独立 Swift/cgo 的 14 个场景全部通过。最终源码与构建副本逐字节一致；没有启动 App GUI，未对运行中核心发送控制请求。Swift 调用层沿用已存在的两条重载路径，本轮无需修改它们。
- 仅临时构建命令使用 `MACOSX_DEPLOYMENT_TARGET=14.0` 适配本机 Xcode 27；仓库发布配置仍为 10.14，未做 10.14 实机或本机 GUI 重载测试。
- 工作区忽略的 arm64 `goClash.a` / `goClash.h` 已同步为最终生成产物，旧工作区产物保存在本轮验证目录。没有手改生成头文件。
- 安装的 App、Helper、核心文件 SHA-256，进程 PID/启动时间，`scutil --proxy` / `scutil --dns` 输出在验证前后完全一致。

证据目录：`/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-dns-port-conflict-fix-4kco2ic5`，主要文件为 `go-final-tests.jsonl`、`test-summary.json`、`archive-final-build.log`、`final-app-build.log`、`final-reload-bridge.log` 与 `before.json` / `after.json`。独立 Swift 测试夹具目录记录在桥接日志中。

复跑 Go 回归：

```sh
python3 ClashFX/goClash/run_core_tests.py --run 'Test.*(DNS|Bootstrap|Retarget|Loopback|P2|ConfiguredProxy)'
```未安装、替换、重启或发布应用，未操作本机系统代理、DNS 或 TUN。


## 2026-10-17：新子代理独立复查 P2 修复

全新 Luna 子代理 Heisenberg 未参与前述修复及复查，独立核对当前生产代码、三条调用路径、测试及本地固定 Mihomo 1.19.24 源码。父代理核验原验证日志对应的源码/桥接产物，并以临时纯 Go 配置测试复现其发现。此轮没有修改生产代码或生成产物。

### 新 P2：端口数字被当作全局冲突键，误拒绝可共存监听

`validateEnhancedListenerPortConflicts` 在 `main.go:722` 仅比较 API 与 proxy/controller 端口数字；`configuredProxyListenerPorts` 收集 `listeners[].port` 时丢失其绑定地址和传输协议。新增 API 对 proxy/controller 的检查因而会拒绝下面的配置，属于本次 P2 修复引入的回归：

1. 增强生成启动的普通 API 为 `127.0.0.1:19090`，而 TLS API 配置为本机另一地址（例如该机确实拥有的 `192.168.1.20:19090`），且证书、密钥有效。Mihomo 的普通 API 和 TLS API 分别以自身地址调用 TCP Listen，可以在不同具体本机 IPv4 地址上共用端口；新校验却只按 19090 相同拒绝启动。`lockEnhancedLanBinding` 不改写 TLS API 地址；既有 RuntimeEndpointSet 不检查 TLS API，因此这不是原有门控已经拒绝的情况。
2. 普通或自定义重载中，最终 API 为 `127.0.0.1:19090`，新增 `listeners` 的 `type: tuic`、`listen: 127.0.0.1`、`port: "19090"`（其证书和认证配置有效）。TUIC 实际以 UDP ListenPacket 监听，而 API 使用 TCP，两者可以共用端口。新 validator 将 TUIC port 当作 TCP proxy 冲突而在提交重载前拒绝。重载不重新应用 controller，但保留既有 API TCP 并启动目标 TUIC UDP 本不需要互斥。

本地 Mihomo 1.19.24 证据：`hub/route/server.go` 的普通/TLS API 分别调用 `inbound.Listen("tcp", cfg.Addr/TLSAddr)`；`listener/tuic/server.go` 调用 `inbound.ListenPacket("udp", addr)`；`listener/parse.go` 识别 tuic；`hub/executor/executor.go` 明确 ApplyConfig 不包含 ExternalController。

父代理的两个最小 map 测试分别要求允许不同 API/TLS TCP 地址、允许 TUIC UDP 与 API TCP 同端口。两项均按预期失败，返回 `[port_conflict] service=api_listener ... reason=reserved_listener`，证明新校验的误拒绝。测试没有启动任何监听、加载证书、运行核心或调用本机控制接口；Mihomo 的可共存语义来自上述固定版本源码，而非这台机器上的实际绑定试验。

三条路径在最终 API 写入顺序和生命周期取消门控上未发现此次绕过。原 66 个 Go 测试及子用例、14 个桥接场景没有覆盖不同地址和 UDP-only listener；此前通过不覆盖上述反例。后续需按传输协议、实际绑定地址/通配地址覆盖关系和端口判断冲突，并给这两类合法配置增加回归，再验证三条路径。

本次复查结论：尚不能判定 P2 修复完全通过；只记录发现，不继续修复。证据目录 `/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-p2-independent-review-df6wt8fc`，其中 `counterexamples.log` 是预期失败的两项反例，`prior-evidence-audit.json` 是原验证证据核对。`before.json`/`after.json` 和 `source-before.json`/`source-after.json` 对比完全一致：本机 App、Helper、核心的进程/安装文件及系统代理、DNS 未变，生产源码/生成产物未变。无发布、替换、安装、重启或网络修改。


## 2026-10-17：地址与协议感知的监听冲突修复

针对独立复查确认的误拦截，冲突模型改为保留监听协议、实际绑定地址和端口。API 与 TLS API 在不同具体地址上的同端口 TCP 监听、TUIC UDP 与 TCP API 共用端口应允许；同地址同协议，以及通配地址实际覆盖到同一端口的真实冲突继续拒绝。

生成启动的 API/DNS 端口分配与重载固定 DNS 端口校验均使用这一模型。自定义启动新增只读 cgo 校验入口，在后台准备配置时按原配置实际 DNS/API/代理地址校验，完成后才允许暂停当前核心；校验不改写自定义地址。Swift 的 RuntimeEndpointSet 仅保留端口范围与非空元数据检查，绑定冲突交给完整配置校验，避免数字门控重复误杀。

桥接回归脚本扩展为普通生成配置、自定义配置各 16 个输入场景，同时验证自定义启动的只读检查和重载端口改写。包含不同 IPv4/IPv6 地址、localhost/通配覆盖、TUIC UDP/API TCP、TUIC UDP/DNS UDP 等允许与拒绝场景；只操作临时 YAML，不启动这些监听或加载真实证书。

最终结果：

- Go：38 个顶层测试，101 个测试及子用例通过，0 失败、0 跳过。覆盖此前两项纯配置反例、真实冲突拒绝、地址/协议区分、范围/逗号端口、动态端口 0、不同具体地址的 reserved 集合、自定义启动只读检查及普通/自定义重载。端口范围在转换为 uint16 前做边界检查，避免 70000 被截断成虚假的 4464 端口。
- Swift 元数据与切换安全 XCTest：10 项通过，0 失败。端口清单不再用缺失地址/协议的信息判定绑定冲突，仍校验范围与必需数据。自定义启动在后台纯读校验通过后，才可能在主队列暂停当前核心；迟到结果仍受 deadline/settlement/generation 门控保护。
- 最终原生 c-archive 与生成头文件、完整 App/Helper 隔离构建通过；源码与验证副本逐字节一致。独立 Swift/cgo 验证普通、自定义配置共 32 个输入场景，每个场景同时核对只读启动校验与重载改写。无效场景拒绝且文件字节、权限不变，合法场景保留独立 DNS/DoH/API/TUN 配置。
- 独立复核最初提出显式 IPv4 wildcard 与 IPv6 服务的剩余误拦。父代理没有仅凭地址字符串或标准库 socket family 判定，而是在本机临时自动分配端口上验证：Go generic TCP `0.0.0.0` 虽可能开双栈 fd，Darwin 允许单独的 `::1` TCP 监听，分别 dial IPv4/IPv6 能到达各自服务；同类 generic UDP 组合则确实返回 EADDRINUSE。因此 TCP 的显式 IPv4 wildcard 保留 IPv4 绑定域，UDP 保留实际双栈占用保护；空 host / generic IPv6 wildcard 仍覆盖相应地址空间。新增纯配置回归区分这两种行为。
- 又通过固定 Mihomo 1.19.24 的 `adapter/inbound.Listen` / `ListenPacket` 实际入口重复临时端口验证，结果一致：IPv4 TCP 请求得到 IPv4 服务响应、IPv6 TCP 请求得到 IPv6 服务响应；UDP 同端口冲突得到 EADDRINUSE。只运行独立探针，没有启动核心、Helper、TUN 或 GUI，没有使用生产端口；所有临时监听均已关闭。此项验证限本机 Darwin，不等于跨系统或 10.14 实机验证。
- 独立复核已收束，未发现新的确切可操作问题。旧式全局 `ss-config` / `vmess-config` URL listener 未纳入新增端点预检，这是此前已有的覆盖边界，仍由 Mihomo 解析和监听处理；此次不宣称预检覆盖所有核心协议与旧式语法。
- 本机 Xcode 的构建命令仅临时覆盖部署目标为 14.0；源项目 10.14 设置保持不变。未做本机 GUI 冷启动/重载，不发布或替换安装应用。工作区忽略的 arm64 archive/header 已同步最终生成版本，旧文件备份在验证目录；未手改生成头文件。
- 最终安全快照中，App、Helper、核心的安装文件 SHA-256、PID/启动时间、系统代理和 DNS 输出与本轮开始完全一致。

证据目录：`/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-listener-endpoint-fix-if5cum_l`。主要文件：`review-counterexamples-green.log`、`go-final-tests.jsonl`、`test-summary.json`、`swift-gates-tests.log`、`archive-final-build.log`、`final-app-build.log`、`final-bridge.log`、`mihomo-listener-probe.log` 与 `before.json` / `after.json`。桥接日志给出独立 Swift 夹具目录。初轮桥接失败来自 IPv6 地址未加 YAML 引号的测试数据，修正后 32 项全部通过。

```sh
python3 ClashFX/goClash/run_core_tests.py --run 'Test.*(DNS|Bootstrap|Retarget|Loopback|P2|ConfiguredProxy|Endpoint|Listener|Protocol|Address)'
python3 scripts/verify-enhanced-reload-port-conflicts.py --bridge-directory /path/to/generated/goClash
```


## 2026-10-17：五个竞品的源码对照

本轮仅静态阅读官方仓库，不运行竞品脚本、核心或应用。固定下列源码快照；除 ClashX.Meta 核对到 v1.4.46 实际 tag commit 外，其余按所注明主线/HEAD 比较，不将开发主线行为泛化为全部发行版。ClashX.Meta 默认 master 仍是旧 ClashX，已切到实际 release/meta commit，避免比较错分支。

### ClashX.Meta — v1.4.46/meta / `732d923465a096493b23d898521df62e5ca95486`

初始 API/代理端口根据已占 TCP 端口选择，管理通信优先使用随机 Unix socket；首次下发和普通重载共用 ConfigOverride.composeConfig，提交成功后读回 /configs 并协调状态。系统 DNS 按网络 service 保存和恢复。该端口扫描仅含 TCP 数字，不能当作我们全部 TCP/UDP/IP 监听规则的正确性依据。

- [Unix socket initialization](https://github.com/MetaCubeX/ClashX.Meta/blob/732d923465a096493b23d898521df62e5ca95486/ClashX/General/ClashMetaConfig.swift#L93)
- [shared composition and readback](https://github.com/MetaCubeX/ClashX.Meta/blob/732d923465a096493b23d898521df62e5ca95486/ClashX/General/Managers/ConfigReloadManager.swift#L55)
- [per-service DNS backup/restore](https://github.com/MetaCubeX/ClashX.Meta/blob/732d923465a096493b23d898521df62e5ca95486/ProxyConfigHelper/MetaDNS.swift#L53)

### Clash Verge Rev — dev / `3b7bfa10fd9ab85a119de3d2dcc9e72330e3fa7a`

代理端口保存路径检查地址/协议/端口，排除当前核心自有监听，并处理 root 核心与普通用户进程之间 TIME_WAIT 导致的 bind 假冲突。只有已证明外部占用才选择会话 fallback，不改持久配置。端口更新以草稿事务、文件快照、核心校验/重启及失败回滚处理。其 fallback 的部分保留集合仍按数字过滤，不宜整套照搬。

- [owned binding exclusion](https://github.com/clash-verge-rev/clash-verge-rev/blob/3b7bfa10fd9ab85a119de3d2dcc9e72330e3fa7a/src-tauri/src/core/listener.rs#L194)
- [root TIME_WAIT caveat](https://github.com/clash-verge-rev/clash-verge-rev/blob/3b7bfa10fd9ab85a119de3d2dcc9e72330e3fa7a/src-tauri/src/core/listener.rs#L337)
- [transaction and rollback](https://github.com/clash-verge-rev/clash-verge-rev/blob/3b7bfa10fd9ab85a119de3d2dcc9e72330e3fa7a/src-tauri/src/feat/listener.rs#L31)
- [session fallback only proven conflict](https://github.com/clash-verge-rev/clash-verge-rev/blob/3b7bfa10fd9ab85a119de3d2dcc9e72330e3fa7a/src-tauri/src/config/port.rs#L32)

### Clash Party — smart_core / `6c1151f4cbdf4c713524b1410a9d485f2bf5ad19`

主线使用每用户/进程独立 Unix socket 管理核心，简易模式 DNS 默认 127.0.0.1:1053；启动与热加载共用 generateProfile。远程 profile 候选通过 -t 才保存；受控设置 PATCH 失败路径则保留新文件并标注下次重启生效，不能据此认为它对所有设置都有原子回滚。检查的路径未看到通用 DNS 端口自动移动与引用 retarget。

- [per-process Unix socket](https://github.com/mihomo-party-org/clash-party/blob/6c1151f4cbdf4c713524b1410a9d485f2bf5ad19/src/main/core/manager.ts#L402)
- [shared profile generation for hot reload](https://github.com/mihomo-party-org/clash-party/blob/6c1151f4cbdf4c713524b1410a9d485f2bf5ad19/src/main/core/mihomoApi.ts#L444)
- [simple DNS listener defaults](https://github.com/mihomo-party-org/clash-party/blob/6c1151f4cbdf4c713524b1410a9d485f2bf5ad19/src/shared/simple-config.ts#L156)
- [patch failure persists settings for later restart](https://github.com/mihomo-party-org/clash-party/blob/6c1151f4cbdf4c713524b1410a9d485f2bf5ad19/src/main/config/controledMihomo.ts#L160)

### FlClash — HEAD v0.9.0 release commit / `03f955382409a4a7ac1f3f92e46d9fcc6d39f106`

代理和 TUN 监听共用 updateListeners，配置校验主要调用内核解析。加载失败会尝试内置默认配置，可能没有代理节点；这和保留上一份可用配置是不同产品策略。检查的合成与监听更新路径未看到自动端口冲突回退。macOS 系统 DNS 有单独保存/恢复协调器。

- [shared listener update](https://github.com/chen08209/FlClash/blob/03f955382409a4a7ac1f3f92e46d9fcc6d39f106/core/lifecycle.go#L61)
- [fallback default on load failure](https://github.com/chen08209/FlClash/blob/03f955382409a4a7ac1f3f92e46d9fcc6d39f106/core/config.go#L110)
- [macOS DNS coordinator](https://github.com/chen08209/FlClash/blob/03f955382409a4a7ac1f3f92e46d9fcc6d39f106/lib/common/system_dns.dart#L150)

### Clash Nyanpasu — HEAD / `a4f706fe788e3570247ad2fa49636c6b4c55c98b`

端口提供 Fixed/Random/AllowFallback 策略，并将候选选择、应用回执和已确认运行绑定分开；策略未变时复用已确认绑定，避免把自己仍持有的端口当外部占用。运行配置经共同构建管线、核心 check 和 reconcile，只有核心确认成功才提升候选端口，区分未提交、未变化、已回滚及结果未知。检查到的 DNS 模块不应被泛化成与端口回退联动的系统 DNS 事务。

- [confirmed binding versus candidate](https://github.com/libnyanpasu/clash-nyanpasu/blob/a4f706fe788e3570247ad2fa49636c6b4c55c98b/backend/tauri/src/client/ports.rs#L92)
- [commit apply receipt only on confirmation](https://github.com/libnyanpasu/clash-nyanpasu/blob/a4f706fe788e3570247ad2fa49636c6b4c55c98b/backend/tauri/src/client/core_lifecycle/workflow.rs#L590)
- [isolated timed core config check](https://github.com/libnyanpasu/clash-nyanpasu/blob/a4f706fe788e3570247ad2fa49636c6b4c55c98b/backend/tauri/src/client/application_workflow/adapters.rs#L171)

### 对 ClashFX 的结论

1. 保持单一最终配置生成与端点规划；在同一会话中复用核心已确认的绑定，只在确定的外部占用下做回退。端口回退只影响会话运行配置，不悄悄修改用户原始配置。
2. 将源配置、候选运行配置、核心确认后的运行事实分开。借鉴 Verge 的事务和 Nyanpasu 的 apply receipt，核对 UI、运行端口、系统代理/DNS、文件持久化在失败/未知结果下是否一致；保留最后已验证配置。
3. 完整语义校验使用独立的固定版本核心测试进程；客户端端点检查只负责其明确的地址/协议/端口范围。Mihomo 1.19.24 main.go:149–164 的 -t 分支解析后返回，不启动监听，所以它不能替代端口实际绑定、API/DNS 协议与数据面就绪检查。
4. Unix socket 本地管理通信可作为后续架构选项，减少管理 API TCP 端口依赖；HTTP 控制端仍按 dashboard/远程访问需求单独保留。此项需考虑 ClashFX 的 10.14 兼容与现有网络库，不在本轮直接照搬。
5. 保留本轮真实 Mihomo/Darwin 监听回归。竞品 Rust/socket 探测与 Go 核心的 bind 选项不一定完全一致；上游做法是设计参考，不替代我们自己的兼容性验证。

上述比较是静态源码证据，不是竞品运行稳定性的实测排名，也不把已检查路径中未出现某逻辑写成全仓库绝对不存在。没有修改 ClashFX 产品代码、生成产物或当前运行环境。研究数据位于 `/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-competitor-research-8vp3r9zl`，其中 competitor-findings.json 和 repositories.json 保存固定提交与证据链接。

## 2026-10-17：确认端口、配置事务与分层验证

本轮将竞品调研中的三项做法落实到配置路径：

- 同一增强核心重载采用已确认的 API/DNS 端口，不对自己占用的端口重新探测或随机分配；新核心启动将上次确认的端口作为优先候选，确认外部占用后才回退。普通和自定义重载共用最终配置校验，保留显式代理端口以及 DNS 引用的作用域。
- 候选配置先冻结为私有目录中的不可变快照（目录 0700、文件 0600、SHA-256 摘要）。只有应用、运行态回读与分层检查完成后才提升为确认状态。明确失败会重新应用同一核心作用域的旧快照并验证；超时或无法确认的写入进入未知状态，不并发发送回滚，也不继续提交新配置。
- 核心启动代次与排队重载绑定；解析、应用和提交快照由同一核心锁串行化。生命周期变化取消传输和验证进程，迟到回调不能确认替换后的核心。切换前刷新可观测的手动模式等标量设置，保留旧路由图；API 不回传的自定义监听信息不会被误当作缺失配置。
- 结构/地址/传输协议冲突检查后，独立进程以 `-t` 解析配置。它使用私有 HOME、工作目录、临时目录和缓存路径，不启动代理/DNS/TUN 监听。随后再验证实际通用监听端口、运行模式；增强模式还检查核心监听归属、TUN 和 DNS UDP/TCP 响应。数据通路健康、外网不可用和未检查分别记录，不将语义验证通过等同于网络可用。
- 增强模式启动预检在暂停内置核心之前完成。启动失败恢复冻结的内置配置检查点，避免重新读取已经被编辑的源配置而改变旧路由图。

验证使用临时源码副本、临时 Go 模块覆盖以及无特权、禁用 TUN/DNS 的回环核心；不调用本机正在运行的核心控制 API。新增 `scripts/verify-runtime-config-transactions.py` 通过实际 HTTP 代理访问回环 204 服务，并制造真实监听占用，确认 API 接受但监听未生效时能够识别并回滚。暂未进行真实增强模式的 GUI/系统网络变更验证，保持用户要求的运行环境隔离。

后续独立复查补齐了边界：所有五类通用端口（含 redir/tproxy）都必须与运行态回读一致；代理监听之间也执行同一地址/协议/端口范围检查。自定义监听按 Mihomo 的弱类型名称解码和最后同名覆盖规则去重，避免把不实际创建的监听当成冲突。核心暂停请求在发布门禁时取消旧代次；配置/TUN 写入与缓存关闭遵循缓存锁再核心锁的顺序；旧暂停请求在执行前核对代次，不能关闭已经恢复成功的新核心。

确认后的 API/DNS 数字端口单独保存为跨启动偏好；只有验证完成才更新，读取时检查范围并强制设为未持有状态，新核心仍检查可用性。手动 Selector 的实际选择在切换前捕获，目标配置的有效记忆选择在数据通路验证前恢复，回滚严格恢复旧选择并回读。外部探测站点被规则屏蔽、超时或要求代理认证，均不能据此认定配置无效：分别记录未确认可达或未检查，不将其标记为健康。

最终自动化覆盖包括 47 项 Swift XCTest、78 个顶层 Go 测试（含子用例 188 项）、32 个启动/普通与自定义重载 Swift/cgo 场景，以及真实回环代理的端口占用与回滚。完整隔离 App/Helper 构建采用本机 SDK 所需的 macOS 14 编译覆盖；工程最低部署版本保持 10.14，新增 Foundation 工具另外通过 10.14 目标类型检查。真实 TUN/系统 DNS 切换未运行，仍作为发布前的独立人工验收项。

本轮新建的两位独立复查代理分别复查 Swift 事务集成与 Go 核心边界；提出的问题修正后均已再次检查，最终在所复查范围内没有剩余可执行问题。最终安装应用、Helper、批准核心的二进制摘要和进程启动时间，以及系统代理/DNS 快照均与工作前完全一致。仅刷新工作区内忽略的桥接归档、生成头文件和支持 `-t` 的核心（旧文件已备份），没有发布、替换应用、重启现有进程或修改系统网络。

## 2026-10-17：新增整体独立复查

另起全新上下文的代理审查端口复用、配置回滚与分层验证。并行隔离核对发现并复现了待重启 IPv6 偏好造成的正常配置误拦截：内置桥接器重载时沿用核心启动时的 IPv6 会话值，候选却拿新偏好作回读期望。修复后，内置重载从新鲜确认快照保留会话 IPv6，设置偏好仍在下次启动时生效；HTTP/外置核心路径不受此归一化影响。

新增 `scripts/verify-runtime-session-settings.py`，在两个私有 HOME、独立进程、动态回环端口、禁用 TUN/DNS 的真实 cgo 核心中验证两个 IPv6 偏好变化方向，同时检查实际端口、回读和提交快照一致。两例均通过；新增 XCTest 后 48 项相关回归通过，新增策略工具通过 macOS 10.14 目标类型检查，源码匹配的隔离 App/Helper 编译通过。整体独立复查仍在进行；本段不提前代表复查结论。

### 整体复查修复与复核

新代理指出并经源码、实核用例确认的其他问题也已修正：

- 普通和自定义重载统一强制应用全局监听设置（嵌入式 `ApplyConfig(..., true)`、HTTP `PUT /configs?force=true`）。不变的监听仍由 Mihomo 复用；显式端口或地址变化会生效。回读检查与回滚基线刷新均包括 `bind-address`，避免把旧的更宽绑定当作新配置成功。
- 同名自定义监听替换失败时，先移除已经关闭的旧注册项，清理未成功启动的替换实例。按期望名称和配置核实实际成功注册的监听；嵌入式启动/重载和外置核心启动/重载都采用该检查。确定的监听失败以 HTTP 400/桥接错误返回，事务据此恢复旧配置，不能误确认或只进入不明状态。
- 上游部分监听器在失败后 `Close()` 会解引用尚未创建的传输。仅对失败后的清理调用隔离 panic；原始启动错误仍拒绝候选。真实 TrustTunnel 构造失败回归验证进程存活、旧确认快照不变、同名旧监听恢复后可以连接。
- 自定义 DNS 的探测地址从冻结配置提取，启动、普通/自定义重载和复核使用一致目标。特定接口地址保持原值；通配地址映射到相应 IPv4/IPv6 回环；有界 DNS 查询支持 IPv6。补充真实 Mihomo 无 TUN、静态 hosts 响应的 IPv4/IPv6 UDP/TCP 隔离验证，未查询外部 DNS，也未更改系统 DNS。

相对 provider 预检误拒的静态怀疑被排除：真实捆绑 `-t` 在相对 file provider 文件存在和不存在时均通过，因为该路径不初始化 provider。加入实际 CLI 回归保持此兼容性；未为这条不成立的判断改动隔离资源策略。此前假 shell 用例只证明隔离目录行为，不能代表 Mihomo 的解析结果。

新代理已对最终修改再次进行只读复核，在本轮审查范围内未发现剩余可执行问题。最终验证结果及运行环境对比见本轮证据目录（`/tmp/clashfx-overall-independent-review-path`）；所有测试核心均为私有 HOME、动态回环端口的独立进程。

本轮最终结果：81 项 Swift XCTest、81 个顶层 Go 测试（含子用例共 193 项）、32 个 Swift/cgo 启动及普通/自定义重载合约场景全部通过；真实 HTTP、嵌入式 cgo 的端口/地址变更、普通与命名监听失败回滚、TrustTunnel 清理崩溃保护、IPv4/IPv6 DNS UDP/TCP 用例均通过。最后生成的归档和核心用于完整隔离 App/Helper 编译，源码摘要与构建输入一致；新增策略/DNS 工具及依赖通过 macOS 10.14 目标类型检查。完整构建沿用本机 SDK 所需的 14.0 临时覆盖，工程部署目标不变。

最终系统代理/DNS、应用/Helper/核心进程与启动时间、已安装二进制摘要均与本轮新基线完全一致。仅备份并刷新工作区忽略的生成归档/头文件/核心；未发布、安装或替换本机应用。未进行真实 TUN 与系统 DNS 切换，仍保持隔离验证范围。证据索引为 `/tmp/clashfx-overall-independent-review-path`。

## 2026-10-17：再次边界复查

本轮由新的 Go、Swift 只读代理分别检查，父代理以隔离实核和竞态检测确认问题后修正。

- **UDP 部分绑定失败误报可用。** 真实用例复现了仅 UDP 端口被占用时，HTTP PUT 返回 204、回读仍有代理端口，但 TCP 已关闭。SOCKS/Mixed 改为 TCP/UDP 同时成功才登记；启动、直接桥接及强制 HTTP 重载共享完整监听检查。混合端口启动也检查 UDP，管理 API 仍按 TCP 判断，避免误拦合法跨协议复用。
- **特殊监听与交接残留。** SS/VMess/TUIC 全局服务加入确认检查，URL 服务加入共享冲突模型；停止内置核心时一并关闭命名监听、URL/QUIC 服务及内部 TUN，再关闭 API/DNS 和缓存。真实套接字用例验证释放、回滚和重新启动。
- **多地址构造失败泄漏。** SS、VMess、TUIC 构造器在后续地址失败时关闭已经创建的资源；修复 VMess 命名返回变量被 goroutine 捕获后置 nil 的问题，以及关闭时空数据缓冲区的释放。Darwin TProxy 不支持的 socket 配置失败也会关闭刚绑定的 TCP/UDP 套接字，避免 Redir 的可选 UDP 尝试留下占用。
- **正常配置兼容性。** TUIC 按上游构造器的超时、CWND、报文大小默认值归一化后比较和复用，真实健康服务可以通过。命名 IPv6 TCP 先绑定时，通用全局 TCP 可保留 IPv4 服务；仅对此已验证的顺序放宽静态冲突判断，UDP 和管理 API/TLS 仍保持独立严格检查。
- **回读与恢复状态。** 回读身份包含核心会话、传输、核心代次和配置事务代次。事务回滚后迟到的同 profile 回读也无法发布。每次基线确认前清除凭据，成功才记录 receipt ID；预检/准备失败只有匹配本次新鲜凭据才能重新验证，并先发布该基线端口，不能重新信任旧 `currentConfig`。内置检查点恢复失败会先停止并隔离核心，再标记停止。
- **HTTP 并发与迟到写入。** PUT/PATCH 在读取请求体前捕获生命周期凭据，解码后按请求锁、缓存生命周期锁、核心锁、配置锁顺序执行。应用与监听确认保持原子，PATCH 和配置读取使用相同配置锁；保留原有 embed-mode 写入限制。慢请求跨核心代次后不得解析/应用。CLI 在配置确认后才开放管理 API。
- **PATCH 失败处理。** 基本监听失败返回 400 并恢复原 LAN/绑定地址与端口，在此之前不提交模式/日志/IPv6。未提供 SS/VMess 字段时不从 JSON 回读重构 URL 服务，避免模式切换意外关闭它们。LAN 偏好只在 2xx 后提交，日志级别也正确分类非 2xx。
- **访问控制数据竞争。** 定向 `-race` 复现了活跃监听读取免认证/访问控制前缀时，重载替换切片的竞争。现在加锁发布一份复制后的前缀状态，读取也同步，getter 不泄露可变底层数组。

最终 88 项 Swift XCTest、91 个本地顶层 Go 测试（含子用例 216 项）、7 个上游 HTTP 顶层回归（含子用例 9 项）通过；合计 Go 225 项用例。相关构造/UDP/访问控制与 HTTP 并发回归使用 `-race` 重复三轮通过。32 个启动/普通/自定义重载桥接场景、真实 HTTP/cgo 回滚、显式地址/端口变更和 IPv4/IPv6 DNS UDP/TCP 验证通过。完整隔离 App/Helper、核心、桥接归档编译通过；工程最低部署版本未改，完整构建继续使用本机 SDK 所需的临时 14.0 覆盖，纯策略/控制器通过 10.14 目标类型检查。

复核中的测试假设也已纠正：空证书 TUIC 可自动生成证书，负例改用明确无效的证书；整体预检超时可能早于子进程启动，测试仅在进程实际启动时检查其退出。通用 IPv4/IPv6 绑定并不总互斥，失败回滚用例采用确定的具体地址冲突，另保留允许合法共存的原始套接字正例。

新代理对修正再次只读复核，在本轮已检查范围内没有剩余可执行问题。源码摘要与最终隔离构建输入一致；本机应用/Helper/核心的进程、启动时间和二进制摘要、系统代理与 DNS 均和本轮基线完全一致。仅备份并刷新工作区内忽略的生成产物，没有发布、安装、替换应用或切换真实 TUN/系统 DNS。证据索引：`/tmp/clashfx-final-boundary-review-path`。新增 HTTP 回归可通过 `python3 ClashFX/goClash/run_core_tests.py --run '.' --runtime-http` 在私有测试 HOME 下重现。


## 2026-10-17：新代理整体复核及失败路径补齐

本轮由全新上下文的 Luna 代理 Rawls 独立检查整体实现，父代理负责复现、整合与隔离验证；Darwin 在不重叠的文件范围修复 PATCH。最后 Rawls 对修复再审，在本轮限定范围内未发现剩余可执行问题。

- **PATCH 失败的部分提交。** 监听失败前已提交的访问前缀、sniffing、TCP concurrency、interface name 及 TUN 元数据改为监听确认成功后提交；仅在明确请求 TUN 时更新。失败批次通过 `enable:false` 的 MTU/device 变化复现和验证，没有创建系统 TUN 设备。健康的 disabled TUN 元数据更新仍可成功。
- **附加监听回滚与恢复顺序。** 保存 SS/VMess 的原始 URL 和 TUIC 原配置，失败时只恢复请求涉及的附加服务，未请求的服务保持原样。先关闭候选基本/附加监听，再恢复旧拓扑并检查实际监听，避免新 SS 占用旧 mixed 端口导致反向恢复自冲突。新增实际 HTTP 回归覆盖基本 UDP 冲突、附加服务失败、批量设置不提交、跨端口恢复及未请求服务保留。若恢复时旧端口已被外部占用，会返回含恢复失败的错误，不报告恢复成功。
- **失败启动的资源残留。** 私有子进程复现了 HTTP 监听冲突后 API、mixed TCP/UDP、缓存锁仍存活且 mutation gate 仍 active。现在数据监听和管理端点都确认后才提交启动快照；失败时在生命周期/核心锁内清理监听、关闭缓存并隔离后续写入。回归检查端口与缓存可重用、失败不发布快照、更正配置后可正常启动。
- **管理 API 启停竞态与错误确认。** 新启动重试测试的 `-race` 复现了上游异步 start/stop 同时访问 server 指针。固定版本 overlay 改为串行同步创建和关闭 endpoint，仅 Serve 异步执行并持有自己的资源；TLS 在绑定后的校验失败也释放套接字。新增 HTTP/TLS/Unix 快速启停、失败清理及健康重试验证。API 与 mixed 共用 TCP 端口时，API bind 失败现在传回启动层，不再提交成功快照。

最终隔离验证：88 项 Swift XCTest、93 个本地 Go 顶层测试（含子用例 220 项）、11 个上游 HTTP 顶层回归（含子用例 16 项）全部通过，合计 Go 236 项。生命周期、启动失败、管理端点、构造器、UDP/访问策略及 HTTP 并发回归使用 race detector 重复三轮通过。最终重建的桥接归档和核心用于真实 HTTP/cgo 配置切换与回滚、IPv4/IPv6 DNS UDP/TCP、32 个启动/普通/自定义重载契约场景，全部通过；完整隔离 App/Helper 编译成功。工程最低部署目标未改，完整构建仍仅在临时副本使用本机 SDK 所需的 14.0 覆盖。

24 个关键源码与临时验证副本摘要一致。工作区忽略的生成归档、头文件与核心仅在备份后更新；本机已安装 App/Helper/核心的文件摘要、PID/启动时间和系统代理/DNS 与本轮开始基线完全一致。未发布、安装、替换本机应用或提交/推送；未执行真实 TUN 与系统 DNS 切换。证据索引 `/tmp/clashfx-fresh-overall-review-path`，本轮证据目录为 `/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-fresh-overall-review-1cgv7w_s`。


## 2026-10-17：启动清理、API 与 PATCH 的新一轮独立复核

新上下文 Luna 代理 Pascal 只读检查上一轮新增的启动失败清理、管理 endpoint 生命周期和 PATCH 回滚，父代理并行验证并修复发现的边界。最终限定范围内无剩余可执行问题；TUN 清理遗漏的疑点已通过核对 `listener.Cleanup()` 排除，未作多余更改。

本轮修复一个 **Go/C 并发启动边界**：旧启动失败时，清理代码推进生命周期 generation，使已排队的较新启动也因 token 过期被取消。隔离测试复现后，失败清理改为只设置 suspended 位；显式 suspend 仍推进 generation。`withOpenRequested` 在等待锁前保留入口 token，拿锁后按 generation 准入，并用完整当前 state 完成最后的激活检查。这样较新启动可在旧失败清理后继续，显式暂停仍能取消排队或正在启动的请求。

新增通道控制的确定性回归覆盖“较新排队启动继续且缓存可写”和“显式 suspend 仍取消”，不依赖 sleep。将临时副本切回旧准入/失败行为时，新回归准确失败；恢复修复后通过。此问题在无线程约束的 Go/C 入口可构造；独立代理尚未找到当前大多由主线程串行调用的 App 用户流程中的明确并发触发路径，因此将其归为入口状态机边界修复，不宣称已复现日常 UI 故障。

最终 94 个本地 Go 顶层测试（含子用例 223 项）、11 个上游 HTTP 顶层回归（含子用例 16 项）通过，合计 239 项；相关生命周期/排队启动/API 和 HTTP 竞态套件重复三轮通过。88 项 Swift XCTest、32 组桥接契约、重建核心与桥接归档上的真实 HTTP/cgo 事务、IPv4/IPv6 DNS UDP/TCP、完整临时 App/Helper 构建全部通过。25 个关键源码与构建副本摘要一致。

只备份并刷新工作区忽略的生成产物；本机 App/Helper/核心 PID、启动时间、已安装文件摘要及系统代理/DNS 与本轮基线完全一致。未发布、安装、替换应用、提交或推送，未执行真实 TUN/系统 DNS 切换。证据索引 `/tmp/clashfx-startup-api-patch-review-path`，目录 `/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-startup-api-patch-review-oyjriwur`。

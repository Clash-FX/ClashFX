# 独立 macOS Helper/TUN 发布验收

日期：2026-10-12（Asia/Shanghai）。最终结果：按用户限定的真实 Helper/TUN 后端验收范围，通过。未安装或发布 Lab。

## 新批准客户端与核心信任设计的后续验收

2026-10-14 更新夹具以覆盖 `ProxyConfigHelperTrustPolicy.h` 的批准客户端/核心信任设计。下方 2026-10-12 的运行记录属于此前候选版本，不能作为新信任设计已通过验收的证据；新夹具尚待一次新的 GitHub-hosted macOS 验收运行。

夹具要求 Helper protocol version 6。它为 `ProtoProbe.app` 和 `TxDriver.app` 分别复制相同的 `mihomo_core` 到各自的 `Contents/Resources/`，完成 ad-hoc 签名后通过 `codesign` 读取各自的 40 位小写 CDHash；`TxDriver.app` 必须先完成签名，随后才把 CDHash 写入收据。它在 `/Library/PrivilegedHelperTools/com.clashfx.app.Helper.trust.plist` 写入 SchemaVersion 1 收据，收据只批准这两个确切 CDHash，并为每个条目绑定对应 bundle 的资源路径和相同的 64 位小写 core SHA256。它把唯一可执行核心安装到 `/Library/PrivilegedHelperTools/com.clashfx.app.Helper.mihomo_core`；核心和收据均要求 root 所有、无任何写权限、带 `UF_IMMUTABLE`，父目录要求 root 所有且无 group/world 写权限。可选的 `installApprovedMihomoCore` 方法用于已授权的生产签名客户端；临时 ad-hoc 客户端不满足该方法的 Developer ID 要求，因此夹具在托管 guest 中直接构造并验证测试收据。

Helper 启动后，夹具还会尝试让同一 `com.clashfx.app` Bundle ID、但 CDHash 未列入收据的 ad-hoc 克隆访问 XPC，并要求 Helper 拒绝。核心运行期间，夹具用进程文本映射检查实际可执行文件是上述 root immutable 核心；Helper 状态中的 `binaryPath`/`sourceBinaryPath` 只作为状态证据，不替代进程路径检查。运行前若 Helper、root 核心或收据路径已存在，夹具会在任何系统修改前拒绝运行；结束时卸载 Helper、停止核心并移除本次创建的核心与收据路径。

该入口仍只接受新鲜的 GitHub-hosted macOS runner 和 root 权限。不要在开发机运行特权验收、launchd、安装或 TUN 步骤。`--help` 与 Python 语法检查可在本机执行；本次更新没有运行 hosted 验收，也没有把此前通过记录外推到新信任设计。

## 用户授权与隔离

本次仅补真实 Helper/TUN 的启动、恢复、失败回滚；按用户要求不处理正式 Release 包及 macOS 10.14 兼容性认证。宿主正在运行的 ClashFX、Helper、核心、系统代理、DNS、TUN 和默认路由禁止修改。

无现成虚拟机/远程 Mac 配置，因此采用 GitHub-hosted macOS 临时运行器。候选源码复制到独立临时 Git 仓库，再提交到 `codex/helper-tun-acceptance-20261012` 测试分支；原工作区保持未提交，不合并、不打标签、不发布。未上传本地规划目录、个人日志或未提交诊断文档；临时快照只覆盖候选源码、测试和验收工作流。

宿主只编译了 XPC 客户端、生产 Helper 和生产事务客户端，未执行这些产物。运行脚本在本机返回 `status=refused`，在任何系统服务/配置动作前拒绝非托管环境；没有伪造 CI 环境变量或绕过 UID 检查。

## 实际验收入口

- `.github/workflows/helper-tun-acceptance.yml`：仅匹配临时测试分支，权限只读，不含发布步骤；直接构建真实 Helper 与 Mihomo，不构建正式 App 包。
- `scripts/run-hosted-helper-tun-acceptance.py`：要求 macOS、GitHub-hosted 标识、标准 runner 路径、root，以及无既有 ClashFX/Helper/core；使用生产 Mach service 和 launchd 模板，最终核对并清理本次进程、接口和设置。
- `scripts/helper-tun-acceptance-client.m`：符合生产 Bundle 路径/标识的 ad-hoc 客户端，经过真实 XPC 授权与协议，不链接假 Helper。
- `scripts/helper-tun-production-transaction.swift`：链接实际 `SystemProxyManager` 和 `ClaudeProxyLockTransaction`，真实 XPC Core/代理操作；无效配置和 SCPreferencesLock 注入触发生产回滚，检查提交次数、旧运行配置和代理检查点恢复。

## 验收矩阵

最终已通过：

- 真实 root Helper 的 XPC 协议、进程与监听归属。
- Helper 启动真实 TUN 核心，核对 API、utun、自动路由、UDP/TCP DNS 以及端口所有权。
- 停止/重新启动与无效配置退出；旧进程终止、新 launch/PID 成立。
- 生产事务成功、实际 runtime 失败后回滚、SCPreferences 写入冲突后回滚。
- 系统代理逐服务捕获/启用/恢复；系统 DNS 真实覆盖及恢复。
- 最终代理/DNS/路由对照基线、无残留测试进程或 TUN 路由、测试 launchd job 已卸载。

## 运行记录

第一轮 [38249716895](https://github.com/Clash-FX/ClashFX/actions/runs/38249716895)，候选 `9d1a06c2509ef084ad7c4329e88de6ac9f37136e`：Helper 构建成功，Go 依赖下载遭遇 HTTP/2 INTERNAL_ERROR，尚未运行特权验收。调整仅涉及下载传输与有上限重试。

第二轮 [38250189880](https://github.com/Clash-FX/ClashFX/actions/runs/38250189880)，候选 `a7a0736b40ec5208850dd2e81c22c7128746ae3f`：真实 Helper/TUN 启动、监听归属、UDP/TCP DNS、系统代理与 DNS 覆盖/恢复成功，清理成功。事务客户端因运行器传入 `--fixtures` 而自身要求 `--manifest` 拒绝执行，尚未覆盖回滚，因此整轮失败。

第三轮 [38251015933](https://github.com/Clash-FX/ClashFX/actions/runs/38251015933)：事务阶段要求空闲 Helper，而前阶段的本轮测试核心仍在运行，客户端写出拒绝报告；无期限的 RunLoop 阻止客户端退出。修复测试阶段交接和显式完成循环。路由检查保留默认路由、接口、下一跳及全部原始观察，对带 WASCLONED 的临时主机缓存允许退回相同转发路径，仍拒绝残留 utun 路由、不同网关/接口、REJECT/BLACKHOLE 和静态路由丢失。

第四轮 [38252245665](https://github.com/Clash-FX/ClashFX/actions/runs/38252245665)：真实生产事务成功、无效配置回滚、SCPreferencesLock 冲突回滚全部通过；外层夹具错误地把“成功事务后的开启代理检查点”与“测试启动前的关闭状态”混为一谈。修复仅区分事务恢复与整个套件的退出恢复，不修改生产事务代码。

最终 [38252765807](https://github.com/Clash-FX/ClashFX/actions/runs/38252765807)，候选 `6ed5254e1c6216c7086b3e00732f14cf89282ed7`：所有步骤成功，下载的主报告 35 项断言与生产事务报告 8 项断言均通过，合计 43 项，无失败。

## 最终证据与结论

`report.json` 和 `production-transaction.json` 均为 `status=passed`；事务 `controlPassed=true`。真 XPC Helper 运行于 root，Mihomo 版本 1.19.24；utun 具有 198.18.0.1、自动路由成立、控制器/代理/DNS TCP+UDP 监听由当前 launch 的真实 PID 拥有。无效配置的实际进程退出且未就绪；回滚启动旧良好配置的新 PID，并恢复准确代理检查点。SCPreferencesLock 用例经过实际 Helper 写入路径产生失败，随后解锁、恢复运行配置和检查点；两项失败均未增加设置提交次数，`restorationErrors=[]`。

退出阶段通过真实 Helper 停止核心，系统代理和 DNS 恢复到开始快照，TUN 接口/测试路由移除、默认转发路径恢复，测试 launchd job 卸载，没有测试进程残留。报告中的原始路由前后哈希可以因临时 WASCLONED 缓存到期不同，原始差异保留，不声称全部路由缓存逐字节一致。

原工作区的既有 tracked diff 及候选未跟踪源码逐字节保留。宿主 App PID 70829、核心 PID 71936、Helper PID 70845，以及系统代理、系统 DNS、默认路由 SHA256 与开始时完全一致。测试只在独立托管 Mac 改变网络状态。

原始证据目录由 `/tmp/clashfx-hosted-acceptance-baseline/workspace.txt` 指向，最终报告在其 `fifth-artifacts/`；工作流日志和不可变 SHA 也作为云端证据保留。仅临时测试分支产生提交，当前用户工作区没有提交、合并、tag 或发布。

按 2026-10-12 旧候选范围，真实后端验收阻塞当时已补齐；这项历史结论不覆盖新批准客户端/核心信任设计，也不能单独作为当前 Lab 发布就绪证据。新夹具在新鲜 hosted macOS 运行通过前，仍需完成本设计的后端验收。旧结论同样不扩展到下面未覆盖的 GUI、安装授权和物理硬件动作。正式包及最低系统兼容性按用户指示当时未认证。

## 覆盖边界

客户端执行真实后端及生产事务组件，完整 Cocoa AppDelegate/GUI 没有启动。SMJobBless 安装授权 UI、物理外屏/电源热插拔、真实 Helper 关闭报错及调用者取消场景不会被此脚本伪称为已覆盖。事务级 DNS 仍由 AppDelegate 负责；脚本单独验收真实 Helper DNS 覆盖/恢复，不将其当作完整 GUI DNS 回滚。

本机基线和候选清单在 `/tmp/clashfx-hosted-acceptance-baseline` 指向的临时工作区。当前 App PID 70829、核心 PID 71936、Helper PID 70845；宿主代理/DNS/默认路由摘要会在结束时重新核对。


## 2026-10-17 hosted runtime acceptance (historical progress; completed below)

User authorized a temporary GitHub branch and hosted Mac, using gh account mixc6763-prog. Candidate 5ee6959b58e559fd832d3a62dad9bfd2c9647657 on codex/helper-tun-acceptance-20261017-runtime-49f069. Current run https://github.com/Clash-FX/ClashFX/actions/runs/39035375810. No release/install/app replacement.

New backend coverage: three actual Helper/core stop-start cycles with PID, TCP/UDP and TUN route release checks; production RuntimeConfigTransactionController with six config switches, real local HTTP204 proxy forwarding and UDP/TCP fake-IP DNS, distinct syntax/semantic rejections, TCP/UDP conflict rollback and failed PATCH preserving TUN/policy. System DNS override includes actual macOS resolver lookup and fake-IP route evidence, followed by exact settings restoration. Complete GUI/AppDelegate and SMJobBless authorization UI are not covered.

Independent fixture review strengthened DNS A-record/CIDR parsing and question matching; pure wire-format checks, local compilation and refusal guard pass. First run39034835683 canceled during compile; run39035110126 failed before privileges because hosted dyld rejected Go1.22 CLI test without LC_UUID. Run39035293564 canceled, acceptance toolchain aligned with locally validated Go1.26.1; module version unchanged. Current run pending, no historical pass is reused.

Evidence /var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-hosted-manual-acceptance-8n7rf8i7; pointer /tmp/clashfx-hosted-manual-acceptance-path. Host process/binary/proxy/DNS baseline preserved.


## 2026-10-17：当前修复的托管 macOS 真实后端验收完成

最终运行：[39038046967](https://github.com/Clash-FX/ClashFX/actions/runs/39038046967)，候选 `cdf94d566b2484b44b2f5eb5f0d2c2949254792a`，分支 `codex/helper-tun-acceptance-20261017-runtime-49f069`。使用用户指定的 mixc6763-prog 账号；原工作区没有提交、合并或打 tag，也未创建 Release。

| 场景 | 结果 | 实际证据 |
|---|---|---|
| 核心冷启动 | 通过 | 新鲜托管 Mac 上运行真实生产 Legacy 安装脚本、协议 6 Helper、批准客户端与 root immutable 核心；API、TUN、路由及 DNS 就绪 |
| 连续配置切换 | 通过 | 生产 RuntimeConfigTransactionController 连续六次切换 mode/log-level，每次确认端口复用、本地 HTTP 204 代理转发及 UDP/TCP fake-IP DNS |
| 失败回滚 | 通过 | 语法与语义错误均在 apply 前拒绝；真实 TCP/UDP 端口占用触发回滚并恢复原 receipt/端口/DNS；失败 PATCH 不提交候选 TUN 和访问策略 |
| 快速启停 | 通过 | 三轮实际 Helper 核心 stop/start，旧 PID、TCP/UDP 套接字与 TUN 路由释放，新 launch/PID 及监听归属成立 |
| 真实 TUN/DNS | 通过 | 系统 DNS 覆盖为 198.18.0.2 后，dscacheutil 对唯一域名取得 198.18.0.8；路由证据指向当前核心的 utun4，随后 DNS 设置精确恢复 |
| 生产事务与退出恢复 | 通过 | 无效运行配置及实际 SCPreferencesLock 冲突触发生产回滚；系统代理/DNS 恢复，测试接口/路由、进程、launchd job、Helper、核心与信任收据均清理 |

主报告 106 条断言、运行时配置报告 25 条、生产事务报告 8 条，共 139 条全部通过；生产事务 controlPassed=true。托管 Go/API/PATCH 回归、Swift/cgo 会话与 32 组启动/普通/自定义重载契约用例也通过。路由恢复按转发路径与持久路由规则检查，允许临时 WASCLONED 缓存到期，不声称所有内核路由缓存逐字节一致。

此前失败均已保留证据并修正验收夹具：托管 dyld 与旧 Go 测试程序不兼容（验收改用已验证的 Go1.26.1，go.mod 不改）、桥接支持头文件漏打包、macOS Python 无 os xattr API、Swift 生成安装脚本去缩进，以及 Swift 默认 JSON 的斜杠转义不被 Mihomo YAML 读取器接受。最后一项已通过真实核心只解析检查复现并修复，保留 CIDR/URL 编码回归。未因此修改本轮 ClashFX 运行逻辑。失败托管任务也分别验证了其已创建资源的清理。

本轮是真实后端场景验收，完整 ClashFX GUI/AppDelegate、SMJobBless 授权弹窗和完整事务级 DNS 回滚没有被假称覆盖；最低 macOS 版本也未重新认证。系统 DNS 覆盖/恢复与生产核心/代理事务分别验证。

最终下载的三份报告均为 status=passed。429 个候选输入摘要与工作区源码一致。本机 App/Helper/核心 PID、启动时间和文件摘要，以及 scutil 代理/DNS 与本轮开始基线完全一致；未在本机安装、启动测试 App/Helper、替换应用或改变网络配置。

证据索引：`/tmp/clashfx-hosted-manual-acceptance-path`；目录与最终 artifact 路径见该目录的 `final-artifact-directory.txt`。临时分支保留供审阅，无发布步骤。

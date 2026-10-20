# 隔离验证与 issue 236 / 247 复核（2026-09-24）

## 验证范围与安全边界
审查工作区现有增强模式修复（8 个修改文件），保留其他 agent 的未提交更改。本轮没有修改生产源码、发布或评论 GitHub。

- XCTest 仅构建并运行无宿主的 ClashFXTests；生产 AppDelegate、Settings、Helper 均不链接，网络通过 URLProtocol 拦截。155 项通过，0 失败。
- Go 定向覆盖 DNS 选择/改写、UDP 占用、默认端口、URL-test 选择和 tolerance、TUN stack：10 个顶层测试通过。
- 真实 Mihomo + 生产菜单集成：1 项通过。使用临时独立 home、随机 loopback 端口、本地 HTTP 代理和 origin；TUN/DNS/订阅更新关闭，无特权 Helper。夹具进程和端口已清理。
- Swift frontend parse 通过（只代表语法，不代表完整应用编译）；Objective-C Helper 在 macOS 10.14 deployment flag 下语法检查通过。首次 clang 缺少 modules 参数，补上 -fmodules 后通过。
- git diff --check 通过。
- Xcode 27 的测试命令仅临时覆盖 deployment target 为 12.0，项目 10.14 配置未改。不声称完成 macOS 10.14 真机验证。

前后运行中 App PID=1443，核心 PID=1693；进程启动时间、系统代理、系统 DNS 及 /Applications 内 App 和核心二进制 SHA-256 全部相同。完整 App 构建/链接、特权 TUN 启停和物理换网不在本轮覆盖内。

## 增强模式修复仍有需要处理的缺口

### P1：DNS 查询成功标志仍不能证明当前核心拥有监听
AppDelegate.swift:4070 的探测只检查事务 ID 和 QR 位。隔离提取该生产函数，给它一个不属于 Mihomo 的临时 TCP+UDP DNS 服务器，服务器返回 SERVFAIL（RCODE=2）及零 Answer，函数仍返回 true。与当前核心关联的监听归属/绑定结果没有验证。因此原先“别人占了 DNS 端口而误判就绪”的问题未闭环。注意 SERVFAIL 可以证明服务器回应了报文，却不能证明解析成功，更不能证明回应者是本次启动。

建议将“本次核心绑定成功”“DNS 协议服务就绪”“上游解析健康”分开。通过 Helper 提供当前进程/launch 身份及监听归属或可靠的本轮绑定状态，验证 UDP/TCP；明确处理响应码，并正确读取 TCP 长度帧，避免单次 recv 的分片误判。用故意占用端口的独立服务器做反例测试。

### P1：取消配置重载可能永久不完成
AppDelegate.swift:1458 的 generation/active/termination 不匹配时直接 return，未完成调用者 callback。updateConfig 在启动时设 isConfigUpdating=true，只在 reloadCallback 中清理。增强模式重载生成期间发生关闭/恢复，使 generation 变化，就可能留下更新锁，之后配置更新一直被拒绝。

建议取消也必须完成一次可识别的 cancellation 结果，通过事务身份避免旧结果改动新状态；增加“生成中关闭/恢复/退出”交错测试，不只测试 identity 函数本身。

### P1：关闭流程末尾仍未验证会话身份
AppDelegate.swift:3986 的 group.notify 等待 DNS/Helper 后无 generation 或 isTerminating 校验，仍可执行 startProxy 和重载。若等待期间退出或切换到更新的生命周期，旧关闭回调可能重启内置核心/覆盖新状态。Helper 排队不等于客户端事务隔离。

建议给关闭事务也携带身份，尾部和嵌套回调验证，且明确完成/取消语义。用可控 Helper 回调模拟迟到回复；这些测试应运行真实协调逻辑的依赖注入版本。

以上是代码审查和隔离反例发现；155 项全绿不能说明真实 AppDelegate 的所有生命周期回调都经过验证。当前测试目标刻意不链接生产 AppDelegate，新增两项测试主要覆盖纯策略函数。

## 证据位置
- 安全快照和 DNS 反例程序：/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-safe-review-o5jahli5
- XCTest 日志：/tmp/clashfx-safe-review-xctest.log
- XCTest 结果：/tmp/clashfx-safe-review-derived/Logs/Test/
- Go 日志：/tmp/clashfx-safe-review-go.log
- 真实核心夹具：/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-real-core-menu-l1csv5s4/


## Issue 236：需要解释语义和小幅交互优化
已只读获取最新回复：https://github.com/Clash-FX/ClashFX/issues/236#issuecomment-5810826242 。

100 ms 是上次观测值，不是可以持续使用的性能档位；现在测得 200 ms，继续显示 100 ms 不会让连接更快。HTTP 探测给出延迟，不是带宽。旧值暂时指导选路只是因为没有新证据，不能优先保留历史最小值而忽略当前状态。url-test 按当前候选延迟及 tolerance 选路；fallback 主要按配置顺序选择第一个可用候选，不能笼统解释为按最低延迟选路。菜单展示仍应服从 Mihomo fresh now。

重复点击已被拒绝：AppDelegate.swift:4796 全局会话保护，ProxyGroupSpeedTestMenuItem.swift:111 自动组本地保护。截图反映行仍会高亮，造成“可再点”的错觉，不能据此认定请求并发。

建议最小优化：保留 AppKit menu tracking，增加自定义视图 busy 状态，测速期间文字变淡、不高亮，鼠标/键盘重复激活不产生新请求；结束、取消、失败时只由匹配会话恢复。不能直接粗暴改 NSMenuItem.isEnabled，因为代码已有关闭菜单跟踪风险说明。无需为了这个反馈恢复定时全节点测速，也无需改变历史值/自动选路算法。

测试应覆盖 Selector 与自动组重复点击、跨组全局忙碌、取消后重试、旧结束回调及菜单保持展开。真实菜单跟踪体验最后仍需人工验证。

可回复（仅草稿，未发送）：
“100 ms 是上一次测速时的观测值，不是节点固定拥有的速度。现在测得 200 ms，继续保留旧数字也不会让实际连接恢复到 100 ms；新测速是为了发现网络变化和节点失效。自动选择依据核心的新测量及容差，故障转移则按配置顺序选择可用节点。测速期间重复点击目前不会新增任务，但按钮仍高亮确实容易误解，我们会优化忙碌状态的显示和交互。”

## Issue 247：有实际代码风险，当前补丁未完整解决
链接：https://github.com/Clash-FX/ClashFX/issues/247 。issue 没有诊断报告/评论，不能确认报告者当时的实际端口占用者。

当前源码能解释随机备用端口的一条路径：
- AppDelegate.swift:3431 起启动配置改成 .enhanced_config.<UUID>.yaml。
- AppDelegate.swift:4400 的 cleanupMihomoCore 仍传 .enhanced_config.yaml；Helper:246 要求参数中包含该字面路径，因此不匹配新的 UUID 文件名。应用异常结束时遗留的核心会漏清理。
- AppDelegate.swift:379 附近先 updateConfig/startProxy，再 restoreEnhancedModeIfNeeded；后者才发起清理。Settings.enhancedMode=false 时这条清理路径甚至不执行。
- goClash/main.go:671 在用户 MixedPort 不可用时选择随机空闲端口。因此存在用户配置四位端口、实际运行五位备用端口的合理代码链；这不证明用户设置被永久改写。

修复建议：保留独立不可变配置，更新受限的 ClashFX 自有进程识别与崩溃清理（校验二进制、home、合法 UUID 文件模式，不能仅按进程名杀进程）；确保恢复自有端口前的清理有界完成，并覆盖增强模式已关闭但仍有残留核心的启动场景。区分用户期望端口与当前运行端口，备用端口不得回写用户设置；关闭增强模式后恢复用户端口并刷新菜单/系统代理。若端口确被其他应用占用，要明确解释，不能静默伪装成成功恢复。

测试：临时 fake Helper/port allocator 或无 TUN 的独立核心，覆盖 UUID 旧配置识别、旧核心退出前后端口恢复、真实外部占用、用户端口偏好不变、菜单及系统代理一致。不要在正在使用的核心上操作。

## 交付判断
隔离测试通过，但不能作为本轮增强模式修复已可发布的结论。优先补 DNS 监听归属、取消回调收尾、关闭事务身份保护及 UUID 残留核心清理；#236 交互改进可独立提交，#247 端口恢复与生命周期修复一起验证。无生产源码修改，无 GitHub 回复、提交或发布。

---

## 2026-09-24 修复执行补记

上文“仍有缺口/未完整解决”记录的是本轮修改前的审查状态。以下是随后实施的修复和本轮验证；不能据此宣称已完成真实 TUN 或发布验证。

### 已实施

- **DNS/代理端口就绪分层**：Helper 状态附带其当前托管进程的 PID、binary/config 路径及本轮日志；Helper 使用 lsof 列出该 PID 实际拥有的 TCP/UDP 端口。启动要求 API TCP、生成配置声明的代理 TCP 端口、DNS TCP、DNS UDP 都归属于同一 Helper 进程和本轮不可变配置，并有本 launch 两种 DNS bind 日志。期望代理端口未由本 launch 持有时，日志和失败提示会报告端口可能被其他应用占用，不会停止其他进程。DNS 探测验证事务 ID、响应标志、question 回显和 RCODE；TCP 使用两字节长度帧并循环读取完整消息。SERVFAIL/零 Answer 被记录为“协议有响应、上游暂不健康”，不会单独触发启动重试。
- **配置 reload 收尾**：配置生成、API reload 的 callback 通过 once gate 恰好完成一次；关闭、退出或 generation 变化时以取消错误完成并清理 isConfigUpdating/回调暂停状态。旧 reload 的迟到结果不能清理新事务。
- **关闭事务隔离**：close 持有 generation 与 close UUID；DNS/Helper 等待完成、重启内置核心、reload、syncConfig 和菜单/系统代理刷新前均验证身份。退出或新事务使旧回调取消，不能继续启动或覆盖状态。Helper stop 等待有界且 leave once；迟到 DNS restore 若碰到新 TUN launch 会按新 launch 重新应用 DNS。
- **启动顺序与 #247**：启动先等待 Helper 检查，随后有界清理 ClashFX 自有 .enhanced_config.<UUID>.yaml 进程及历史版本 .enhanced_config.yaml 残留，再启动内置核心并加载初始配置；不依赖 Settings.enhancedMode 才执行残留清理。Helper 同时校验真实可执行文件路径、-d home 和合法配置身份，不按进程名杀进程。普通核心启动遇到明确配置 MixedPort 占用时返回含端口号的错误，不再静默切随机端口；不会写回用户偏好。关闭增强模式后读取当前配置更新菜单及系统代理端口。
- **Mihomo 热重载**：本仓库绑定 Mihomo v1.19.24。其 /configs 更新调用 executor.ApplyConfig，会更新 DNS、proxy listeners 和 TUN；updateGeneral 不负责重建 ExternalController。因此标准配置 reload 保留当前 DNS listen/Loopback DNS 引用及已运行 controller 端口，TUN 仍强制为 enabled；不把生成器挑选的新 controller 端口误当成运行端口。Custom Config as-is reload 复制为新的 launch 文件，要求配置仍启用 TUN，并固定当前 DNS/API 端口后才应用。[ApplyConfig 源码](https://github.com/MetaCubeX/mihomo/blob/v1.19.24/hub/executor/executor.go)；[/configs 源码](https://github.com/MetaCubeX/mihomo/blob/v1.19.24/hub/route/configs.go)。
- **#236**：测速视图保持 NSMenuItem.isEnabled，busy 时灰显并取消高亮；鼠标/键盘重复激活都被拒绝。全局会话让其他组同步 busy；对应会话的正常结束、失败或取消清理视图，旧会话不能清除新会话状态。测试覆盖菜单继续跟踪、跨组点击、取消重试和迟到结束。

这些代码风险解释了可复现的随机备用端口路径，但 #247 缺少用户诊断数据，不能据此断言是报告者唯一根因。新版真遇到其他应用占用期望端口时应给出明确错误；不会杀外部进程。

### 本轮验证记录

- 全部 ClashFXTests：164 项执行、1 项跳过、0 失败。新增的 CoreLogGuardTests 覆盖 foreign launch 拒绝、API/DNS/代理 socket ownership、仅 UDP 监听、SERVFAIL 分层、question/QR 校验、TCP 任意分片、DNS reload 端口保持、配置取消/迟到完成及重叠关闭身份。
- #236 MenuIntegrationTests：worker 报告 19 项通过，覆盖实际生产菜单视图、跨组 busy、鼠标/键盘、取消和旧结束回调。菜单仍需人工确认真实 AppKit tracking 观感。
- Go 定向命令 python3 run_core_tests.py --run 'TestResolveConfiguredMixedPortNeverSilentlyChoosesBackup|TestEnsureDefaultProxyPort|TestEnhancedDNS'：通过。
- Objective-C Helper 在 macOS 10.14 target、-fmodules 下语法检查通过；Swift frontend parse 和 git diff --check 通过。
- 一次全量 go test ./... 仍有 3 个既有 URL-test/Darwin TUN 断言失败；本次端口选择定向测试通过。未把这 3 项归为本次修复。
- Xcode 27 的测试命令临时覆盖测试 deployment target 为 12.0；生产项目 deployment setting 仍是 10.14。无宿主 XCTest 不链接生产 AppDelegate，故以上策略测试不等价于真实生命周期自动化。
- 完整 App build 在当前 Xcode 27 下因 Pods target 的 10.14 deployment target 已低于该 SDK 支持范围（最低 12.0）失败；本轮没有为 production build 覆盖该配置。AppDelegate 做过 Swift parse，但完整生产 AppDelegate/Helper 链接构建仍未通过验证。
- 独立无 TUN 核心/菜单夹具通过，运行 Mihomo 1.19.24，临时 home、随机 loopback 端口、本地节点、TUN/DNS 关闭且无特权 Helper；PID 96170 及其监听器均已清理。

验证前/后快照分别保存在 /tmp/clashfx-issue236-247-before.json 和 /tmp/clashfx-issue236-247-after.json：两份记录中 App PID 1443（启动 Thu Sep 24 19:24:08 2026）、核心 PID 1693（启动 Thu Sep 24 19:24:14 2026，参数仍为安装版本旧共享 config）、完整 scutil --proxy、scutil --dns 及安装包摘要完全相同。App SHA-256 aac52f64ec44ad32c6c3419d06583209c90b475eb30db3c8f27ebb1ae48aece0；核心 SHA-256 581a179aa2e22f6edd5409b3fccd207960e7c44e9e61936bf43f6fea3fe87e77。夹具脚本另确认安装 App/Core PID 与代理摘要不变，临时核心和监听器关闭。

### 未验证项与发布前检查

- XCTest 仍是无宿主目标：它运行实际菜单视图、生产生命周期 coordinator 和策略，但没有实例化真实 AppDelegate/XPC Helper，也没有用 fake Helper 进程执行真实 PID 清理。因此完整 callback 编排和 Helper 进程匹配仍需要完整 App/Helper build 后的隔离集成测试。
- 端口分配器单测覆盖“用户端口空闲/外部占用”；未在真实 Mihomo 子进程上故意占用混合端口验证最终用户提示。
- 未启动真实 TUN、未切换物理网络、未修改系统 DNS/代理，尚需发布前在专用测试机执行 TUN 启停和换网恢复检查。
- XCTest 164 项执行、1 项跳过、0 失败，仍不能替代上面的构建、Helper、真实 TUN 和物理换网验收。当前状态不应作为可发布结论。

### GitHub 回复草稿（没有发送）

**#236**

> 100 ms 是上一次测速的观测值，不是节点固定的性能档位。现在测得 200 ms，保留旧数字也不会让连接恢复到 100 ms；HTTP 探测测的是响应延迟，不是带宽。url-test 根据当前候选延迟和 tolerance 选择，fallback 按配置顺序选择可用节点，实际选路仍以 Mihomo 的 fresh now 为准。测速期间重复点击原本不会创建第二个任务，但行仍高亮确实容易让人误以为可以再次启动；我们已加 busy 灰显并抑制鼠标、键盘重复激活。

**#247**

> 我们在启动顺序和端口冲突处理里找到一条可能造成随机备用端口的路径：UUID 配置的残留核心此前可能漏清理，且端口占用会被静默改为临时端口。已改为启动时只清理可验证为 ClashFX 自有、带合法 UUID 配置的核心；用户设置端口被其他进程占用时明确报告，不会杀其他应用，也不会把备用端口写回偏好。关闭增强模式后会重新同步配置、菜单和系统代理。由于原报告没有诊断信息，我们无法确认这就是该个案的唯一原因。


后续已修复完整编译/lint、Helper UDP解析和65535范围缺陷，166项隔离XCTest、20项Go测试及临时副本完整构建通过。发布工具链/特权TUN验收仍未完成。详见 docs/lab-release-readiness-2026-09-24.md 最新补记。

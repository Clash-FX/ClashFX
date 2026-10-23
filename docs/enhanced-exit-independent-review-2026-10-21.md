# 增强模式退出与检查点恢复独立复查（2026-10-21）

## 范围

在上一轮增强模式退出、失败重试、端口释放和检查点恢复修复上继续复查；启动全新独立子代理，父代理并行核对回归覆盖。没有启动或控制本机 ClashFX、Helper、核心；没有修改用户订阅、缓存、系统代理、DNS 或 TUN；没有打新包、触发 Actions、发布或替换应用。

## 已复现与修复

IPv6 正常配置被检查点回读误拦：增强模式期间更改 IPv6 偏好后，退出时新的内置核心使用新的会话设置。Go 的 updateConfigAtEpoch 将配置中的 IPv6 固定为当前 enableIPV6，而冻结的旧检查点仍带此前值。原恢复方法用旧值做 readbackError 比较，导致合法恢复被判失败并停核。

复现使用生产恢复方法抽取，依赖替身模拟既有 Go bridge 的 IPv6 固定契约。修改前测试报 session IPv6 mismatch falsely rejected a valid frozen profile；修改后，在恢复检查点中复用现有 preservingBuiltInSessionIPv6 策略，从新的 run/resume 元数据保留当前会话设置，其他代理、分组、端口、API 端点恢复逻辑不变。

新增关闭→开启、开启→关闭两方向场景，断言完整冻结路由图和分组仍在、新 API 端点仍在、不误停核。新增 missing-session-ipv6 负向对照，删除修复会触发原回归断言；已加入已有 startup-candidate-acceptance 验收入口，未触发工作流。

独立子代理另发现 P2：监听就绪检查最终失败后的回退分支在 startProxy 之前恢复了回调。如果启动失败或检查点恢复失败，停核状态仍伴随已恢复的回调；即使启动初始配置成功，也绕开了其他失败恢复分支要求的完整 profile 保护。

已移除这条直接 reopen/resume/start 分支，复用 resumeEnhancedModeCallbacksIfNeeded 和同一个 one-shot resumeGate：只有 checkedResumeBuiltInCore 成功恢复并验证完整 profile 后才恢复回调；启动失败、缺失完整检查点、自动恢复保护都保持隔离；combiningFailure 保留增强模式失败与检查点恢复的具体错误。没有改动端口冲突放行规则。

## 验证

- 生产 startProxy、完整 profile handoff/close/toggle、检查点捕获/恢复方法抽取回归通过。
- 双向 IPv6、冻结路由/分组/端点保留和缺失 IPv6 修复的负向对照通过。
- 既有首次启动、Remote→Local 和失败回滚回归通过。
- 新增实际 callback-resume helper 与实际 one-shot gate 方法抽取：启动失败/缺失检查点不恢复回调，完整 profile 成功恢复一次，自动恢复保护不调用 bridge；失败 gate 重复调用不重启核心，新显式 retry gate 可成功恢复一次，均通过。
- premature-callback-resume 负向对照能捕获提前恢复回调；readiness 调用点另做静态断言，禁止直接 resume/startProxy/reopen，只允许共用恢复入口。该断言不等于执行完整 launch 方法。
- readiness 的 Helper 捕获/后台探测门禁与自动恢复生命周期回归通过。
- Swift 与 Python 语法检查通过。

验证使用私有临时目录和内存中的核心/API/UI 替身；本轮未启动真实核心、TUN 或 GUI，也未重跑完整 Go 或打包流程。新的独立子代理确认 readiness 旁路已改为共同恢复入口，IPv6 归一化只对齐当前会话设置；本轮范围内未发现其他具体问题。子代理的源码复查与方法抽取测试不等于真实 App/Helper/TUN 手工验收。

小型日志、修改前源码和清单存于 `.planning/enhanced-exit-independent-review-evidence/`，不提交。

本机 App、Helper、核心 PID/启动时间与系统代理/DNS 哈希在本轮验证前后一致。

> 更新：已完成后续代码修复，完整诊断构建通过。最新结果见文末“后续修复与复验”；原始失败记录保留供追溯。

# Lab 发布门槛独立审查（2026-09-24）

结论：**当前工作区未达到 Lab 发布标准，不能发布。** 本结论基于独立复跑，不依赖上一位 agent 的完成声明。

## 确定的构建阻塞

1. AppDelegate.swift:476 给只读计算属性 activeConfigUpdateID 赋 nil。属性定义位于 :158，仅返回 configUpdateTransaction.activeID，没有 setter。完整编译报 cannot assign to property: activeConfigUpdateID is a get-only property。前面的 finish(id:) 已负责清除 coordinator 状态，应去掉非法赋值并确认收尾语义。
2. AppDelegate.swift:3728 在实例方法中直接调用静态 readProxyPorts(from:)。完整编译报 static member readProxyPorts cannot be used on instance of type AppDelegate。应使用 Self.readProxyPorts(from: root)。

以上是生产 AppDelegate 的真实类型检查错误，Swift parse 和无宿主单测均不能发现。临时副本的 SwiftFormat 会移动行号，编译日志对应 :488 与 :3740；本报告引用原工作区行号。

## 本轮独立验证

- 无宿主 XCTest：163 项通过，0 失败；显式跳过 RealCoreMenuIntegrationTests，后者单独运行。
- Go：通过 run_core_tests.py --run Test，在项目 shipping overlay 下全部 19 个顶层测试通过。上一轮原生 go test ./... 的三个失败不应混作本轮 overlay 测试失败；项目验证需使用正确入口。
- 独立真实 Mihomo + 菜单：通过；临时核心及监听器已清理。
- git diff --check：通过。
- 生产 App 完整编译：失败，见以上两个代码错误。
- macOS 10.14 发布工具链门槛：本机 SDK27 最低 deployment 为12.0，verify-release-compatibility.py --sdk 明确失败。不能修改发布最低版本来过门槛。CI 指定 Xcode26.6，但未提交的这批改动尚无对应的通过产物可验证。

## 如何隔离构建

将整个工作区用 APFS clone 复制到临时目录，在副本中构建，避免项目 SwiftFormat 脚本修改原工作区。仅诊断编译时临时设 MACOSX_DEPLOYMENT_TARGET=12.0、CODE_SIGNING_ALLOWED=NO，不作为发布产物，不启动该 App，也不替换 /Applications 中应用。两个源码错误在绕过本机 deployment 限制后仍然出现，所以不能只归因于 Xcode 版本。

## 发布前仍需完成

- 修复编译错误后，对最终同一份源码执行完整 App/Helper/core build 和隔离回归。
- 使用支持10.14的工具链构建发布架构，执行 --sdk 及 --app 兼容性门槛，核对包内 App、Helper、核心。
- 在专用测试环境验证真实特权 Helper 的监听归属/旧核心清理、增强模式启停、用户端口恢复、DNS 恢复、合盖及换网。当前无宿主/无TUN测试不能替代这些。
- 确认 #236 的真实 AppKit 菜单跟踪及键盘交互。
- 更新发布说明并按现有流水线完成签名/分发检查后再发布；本轮未发布或触发发布流程。

## 安全与证据

前后 App PID1443、核心PID1693及启动时间一致；系统代理、系统DNS、安装App及核心二进制摘要一致。本轮没有修改生产源码，没有启动真实TUN或调用生产Helper。

- 快照与隔离源码副本：/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-lab-audit-yfv2udt8
- 完整编译日志：/tmp/clashfx-lab-audit-build.log
- XCTest日志：/tmp/clashfx-lab-audit-xctest.log
- Go日志：/tmp/clashfx-lab-audit-go.log
- 真核心测试日志：/tmp/clashfx-lab-audit-real-core.log
- SDK门槛日志：/tmp/clashfx-lab-audit-sdk.log


## 补充源码复核

- Helper UDP 端口归属解析有确定缺陷（ProxyConfigHelper.m:331–335）：lsof -iUDP 会包含 connected UDP，输出形如 local:56653->remote:443；当前按最后一个冒号取端口，记录的是远端443。这不是本地绑定端口，应先解析箭头左侧并按本地endpoint校验，增加 connected UDP 与 IPv6 夹具。不能把当前列表当成准确的本地DNS UDP监听集合。
- 端口范围不一致：port_fallback.go:78接受65535，main.go:87的实际可用性检查却无条件拒绝65535，最后显示已被占用。这是确定的边界错误，应统一有效范围并验证。
- 次级风险待专项验证：MixedPort预检只有TCP；Helper崩溃清理按PID快照及二次路径匹配，但未保存进程启动身份。需要针对UDP冲突和清理期间新launch/PID复用完善验证，不将这些未执行的运行场景误称为已复现故障。

生命周期审查未找到另一个已确认的运行时阻塞；这不替代实际特权路径验收。两处完整编译错误已足以阻止发布，Helper端口解析应在本轮一起修复。


## 2026-09-24 后续修复与复验（替代前述源码阻塞结论）

已修复本次确认的代码问题：
- 删除对只读 activeConfigUpdateID 的赋值，交由 configUpdateTransaction.finish(id:) 统一清理。
- 实例方法调用静态 readProxyPorts 时显式使用 Self。
- 完整编译继续暴露 UInt8 DNS响应码与 -1默认值的类型错误，改为转成Int后记录。
- 完整构建的SwiftLint发现10参数函数错误，将Helper监听快照和本轮期望监听分成两个值类型；不关闭lint规则，不改变校验语义。
- 新增 ProxyConfigHelper/CoreSocketOwnership.h，由生产Helper和隔离测试共用。只读取数字本地监听端口，排除connected UDP的local->peer记录，拒绝非法/尾随字符端口；支持IPv4、IPv6和通配监听。
- Go的isAddrValid和checkPortAvailable均接受65535，与配置端口范围一致。增加真实空闲65535检查（占用时明确跳过，不操作占用者）。

复验结果：
-166项无宿主XCTest通过，0失败；新增3项Helper端口解析反例测试。
-项目shipping overlay下全部Go测试通过（当前20个顶层测试）；重新生成arm64 Go静态库及mihomo_core，均在临时源码副本内完成。
-完整App+Helper Debug构建及项目SwiftLint通过：/tmp/clashfx-release-fix-build.log末尾BUILD SUCCEEDED。包含重新生成的Go库/核心。当前工具链诊断构建临时设置deployment12.0、关闭签名、仅arm64；不是可分发Lab产物。
-Helper macOS10.14语法检查与git diff --check通过。
-前后运行进程/启动时间、代理、DNS及安装二进制摘要全部相同；没有启动或安装该构建，没有发布。

证据：
-工作副本、安全快照与之前diff：/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-release-fix-i1wvae2w
-XCTest：/tmp/clashfx-release-fix-xctest.log
-Go构建与测试：/tmp/clashfx-release-fix-go-build.log（保留一次Go拒绝覆盖旧fat binary的失败记录，随后使用新输出文件成功替换副本）
-完整构建：/tmp/clashfx-release-fix-build.log
-Helper语法检查：/tmp/clashfx-release-fix-helper.log

当前发布判断：上述源码编译、lint、UDP解析和65535边界阻塞已解决。仍需支持10.14的发布工具链、双架构/签名产物门槛及专用环境的真实Helper/TUN、用户端口恢复和换网验收；本轮不以临时deployment12.0构建替代这些。

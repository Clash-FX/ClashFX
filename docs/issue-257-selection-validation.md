# Issue 257：选择意图与实际选路

验证日期：2026-10-12（Asia/Shanghai）。来源：[issue 257](https://github.com/Clash-FX/ClashFX/issues/257)。

## 实现

- Selector 使用“手动”，URLTest/Fallback 的已知未固定状态使用“自动”，核心报告非空 `fixed` 时使用“优先”。短提示放在原节点显示区，完整路径和优先目标放在节点文字的悬停提示与 accessibility help。截断保留模式前缀。
- `fixed` 表示优先意图，实际节点和路径始终由新鲜核心 `now` 逐级解析。嵌套子组变化会传播至父组；显示不会把旧测速结果的叶节点当成当前选路。
- 自动组候选可以直接点击，通过 PUT 设置手动优先；有优先目标时显示一个“恢复自动”功能项，通过 DELETE 清除。恢复项预先创建并在菜单构建时附加，不从视图挂载回调插入。勾选始终指向当前 `now`，不会用 `fixed` 代替。
- 自动组候选移除会吞掉原生点击的历史子菜单；历史测量数据与延迟提示保持。既有测速模式、显示顺序设置和失败重试保留。
- PUT/DELETE 都有 10 秒请求期限，控制器的每个异步阶段也有期限。结果使用不回退缓存的 fresh GET 验证；有效快照即使未保留请求意图也会先显示核心真实状态，再报告问题。失败、重复、过期或 scope/core identity 变化不得保存选择记忆。
- 全局选择操作互斥，并与测速互斥；忙闲状态会立即刷新相关菜单。Selector 的成功选择仍保存到 App 记忆；自动组的优先状态由核心负责，组之间不强制同步。
- 旧核心缺少优先状态或使用非字符串 `fixed` 时保留组与现有路由显示，明确显示未知模式并保持只读。LoadBalance/Relay 不增加手动优先；隐式 COMPATIBLE 不可设置优先，显式 DIRECT 仍可选择。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| 无宿主 XCTest 全套 | 284 项执行：281 通过、3 项需要真实核心的用例跳过，0 失败 |
| 选择控制器隔离测试 | 19 项通过，包括原生 NSMenu 动作、恢复项显隐与菜单身份稳定、失败、超时、重复/过期回调、跨组及测速互斥 |
| 模型/解码测试 | 8 项通过：`fixed` 与 `now` 分离、嵌套路线、状态变更传播、未知路线、旧字段格式、Codable roundtrip 等 |
| 生产视图定向测试 | 10 项通过：当前叶节点、悬停及 accessibility、旧证据、历史测量、COMPATIBLE、LoadBalance/Relay |
| 独立 Mihomo 1.19.24 + 生产 overlay | 3 项真实核心集成测试通过；完整菜单测速与 40 节点调度原测试保持通过，新测试覆盖 URLTest/Fallback 的 PUT/DELETE、不可用优先节点的实际回退、父子策略组独立性 |
| 生产 App 编译及链接 | Debug / arm64 通过；未运行构建产物 |
| 既有 Proxy Lock 生产方法探针 | 19 项断言通过 |
| 项目与本地化 | pbxproj、五份 strings 校验通过；`git diff --check` 通过 |

真实核心记录输出 `REAL_CORE_SELECTION_VALIDATION_COMPLETE`，并对 UI 勾选及模型路径与新鲜 `/proxies` 的 `fixed`、`now` 做对应断言。夹具报告 `passed=true`、`runningAppUnchanged=true`、`fixtureCoreStopped=true`、`fixtureListenersClosed=true`；验证前后正在运行的 App/Core PID 与系统代理摘要相同。

可重复命令：

```sh
xcodebuild -workspace ClashFX.xcworkspace -scheme ClashFX \
  -derivedDataPath /tmp/clashfx257-derived \
  -destination 'platform=macOS,arch=arm64' test \
  CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0
python3 scripts/run-real-core-menu-validation.py
python3 scripts/verify-claude-lock-runtime.py
```

## 原有工作与边界

在 `/tmp/clashfx-257-baseline` 保存了任务开始前的相关文件、tracked diff 和状态。未 reset、checkout、stash、提交或发布。子代理的构建曾触发项目原有 SwiftFormat 脚本；无关文件的格式变化已按基线恢复，最终 App 构建使用临时 Pods symlink overlay 将 SwiftFormat 替换为 `/usr/bin/true`，避免再次影响原有工作。此前 #255/#258 的代码、设置和发布说明保持。

本机验证环境为 macOS 27 / Xcode 27。当前 SDK 不接受 10.14 构建目标，因此仅在验证命令中覆盖 deployment target 为 12.0；项目的 10.14 目标没有修改。尚未在 macOS 10.14 或 issue 所述 14.4 实机运行，验证构建不能当作符合最低版本的正式发布包。

未安装、启动或重启生产 App/Helper，未修改正在使用的系统代理、TUN 或 DNS。真实核心测试仅使用独立临时 home、localhost 控制器和本地测试节点。旧版缓存关闭/重开缺陷属于已有修复，此次没有额外修改 Go 核心。

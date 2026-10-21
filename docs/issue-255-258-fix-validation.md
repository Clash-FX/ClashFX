# Issue 255 / 258 修复与验证

日期：2026-10-12（Asia/Shanghai）。问题来源：[255](https://github.com/Clash-FX/ClashFX/issues/255)、[258](https://github.com/Clash-FX/ClashFX/issues/258)。

## 行为变更

- Proxy Lock 先验证配置与完整拨号依赖，随后捕获系统代理 checkpoint；核心和系统代理全部接受后才提交 Lock、Enhanced 和模式偏好。预检失败不会改动正在运行的核心。
- Enhanced 已运行时直接重载，保留当前控制端口、DNS/TUN 配置，避免额外的 Enhanced → 内置 → Enhanced 端口交接。
- 失败时恢复旧运行配置/模式、原 Enhanced 或内置核心状态，以及操作前逐网络服务的代理配置。系统代理 readback 成功后才恢复原保存快照及其有效标记。核心恢复失败也会继续尝试恢复系统代理，分别报告原始错误和恢复错误。
- 事务和现有核心 generation 一起约束回调；重复或过期回调不得提交状态。停止归属未确认时不得启动第二个核心。自动恢复和用户代理切换在事务期间不抢占它。
- 拨号校验检查全部可选组成员、嵌套组、provider dialer/override、include-all 展开及过滤；循环、缺失节点和无法解析的 provider 依赖会拒绝应用，输入配置不被修改。无法安全使用 MATCH relay 时，保留节点原有的安全拨号路径。
- 移除测速选项和显示顺序子菜单，以及视图挂载时的菜单插入。测速模式使用设置中的全局选项；新增显示顺序设置。原生失败重试项在菜单构建时附加，只在可重试时显示。排序仍只在打开菜单时应用，不改变核心选择。

## 已执行验证

| 检查 | 结果 |
| --- | --- |
| 无宿主 XCTest 全套 | 246 项执行；244 通过，2 项需要真实核心的用例跳过，0 失败 |
| 独立真实 Mihomo 1.19.24 + 生产 overlay | 上述 2 项单独执行并通过 |
| 提取生产 AppDelegate Lock 方法体、内存适配器 | 19 项断言通过；未使用真实 App/Helper/偏好或网络 |
| 主 App 编译及链接 | Debug / arm64 通过；没有启动构建的 App |
| 真正的 AppKit 菜单弹出 | 测试中弹出三轮，实际视图挂载，菜单项身份保持，未插入选项/排序菜单，未触发测速 |
| Storyboard / 项目 / 本地化 | App 构建包含 Storyboard 编译；项目及五份 strings 校验通过 |
| `git diff --check` | 通过 |

核心验证夹具报告 `passed = true`、`runningAppUnchanged = true`、`fixtureCoreStopped = true`、`fixtureListenersClosed = true`；验证前后正在运行的 App/Core PID 和系统代理摘要相同。

普通 XCTest 包含 8 项真实事务协调器测试、19 项系统代理隔离测试、22 项 Lock 策略测试和 31 项菜单测试。回滚注入覆盖核心失败、系统代理部分应用后失败、两种恢复失败、重复/迟到回调和失效事务。生产方法探针额外验证 Enhanced 原地重载、核心切换与恢复、停止归属未知时的隔离以及停止状态的恢复。

可重复命令：

```sh
xcodebuild -workspace ClashFX.xcworkspace -scheme ClashFX \
  -derivedDataPath /tmp/clashfx258-derived \
  -destination 'platform=macOS,arch=arm64' test \
  CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0
python3 scripts/verify-claude-lock-runtime.py
python3 scripts/run-real-core-menu-validation.py
```

主 App 构建使用临时 Pods symlink overlay，将 SwiftFormat 命令替换为 `/usr/bin/true`，避免构建脚本格式化用户原有未提交文件；其他 Pods 和构建脚本保持原样。

## 保留原改动与验证边界

开始前在 `/tmp/clashfx-258-baseline` 保存了涉及文件及原 tracked diff。修改仅叠加在本次相关文件上，没有 reset、checkout、stash、提交或发布；无关 tracked diff 保持原样。此前的发布说明及未提交功能保留。

本机 Xcode 27 已不接受 10.14 deployment target。以上构建/测试仅用命令行临时覆盖为 12.0，项目的 10.14 目标不变；这不能代替 macOS 10.14 实机运行验证。

未在正在使用的 Helper/TUN/系统代理上注入失败；隔离测试通过不能代替实机恢复验收。没有安装新 App、重启正在运行的 App 或发布 Lab。历史故障瞬间 7890 的 owner 仍不能由现有证据确定；本次避免不必要交接并完善失败恢复，不宣称已确认其历史占用者。

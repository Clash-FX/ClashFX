# Proxy Lock、自动恢复、测速与节点选择交叉验证

日期：2026-10-12（Asia/Shanghai）。本次保留此前所有未提交工作，仅在源码和隔离夹具中检查与修复，不操作当前运行的 ClashFX。

## 发现并修复的交叉缺口

1. **同地址重载的旧回调**：选择/测速世代此前只跟随 Enhanced 生命周期。同一 API 地址的内置核心配置重载及 Lock 原地重载可能沿用旧世代。新增交互 epoch，在重载、Lock 事务、退出、重启及控制实例切换时失效；配置同步同时校验配置名、API 地址、远程 UUID 与世代。配置文件准备和发送阶段也校验原始作用域。
2. **记忆恢复越过互斥**：旧恢复函数对所有历史组直接 PUT，包括 URLTest/Fallback，且发出后就解除重载标志。改为先获取新鲜快照，只恢复仍存在的 Selector 及合法成员，每组最后一条记忆生效、串行请求；失败/超时/取消后不继续写。重载等待记忆恢复、模式确认及有期限的配置读回，之后才允许新测速与选择。其他启动路径的记忆恢复也纳入保护。
3. **选择控件销毁提前释放操作**：菜单重建/拓扑变化使控件失效时，仍可能有 PUT 在途。保留操作所有者直到阶段回复或超时，不发布失效结果或保存旧选择。排队重载阻止新的选择，但允许当前请求完成读回并记忆；配置重载在选择或记忆恢复完成后执行，并有等待期限。
4. **自动代理写入越过 Lock 或切换**：自动 enable 在进入队列、快照捕获后、实际写入前都在 main 检查原始世代与实时资格，过期请求不再写旧端口。Helper 超时或 XPC 错误不等于特权写入结束；未确认写入隔离到实际 Helper 回复，期间拒绝新写入及 Lock 检查点，避免将未知状态作为可回滚起点。
5. **Rule 模式恢复递归重试**：Lock 恢复 Rule 失败后，配置同步可能再次发起恢复。此路径现在共用有上限的恢复机制、读回和取消处理，避免 PATCH/sync 无限循环。Lock 要求的 Rule 状态未确认时，不自动写系统代理。
6. **测速诊断作用域遗漏**：批量 inline/provider 请求现在附带准确节点、provider 和核心 ID，手动批量与单节点流程都先准备新鲜拓扑身份。会话固定开始时的核心作用域；作用域改变取消并拒绝旧诊断发布。查询须匹配当前作用域，数值诊断还必须匹配行上延迟，错误码须与 HTTP 状态一致；旧核心 503/504 信息仍兼容。
7. **控制实例及弹窗跨作用域**：本地重载不发送到远程实例。重载、Lock、选择/记忆恢复及手动代理操作期间阻止控制实例切换；启动恢复远程选择有期限地等待。Proxy Lock 弹窗使用有期限的新鲜快照，显示与提交前均检查原作用域，避免旧弹窗选择作用于新配置。

网络变化触发的客户端健康检查也在开始与新鲜回复后检查作用域和交互忙闲，避免将旧快照的组名/provider 请求发送到新实例。核心自身的自动健康检查仍由 Mihomo 决定；客户端测速不替核心虚构 `now`。

## 验证

| 验证 | 结果 |
| --- | --- |
| 无宿主 XCTest 全套 | 353 项执行：349 通过，4 项真实核心用例跳过，0 失败 |
| 选择/记忆/假 Helper 定向套件 | 56 项通过，包括 Selector-only 恢复、旧选择保留至请求结束、排队写入资格检查、Helper 超时隔离及真实回复解除隔离 |
| 独立 Mihomo 1.19.24 + 生产 overlay | 4 项通过：菜单测速与调度、自动组 PUT/DELETE 和实际回退、单节点认证失败诊断 |
| Proxy Lock 生产方法探针 | 19 项通过，实际 AppDelegate 方法与纯事务代码使用假依赖执行 |
| 交互生产方法探针 | 11 项通过：执行实际 `syncConfig`、Rule 恢复和切换资格代码；持续失败及通知风暴最多三次恢复，同地址重载与同 URL 远程 UUID 变化不发布旧回复，重载/排队/选择阻止切换 |
| 生产 App 编译/链接 | Debug arm64 成功；未运行产物 |
| 项目/本地化/空白 | pbxproj、五份 strings、git diff --check 均通过 |

第一轮测试因诊断查询的新作用域接口需要更新测试专用 API facade；随后选择用例暴露原夹具发出 DIRECT 请求后没有结束请求，旧的弱控件生命周期掩盖了这个问题。已补齐夹具回复和 autoreleasepool 检查，保留生产的在途操作保护；最终全套无失败，未取消或跳过这些用例。

日志：`/tmp/clashfx-cross-feature-tests-final.log`、`/tmp/clashfx-cross-feature-targeted.log`、`/tmp/clashfx-cross-feature-app-build-final.log`、`/tmp/clashfx-cross-feature-lock-runtime.log`、`/tmp/clashfx-cross-feature-interaction-runtime.log`。真实夹具报告：`/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-real-core-menu-_ruuepsk/result.json`，`passed`、`runningAppUnchanged`、`fixtureCoreStopped`、`fixtureListenersClosed` 均为 true。

可复现命令：

```sh
xcodebuild -workspace ClashFX.xcworkspace -scheme ClashFX \
  -derivedDataPath /tmp/clashfx257-derived \
  -destination 'platform=macOS,arch=arm64' -jobs 2 test \
  CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 \
  PODS_ROOT=/tmp/clashfx257-pods
python3 scripts/run-real-core-menu-validation.py
python3 scripts/verify-claude-lock-runtime.py
python3 scripts/verify-proxy-interaction-runtime.py
```

## Issue 236 回复中的后续修复

重复测速子菜单此前已删除，模式和显示顺序在设置中。最新失败/核心超时/不可用与旧成功参考分开，历史标记只用于旧成功；帮助菜单已有单节点测速诊断，受控原因、身份、地址、请求期限、耗时与 Core API 状态可以复制。本次进一步修复了批量诊断身份和旧作用域查询。详见 [诊断验证记录](issue-236-probe-diagnostics-validation.md)。

“中国-HY2-69”的旧 503 日志不足以确定认证、TLS、QUIC、DNS 或目标连通性原因。本次没有通过用户正在运行的核心重测该节点，也没有把本地认证失败夹具的结论套到该节点。

## 运行保护与保留边界

任务前基线保存在 `/tmp/clashfx-cross-feature-baseline`；没有 reset、checkout、stash、提交或发布。此前 #255/#258、#257、#236 和跨进程保护修改均保留。所有测试只使用独立偏好域、假 Helper、临时文件锁或 localhost 夹具；生产方法探针只链接 Foundation 与假依赖，不载入 App、Helper 或用户设置。

当前 App PID 70829、核心 PID 71936 和系统代理 SHA256 与任务开始时一致。没有安装、启动/停止真实 ClashFX，也没有修改当前 Helper、代理、TUN、DNS 或配置。最低版本实机和生产 Helper/TUN 操作未执行。项目保持 macOS 10.14；本机 Xcode 27 的验证命令临时覆盖到 12.0，构建产物不作为正式发行包。

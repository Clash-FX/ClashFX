# 跨进程运行控制与系统代理自动恢复

日期：2026-10-12（Asia/Shanghai）。修复本机安装版与 Xcode Debug 版在外屏/电源变化后持续争抢 7088/7890 系统代理的问题。

## 实现

- 启动迁移、图标写入、Helper 检查和核心启动之前，先取得每用户共享文件锁；安装路径、Debug/Release 构建和配置名称不影响锁位置。新版实例持有内核 flock 至退出，描述符 close-on-exec；不删除锁文件，防止多个 inode 导致双重控制权。异常退出由内核释放锁。
- 取得文件锁前后检查同 bundle 的其他运行实例，兼容不认识文件锁的已安装旧版；发现已有实例或锁错误即停止第二副本启动。被拒绝副本跳过共享偏好迁移、URL 操作及退出清理，不能恢复代理或停止当前核心。
- App 的 Helper 入口与 SystemProxyManager 的异步阶段再次校验控制权；无控制权的请求不能访问 Helper。获取快照过程中控制权丢失不会保存快照或继续 enable；SSID 暂停后不允许迟到 enable。
- 网络通知、唤醒、健康恢复、启动代理恢复及 SSID 恢复共用自动恢复控制器。0.75 秒合并通知，自动恢复直接应用所需代理，避免先关闭再启用的中间状态。显式用户操作和锁定事务仍按原有事务流程执行。
- 每个配置/端口/锁定作用域最多连续尝试三次，尝试间至少两秒；回调后等 0.25 秒并读回实际代理状态，校验 HTTP/HTTPS/SOCKS 启用、loopback 主机、端口和 PAC/自动发现覆盖，不把成功回调或残留端口当成状态确认。连续稳定匹配十五秒才允许清除旧预算；短暂匹配和自身通知不得刷新重试次数。
- 持续冲突时暂停自动恢复，已有菜单项显示原因且允许点击重试。未确认写入超过三十秒则暂停；取消、作用域变化和显式重试仍保留未确认写入的屏障，等待回调确认结束。晚到或重复回调不更新旧作用域。
- 图标保存先生成固定 512×512 的 1× bitmap，非正方形图源等比例居中，Lab 标记绘入同一 bitmap。避免图标表示依赖外屏 backing scale；DEBUG 仍不写 App bundle。原报告是模拟故障且细节 private，不能把这一加固宣称为已复现的 IconServices 根因。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| 无宿主 XCTest 全套 | 执行 334 项：330 通过，4 项真实核心用例跳过，0 失败 |
| 跨进程文件锁 | 9 项通过：临时目录、旧版预检查、两个副本竞争、独立进程竞争、进程结束释放、权限和 symlink 拒绝；不获取生产锁 |
| 自动恢复控制器 | 9 项通过：通知风暴、共享写入屏障、三次预算、十五秒稳定恢复、暂停/非 owner/未就绪、重复/迟到回调、超时及取消后重新请求 |
| 新增 Manager/实际代理读回 | 4 项通过：无控制权不触碰假 Helper/保存快照，捕获途中丢失控制权，暂停后禁止迟到 enable，拒绝未启用残留端口/外部主机/PAC 覆盖 |
| 图标 bitmap | 4 项通过：无效尺寸、2048 源缩减、非正方形比例、徽标真实像素变化；不调用实际 setIcon |
| 独立 Mihomo + 生产 overlay | 4 项真实核心测试通过，覆盖菜单测速、并发调度、自动策略选择/回退和单节点认证失败诊断 |
| Proxy Lock 生产方法探针 | 19 项通过 |
| 生产 App 编译/链接 | Debug arm64 通过；仅构建、不运行 |
| 项目与本地化 | pbxproj、五份 strings、git diff --check 通过 |
| 运行保护 | 当前 App PID 70829、核心 PID 71936 和系统代理 SHA256 与开始时一致；真实夹具退出、监听端口关闭 |

XCTest 初次运行发现徽标像素检查和取消后重新请求的冷却时序问题，已修正并通过最终全套。生产 App 后续读回悬停状态时触发 Swift lazy 属性的类型推断循环，已显式标注控制器类型，最后编译成功。没有掩盖或跳过失败用例。

记录：`/tmp/clashfx-loop-tests-final.log`、`/tmp/clashfx-loop-app-build-final.log`、`/tmp/clashfx-loop-lock-runtime-final.log`。真实夹具报告为 `/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-real-core-menu-43kh45u7/result.json`，包含 `passed=true`、`runningAppUnchanged=true`、`fixtureCoreStopped=true`、`fixtureListenersClosed=true`。

复现命令（从仓库根目录运行）：

```sh
xcodebuild -workspace ClashFX.xcworkspace -scheme ClashFX \
  -derivedDataPath /tmp/clashfx257-derived \
  -destination 'platform=macOS,arch=arm64' -jobs 2 test \
  CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 \
  PODS_ROOT=/tmp/clashfx257-pods
python3 scripts/run-real-core-menu-validation.py
python3 scripts/verify-claude-lock-runtime.py
```

`/tmp/clashfx257-pods` 是本机临时 Pods symlink overlay，仅将 SwiftFormat 命令指向 `/usr/bin/true`，其他依赖沿用仓库 Pods。生产编译通过这一覆盖避免项目现有格式化脚本改写无关工作；记录中的 SDK 覆盖不用于正式发行。

## 保留原有工作及限制

任务开始前的源码、strings、tracked diff 和运行摘要保存在 `/tmp/clashfx-proxy-loop-baseline`。没有 reset、checkout、stash、提交或发布；先前 #255/#258、#257 和 #236 测速诊断修改继续保留。前述测速诊断收尾见 [记录](issue-236-probe-diagnostics-validation.md)。

所有测试使用无宿主 XCTest、假 Helper、独立偏好域、临时文件锁或独立 localhost 核心；不会启动第二个真实 ClashFX 进行竞争，不触碰生产文件锁、Helper、配置、系统代理、TUN 或 DNS。App 仅编译，不运行或安装。

旧版本自身没有文件锁，不能强制阻止旧程序之后再次启动；新版启动预检查和恢复时的竞争检测保护新版路径。其他用户会话或第三方代理控制器不遵守此锁时，持续冲突由有上限的自动恢复处理；不能宣称新版能控制第三方进程。

本机为 macOS 27 / Xcode 27；验证命令暂时覆盖 deployment target 为 12.0，项目仍保持 10.14。最低版本实机和生产 Helper/TUN 操作受当前用户的运行保护约束，未执行。

# Issue #236：隔离 AppKit 菜单集成验证

日期：2026-09-19。

## 隔离范围

测试运行于无主 App 宿主的 `ClashFXTests` 进程。生产菜单源文件直接加入测试 target：`ProxyGroupMenu`、`ProxyMenuItem`、`ProxyItemView`、`ProxyGroupMenuItemView`、`ProxyGroupSpeedTestMenuItem`、`MenuItemBaseView` 和文本控件扩展。实际调用生产测速菜单 view 的 `didClickView()`，运行生产计划、executor、coalescer、presentation stores、通知观察者、展示解析与布局。

`MenuIntegrationSupport.swift` 仅为测试 target 提供设置、App 生命周期协调和 API facade。测试专用 ephemeral URLSession 使用 `MihomoMenuURLProtocol` 拦截全部请求，唯一允许的主机是 `mihomo-menu-fixture.invalid`；其他主机会直接失败，不会回退到真实网络。没有启动 Mihomo、监听端口、加载生产配置、安装 helper 或修改系统代理。

因此，这些测试验证真实 AppKit 菜单对象、标签、勾选图标及生产菜单动作，但不等价于启动完整 ClashFX 的桌面 UI 自动化。生产 AppDelegate、MenuItemFactory 和 Alamofire API facade 被测试边界替换；本次未验证操作系统弹出菜单的完整 tracking loop、真实代理网络或 macOS 10.14 实机。

## 场景与断言

| 场景 | 核心断言 | 结果 |
|---|---|---|
| 测速中刷新 | hold 两个去重后的 HTTP 请求；核心 now 更新后勾选变化，仍显示测速中；返回后原菜单项实例保持不变，延迟和布局正确 | 通过 |
| 取消后立即重测 | 取消后动作恢复、行不再卡在测速中；新一轮得到 42ms，再释放旧一轮的 999ms 响应，结果不被覆盖 | 通过 |
| 自动组重测 | 返回 A=20ms、B=80ms，但新快照 now=B；自动组子菜单勾选 B、组标题显示 B；嵌套行接收进度通知不崩溃 | 通过 |
| 历史与请求不可用 | 48 小时前 90ms 在刷新、重新构建菜单后仍显示为历史；401 不把节点误判为失败 | 通过 |
| 不同 URL | 相同节点在两个父组测得 90ms/180ms；实时通知与重新打开菜单均保持各自结果 | 通过 |
| 确定的探测失败 | Mihomo 503 探测失败替换上一成功值，但不改变父组 now 对应的勾选 | 通过 |
| 同名节点替换 | 保持节点名、修改核心 id；刷新后不再显示旧 90ms，勾选仍独立跟随 now | 通过 |
| 传统原生菜单分支 | 关闭 custom-view 渲染分支，检查真实 NSMenuItem 的 attributedTitle 与 state 更新 | 通过 |

## 本次发现与修复

第一轮测试在 `testAutomaticRetestUsesFreshNowRatherThanLowestDisplayedDelay` 中触发生产代码 `ProxyMenuItem.proxyInfoUpdate` 的 Debug 断言。原因是自动组进度对象 `AutomaticGroupBenchmarkPresentation` 与 `ClashProxy` 快照共用 `.proxyUpdate(for:)` 通知名；嵌套 Selector 行会收到进度对象，但原观察者要求对象必须是 ClashProxy。

修复为忽略此观察者不处理的通知 payload。进度继续由对应 presentation 观察者处理，核心快照仍负责路径和选中状态。修复后该回归场景通过。崩溃发生在隔离 XCTest 进程，不是正在运行的 ClashFX。

第一轮夹具还存在刷新完成回调中重入 XCTest wait 的问题，已经改为异步刷新并在外层等待刷新结束；这属于测试夹具问题，未修改生产刷新流程。

## 重跑方式

最终结果：8 项菜单集成测试通过；与原有测试合跑后共 130 项，0 失败。验证前后 ClashFX PID 均为 35483，Mihomo 核心 PID 均为 94503，`scutil --proxy` 输出的 SHA-256 摘要完全一致。未对运行中的 App 或核心发送控制请求。

```sh
xcodebuild -workspace ClashFX.xcworkspace -scheme ClashFX \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ClashFXTests/MenuIntegrationTests \
  test CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0
```

本机 Xcode 27 不接受 10.14 deployment target，命令仅覆盖验证目标，项目发布配置仍为 10.14。该命令不启动主 App。移除 `-only-testing` 参数可运行完整独立测试套件。

按本轮要求，到验证结束即停止，不提交、不推送、不准备或发布 Lab 测试包。

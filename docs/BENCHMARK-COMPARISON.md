# 手动延迟测速对比与 #147 修复

调研日期：2026-09-08。以下是源码行为对比，不是同订阅、同网络的实测排名。

## 竞品源码

| 项目 | 策略组列表测速 | 并发与失败处理 | 结果展示 |
| --- | --- | --- | --- |
| Clash Party | 对列表候选逐个调用节点 delay / Provider healthcheck | 默认 50，完成一个补一个；默认超时 5000 ms；没有整轮结束后的自动重试 | 200 ms 合并刷新 |
| Clash Verge Rev | 对列表候选逐个调用测速 | 参数默认 36，但实际限制为 10；滚动补位，最多 200 ms 启动抖动；无整轮失败重试 | 节点结果逐步更新，测量展示至少 500 ms |
| ClashFX（本次修改前） | Selector 优先显式重测选中的自动组，再测可比较的叶子节点 | 初始 8、最高 12，失败密集时降到 4；结束后最多重试 4 个失败节点，并发 2 | 结果合并刷新，重试节点要等第二次结束 |

已核对的固定版本源码：

- [Clash Party：列表请求池](https://github.com/mihomo-party-org/clash-party/blob/2a19b0226627b5796503b1556e583fa909485fee/src/renderer/src/pages/proxies.tsx#L345)、[API URL 与超时](https://github.com/mihomo-party-org/clash-party/blob/2a19b0226627b5796503b1556e583fa909485fee/src/main/core/mihomoApi.ts#L390)。
- [Clash Verge Rev：实际并发和节点测量](https://github.com/clash-verge-rev/clash-verge-rev/blob/f754ee53a0b25ed3b115f978838947455cacecef/src/services/delay.ts#L270)。

这些是调研时的分支快照，不应等同于反馈用户安装的版本。客户端请求数量也不等于内核内部实际探测并发。

## 本次采用的优化

1. 删除 Selector 整轮结束后的失败重试。成功、失败均立即结算；用户需要时可重新点击测速，避免少量离线节点追加两批超时等待。
2. 维持滚动并发 8–12，不再仅因失败多降到 4。节点不可用不能单独证明本机拥塞；暂不照搬 Party 的 50 并发，避免在旧机器和较差网络上放大争用。
3. 复用同一次操作中自动组已经测得的成功叶子结果。必须同时匹配 URL、超时、默认状态码语义、直接成员、节点名以及 Provider/inline 身份。不同 URL、自定义 expected-status、嵌套组路径、失败及历史缓存均不复用。
4. 保持 Mihomo 新鲜 `now` 的权威性。比较测速不会用最小延迟擅自改写自动组选路；需要重测自动组时仍使用该组的 URL 和 expected-status。
5. 保留取消与会话身份检查、别名去重和合并刷新，不按每个结果重建整个菜单。

全局叶子测速原先就是固定 8 并发且不自动重试；本次 Selector 优化不代表全局入口也存在相同重试问题。

## 菜单与退出问题

- 整体淡化来自 `5016df809` 引入的过期展示（30 分钟后 alpha 0.65），以及 `b457b44e0` 中自动组的同类处理；不是“测速不可用”触发的网络禁用。本次移除整行透明度和文字变灰处理，保留结果状态及其时间戳，不改变节点可选性。
- 系统代理操作改为等待整个异步操作完成后再开始下一项；退出期间停止新启用和网络恢复请求。正常退出不再在恢复后二次关闭代理，恢复完成后读回检查原设置，失败保留快照并取消退出，供重试。

## 验证边界

自动测试覆盖复用的匹配/拒绝条件、并发补位和上限、异步代理操作串行与重复回调、PAC/开关位和网络服务增删的恢复核对。使用非 Beta 的 Xcode 26.6。

本次本机 XCTest 结果：107 项通过，0 失败（其中新增 16 项隔离执行测试；arm64，macOS 26.6.1）。Release 应用分别完成 arm64 / x86_64 构建，并检查 Dashboard 兼容资源已进入包内。构建成功不等同于已在旧版 macOS 或 Intel 真机上运行验证。

仍需用反馈用户同一订阅、相同测速 URL 和超时做网络实测，才能判断是否达到其描述的十多秒。系统代理与增强模式同时开启后退出，须在带签名 Helper 的真实运行包上检查系统设置；纯单元测试不替代该端到端验证。

## 使用中的隔离测试

`ClashFXTests/IsolatedOperationTests.swift` 直接测试生产 `SelectorBenchmarkExecutor` 和 `SystemProxyManager`。主程序仅把真实请求和 XPC 作为依赖接入：`SystemProxyManager+Live.swift` 只加入 App target，不进入无宿主的测试 target。测试没有主程序单例、真实 Helper、DNS 操作或真实测速请求；每个代理测试使用独立 UUID 命名的 UserDefaults suite，结束仅清理自己创建的 suite。

- 测速：虚拟时钟驱动请求完成，覆盖健康批次、全超时、单个慢节点、结果复用、无效复用、取消、空计划和重复回调。人为设定的 24 节点、每请求超时 5000 ms 场景应恰好消耗三轮虚拟超时窗口，无追加重试；这不是实际网络速度的测量。
- 代理：模拟捕获、启用、恢复和读回，覆盖 PAC 原样恢复、等待在途启用、退出期间阻止启用、恢复错误/超时/不匹配后的快照保留与重试、取消退出后再启用、Helper 不可用、捕获错误/超时及迟到回调。生产八秒阶段超时在测试中缩短到 250 ms。

可在不退出当前 ClashFX 的情况下运行（正式版 Xcode 26.6，限制编译并行度）：

```sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer xcodebuild test \
  -workspace ClashFX.xcworkspace -scheme ClashFX \
  -destination 'platform=macOS,arch=arm64' -jobs 2 \
  -derivedDataPath /tmp/clashfx-isolated-safety-tests CODE_SIGNING_ALLOWED=NO
```

此命令不启动 App、不安装 Helper、不替换当前运行包。仍不能用模拟测试证明签名权限、系统网络服务提交或真实 TUN/DNS 恢复成功。

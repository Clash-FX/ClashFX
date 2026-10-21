# Issue #236：测速、缓存与自动策略的竞品源码复核

复核日期：2026-09-19。本文基于拉取到本地的完整仓库和固定提交，沿 UI 入口、调用桥接、HTTP 请求、状态保存、刷新和渲染追踪实现；不是基于搜索结果中的代码片段。下文的“事实”指固定提交的源码行为，“建议”是针对 ClashFX 的判断。

后续实施：已增加生产共享模块 `ClashFX/Models/BenchmarkEvidence.swift`，包含条件隔离缓存、响应分类、通知存储和行展示解析，并纳入 App 与独立 XCTest target。第 5 节保留调研当时的发现作为背景：当前补丁已经处理 URL/状态隔离、核心节点 ID 校验、明确的历史提示，以及生产存储—通知—解析与取消回调测试。旧核心缺少节点 ID 时，在配置重载后保守失效；“同配置菜单重建保留”不等同于“核心重建了节点后仍沿用旧结果”。尚未在 issue 作者原始配置或 macOS 10.14 实机上验证。

## 1. 源码版本与阅读范围

| 项目 | 分支及固定提交 | 阅读范围 |
|---|---|---|
| Clash Verge Rev | `dev` / `94491b4ba4f72f1f6010773bd7cd29fdde971aea` | 完整 DelayManager、React 订阅 hooks、策略组测速入口、行渲染、列表刷新、选择 hook、delay 单测；Rust 托盘菜单的相关完整函数、proxy view 生产实现 |
| Clash Verge Rev 的 Mihomo 插件 | `17c7757389ca73d29882753ecf7a160de29aabbe`，与上述仓库 lockfile 一致 | 从 JS invoke、Rust command 到实际 HTTP 请求的完整测速函数；proxy 集成测试文件 |
| Clash Party，原 Mihomo Party | `smart_core` / `bc4fe43ab28ab78660c3c7f2d59e0332f2bcf7d8` | 完整 `proxies.tsx`（812 行）、`proxy-item.tsx`（193 行）、`use-groups.tsx`（49 行）、`mihomoApi.ts`（693 行）、`tray.ts`（872 行）；追踪 IPC 注册与转发 |
| MetaCubeXD | `main` / `8bbc8f58fef71148a94fb5c0ff808f79b057337d` | 完整 proxies store（749 行）、batch latency composable（387 行）、proxy node composable、Latency 组件及两份核心测试（724 / 565 行）；追踪 API、URL 配置、页面选中态和 endpoint query 隔离 |

这是默认开发分支在上述提交的行为，不代表每个已发布版本都相同。本次没有安装、运行竞品应用，也没有执行依赖真实核心的竞品集成测试；竞品测试结论来自阅读测试断言。ClashFX 上一轮 115 项测试与构建通过，是本项目的验证结果，不能代替竞品行为验证。

## 2. Clash Verge Rev：集中测速管理，结果刷新与排序刷新分离

完整调用链：`ProxyGroupTools` / `ProxyGroups.handleCheckAll` → `DelayManager.checkListDelay` → `measureDelay` → `unifiedDelayCheck` → JS 插件 → Rust command → Mihomo HTTP API → `setDelay` → 行订阅；整组结束后再通知 group listeners，并刷新 proxy view。

- **测速入口与语义**：普通节点走 `/proxies/{name}/delay`，provider 节点走 provider scoped healthcheck。当传入策略组时，普通 delay endpoint 测量该组当前路径，不等同于 `/group/{name}/delay` 的整组成员重测。前端批量测速不会根据最小延迟自行选择节点。
- **URL 来源**：用户为该组填写的测试 URL优先，其次组 URL，再其次全局默认 URL。
- **缓存**：键是 `group::name`，保存 delay、更新时间等；手动结果有 30 分钟 TTL。过期后 `getDelayFix` 回退到 proxy 的 `history.last`。因此“手动缓存过期”和“整个 UI 必须空白”是两件事。
- **并发与刷新**：实际并发上限为 10，开始请求前有轻微随机错峰。逐项数值通知合并到下一帧；整组完成后才发排序相关通知，避免鼠标下的行不断换位。
- **选择**：从核心 `now` 渲染当前成员；手动选择另走 select API。proxy view 前台每 15 秒刷新，并有事件触发和测速完成触发。
- **边界**：缓存键没有测试 URL；`getDelayFix` 的通用 history fallback 也不核验 URL。这个实现适合“最近测量”显示，但不能直接作为我们“同一 Selector 行横向可比”的保证。前端 `Promise.race` 超时也不等价于取消底层请求。

固定源码：[DelayManager](https://github.com/clash-verge-rev/clash-verge-rev/blob/94491b4ba4f72f1f6010773bd7cd29fdde971aea/src/services/delay.ts)、[策略组入口](https://github.com/clash-verge-rev/clash-verge-rev/blob/94491b4ba4f72f1f6010773bd7cd29fdde971aea/src/components/proxy/proxy-groups.tsx)、[行状态 hook](https://github.com/clash-verge-rev/clash-verge-rev/blob/94491b4ba4f72f1f6010773bd7cd29fdde971aea/src/hooks/use-proxy-delay-state.ts)、[刷新与排序订阅](https://github.com/clash-verge-rev/clash-verge-rev/blob/94491b4ba4f72f1f6010773bd7cd29fdde971aea/src/hooks/use-group-delays.ts)、[测试](https://github.com/clash-verge-rev/clash-verge-rev/blob/94491b4ba4f72f1f6010773bd7cd29fdde971aea/src/services/delay.test.ts)、[真实 HTTP 请求](https://github.com/clash-verge-rev/tauri-plugin-mihomo/blob/17c7757389ca73d29882753ecf7a160de29aabbe/src/mihomo.rs#L835)。

### 托盘与主窗口是两条实现，不应混为一谈

Rust 托盘的 `create_subcreate_proxy_menu_item` 直接使用核心快照中的 `now` 决定勾选，使用每个成员的 `history.last` 显示延迟。它没有经过前端的 30 分钟手动缓存。`create_tray_menu` 获取 proxies 有一秒外层超时，`update_menu_internal` 重建菜单。

我们可以借鉴它的快照来源，但 ClashFX 需要保持测速中的 AppKit 菜单稳定，不能照搬频繁整菜单重建。

固定源码：[托盘菜单](https://github.com/clash-verge-rev/clash-verge-rev/blob/94491b4ba4f72f1f6010773bd7cd29fdde971aea/src-tauri/src/core/tray/mod.rs#L460)。

## 3. Clash Party：核心历史为主，客户端做短时批量写回

主窗口调用链：页面 `onGroupDelay` → renderer IPC → preload 白名单 → main handler → `mihomoProxyDelay` → 单节点/provider API → 收集结果 → 每 200ms 合并追加到 SWR 中该组成员的 history → ProxyItem 显示最后一条。

- `delayTestUrl` 全局设置优先，其次传入的组 URL，再其次默认 URL。
- 页面批量测试对当前列表逐项调用单节点 API；并发由配置限制，默认 50。
- `pendingDelayResults` / `pendingDelayDone` 合并结果和 loading 更新，避免每个结果都复制整个列表。
- `useGroups` 每 30 秒刷新、5 秒去重，并设置 `keepPreviousData`；订阅 `groupsUpdated` 事件。单节点测试结束也触发重新拉取。
- ProxyItem 的显示直接取 `proxy.history` 最后一项，选中状态单独由 `proxy.name === group.now` 传入。页面这条链路没有另设一天硬过期。
- **边界**：通用 history 不携带展示所需的测试 URL 保证；页面批量 catch 把错误记成 `0`。它在错误分类、URL 可比性、配置切换中的旧回调隔离上，不应被当成完善模板。

托盘调用链不同：`updateTrayMenu` → `buildContextMenu` → 重新取 `mihomoGroups` → 每行读 history、按 now 勾选。托盘测速按钮调用的是 `mihomoGroupDelay`，即整组 `/group/{name}/delay`；成功后通知主窗口 `groupsUpdated`。不能用主窗口的逐节点调度方式描述其托盘测速。

固定源码：[完整策略页](https://github.com/mihomo-party-org/clash-party/blob/bc4fe43ab28ab78660c3c7f2d59e0332f2bcf7d8/src/renderer/src/pages/proxies.tsx)、[行组件](https://github.com/mihomo-party-org/clash-party/blob/bc4fe43ab28ab78660c3c7f2d59e0332f2bcf7d8/src/renderer/src/components/proxies/proxy-item.tsx)、[SWR 刷新](https://github.com/mihomo-party-org/clash-party/blob/bc4fe43ab28ab78660c3c7f2d59e0332f2bcf7d8/src/renderer/src/hooks/use-groups.tsx)、[核心 API](https://github.com/mihomo-party-org/clash-party/blob/bc4fe43ab28ab78660c3c7f2d59e0332f2bcf7d8/src/main/core/mihomoApi.ts#L391)、[完整托盘实现](https://github.com/mihomo-party-org/clash-party/blob/bc4fe43ab28ab78660c3c7f2d59e0332f2bcf7d8/src/main/resolve/tray.ts)。

## 4. MetaCubeXD：分开保存测量、历史、运行状态

单节点链路：`useProxyNode.runLatencyTest` → store `proxyLatencyTest` → 递归解析核心 now → 单节点/provider API → 写 latencyMap 和历史 → Latency 组件查询 store。

整组链路：页面或 `testMultipleGroups` → `proxyGroupLatencyTest` / `testGroupNodes` → group API → 刷新 proxies → 记录返回的成员结果；最后释放 loading 状态。

- `latencyMap` 按节点和测试 URL 分桶；`proxyNodeMap` 保存核心路径和各 URL 的历史；testing maps 独立保存运行状态。
- 开始单节点/整组测试时不抹掉上一结果。运输层请求失败时保留上一测量，并向历史追加失败点；loading 在 finally 中结束。相关行为有直接的测试断言。
- **并非所有路径都如此**：`batchTestNodes` 仍会先清理对应值，并把失败记成 0；`fetchProxies` 获得新的空历史时会覆盖原值。不能概括成“MetaCubeXD 永久保留所有测速结果”。
- 单节点客户端超时至少 20 秒或核心预算 +10 秒，整组至少 30 秒或核心预算的两倍 +10 秒，避免客户端先于核心超时。
- 普通批量按 10 个一批、批间 200ms；节点批量可 Abort，并有“批间取消后不启动下一批”的测试。不能据此声称所有整组 API 都能取消。
- `getNowProxyNodeName` 递归解析 now，有环检测；勾选仍按父组一跳 now。推荐节点是另一功能，页面只有用户开启自动推荐切换后才会据推荐结果 select。
- **重要取舍**：请求 URL 没有成功值（甚至已有 0）时，`getLatencyByName` 会选择其他 URL 的成功值；测试明确要求这一行为。它改善“满屏 ---”，但可能遮住当前 URL 的失败，也不能用于严格横向比较。

固定源码：[完整 proxies store](https://github.com/MetaCubeX/metacubexd/blob/8bbc8f58fef71148a94fb5c0ff808f79b057337d/packages/ui/stores/proxies.ts)、[批量调度](https://github.com/MetaCubeX/metacubexd/blob/8bbc8f58fef71148a94fb5c0ff808f79b057337d/packages/ui/composables/useBatchLatencyTest.ts)、[store 行为测试](https://github.com/MetaCubeX/metacubexd/blob/8bbc8f58fef71148a94fb5c0ff808f79b057337d/packages/ui/stores/__tests__/proxies.spec.ts)、[批量与取消测试](https://github.com/MetaCubeX/metacubexd/blob/8bbc8f58fef71148a94fb5c0ff808f79b057337d/packages/ui/composables/__tests__/useBatchLatencyTest.spec.ts)、[API 超时和 provider 路由](https://github.com/MetaCubeX/metacubexd/blob/8bbc8f58fef71148a94fb5c0ff808f79b057337d/packages/ui/composables/useApi.ts#L383)。

## 5. 对 ClashFX 当前补丁的复核

### 已有方向得到支持

1. **勾选由核心 now 决定**。测速数字存在与否不能决定节点是否被选中，也不能直接以 UI 最小数字替换核心选择。
2. **显示更新应合并**。现有 150ms coalescer 和增量菜单刷新值得保留；不要照搬竞品较高的默认并发。
3. **保留上次结果有价值**。请求没得到新数据时，不能自动解释成节点坏了，也不应因为视图重建就删除证据。
4. **两类测速有不同语义**。Selector 的可比较测量，与自动组自身健康检查/选路必须明确区分。

### 仍需处理，不能仅凭上轮测试通过就宣布完成

**A. 共享缓存的键不包含测试 URL。** `GlobalLeafBenchmarkPresentationStore` 使用 `LeafProxyBenchmarkIdentity`；其中只有 endpoint 种类、provider 名和节点名，URL 在 value 中。先测 URL A，再测 URL B，会覆盖 A 的手动结果。即时通知路径也直接应用全局结果，与刷新时的 URL 判断不完全一致。建议把测试 URL/状态语义纳入测量身份，并让通知和快照刷新共用同一解析规则。

**B. 失败结果类型丢失。** `ApiRequest.requestProxyDelay` 回调只有 Int：控制器不可达、鉴权错误、响应解析失败和节点探测失败都可能压成 0；上层随后写为 `.failed`。建议保留明确的 probe failure、transport/API unavailable、cancelled 分类；后两者不能作为“节点故障”覆盖上一成功测量。

**C. 无期限保留应有身份和陈旧状态约束。** 现有 tooltip 加了时间，但 `isStale` 未形成一致的展示策略；同配置、同 provider、同节点名在订阅更新后可能已指向不同实际节点，当前 identity 无法识别。建议将“最后测量”与“当前可用”分开，按可验证的配置/节点身份失效；不要只用无限保留代替原硬过期。

**D. 115 项测试没有覆盖全部生产 UI 链路。** 独立测试 target 主要编译模型和 executor；完整 App 构建只证明类型和链接正确。需要覆盖 store 到菜单通知的一致性、请求失败保留旧值、同名配置更新失效、取消后旧回调不得覆盖新一轮，以及 now 变化后勾选与延迟独立更新。

本节是代码复核发现，不代表已在 issue 作者原始配置上复现全部问题。

## 6. 建议的收敛方案

保留 AppKit 架构和当前有界调度，收敛到一个可测试的测量解析入口：输入核心快照、父组测试条件、节点/provider 身份、本轮 session 与最近测量；输出当前路径、延迟证据及其 URL/时间/新旧状态。选择状态继续独立读取核心 now。

优先序：同测试条件下的新核心证据或新手动结果 → 同身份、同测试条件的历史测量（明确标为历史）→ 未测/本次不可用。其他 URL 的测量如果展示，只能作为明确标注的参考，不能参与本组比较；确定的最新探测失败不能被另一 URL 的旧成功掩盖。

执行时先修 A/B 并补生产状态流测试，再完善 C 的失效与展示；不需要整体移植竞品 UI 框架，也不需要因为源码调研引入新的依赖。

## 7. 对先前结论的更正

- 24 小时硬过期是 ClashFX 旧逻辑中的真实条件，但只有缺少可用回退证据时才导致空白。截图时间间隔不能证明它就是 issue 的唯一根因。
- 自动组与父组 URL 语义混用是可以从请求及核心实现验证的问题，但截图里父组勾选“自动选择”，不等于证明自动组内部没有有效 now。需要原配置或核心响应才能归因到作者的具体路径。
- 本次仅增加源码调研报告，没有继续修改 App 生产代码或发布构建。

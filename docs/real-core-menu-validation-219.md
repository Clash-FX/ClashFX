# 真实 Mihomo + 本地节点 + AppKit 菜单隔离验证

日期：2026-09-19。验证脚本：`scripts/run-real-core-menu-validation.py`。

## 环境

- 从仓库固定的 Mihomo 1.19.24 及 `core_overlay.py` 发布补丁重新编译独立二进制，没有使用或替换运行中的核心。
- 独立临时 home/config/cache，随机回环控制端口和一次性 secret，普通用户权限启动。
- mixed/http/socks/redir/tproxy 入口端口均为 0；TUN、DNS、NTP、sniffer、Geo 自动更新关闭；allow-lan=false；不调用 helper，不设置系统代理。
- 两个本地 HTTP CONNECT 代理及一个确定拒绝连接的故障代理，只允许转发到本机测试 origin。所有测速地址为 127.0.0.1，未使用真实订阅、远端节点或公共测速网站。
- XCTest 的 HTTP 会话关闭代理/PAC、Cookie、凭据存储、URL 缓存和重定向；只接受脚本 manifest 中的回环地址。普通单元测试仍走模拟 URLProtocol，真实核心用例必须显式启动脚本才能运行。
- 使用生产 NSMenu、菜单视图、测速动作、计划、executor、解析器与 presentation stores。测试 target 的 API facade 和 App 生命周期协调仍为测试边界，**不是完整 ClashFX 主 App 的人工桌面操作验证**。

## 第一轮发现

真实核心会在测量后改变历史数据，导致菜单持有的拓扑快照被刷新。测速动作此前只保存组对象，而组的 enclosingResp 是 weak；可见行都转向新快照后，第二个动作仍使用旧组，其快照已释放，生成的 memberIDs 为空。随后行校验丢弃“测速中”的记录，结算又找不到对应会话，第二组显示“未测速”。

修复 `ProxyGroupSpeedTestMenuItem`：持有动作所需的快照，并订阅真正的 ClashProxy 组更新，与可见菜单行一起更新组对象；忽略同通知名下的进度 payload。补充了不依赖真实核心的确定性回归，验证第一组完成并刷新历史后，第二个自动组仍能正确结算。

## 修复后真实核心结果

| 场景 | 观测结果 |
|---|---|
| 正常代理及显式 DIRECT | Local-A 79ms、Local-B 215ms、DIRECT 30ms，均显示在对应菜单行 |
| 故障 HTTP 代理 | Local-Broken 显示 fail，未用其他成功节点替代 |
| 真正的空地区组 | include-all + 无匹配 filter 由核心生成 COMPATIBLE；Empty-SG、Empty-TW、Nested-Empty 均显示兜底说明，菜单测速没有请求 COMPATIBLE |
| 空组 ReTest | 不启动测速会话，不发送延迟请求 |
| 自动组选路 | 改变本地节点响应耗时后，核心 now 从 Local-A 变为 Local-B，AppKit 勾选同步变化 |
| 不同测速 URL | 同一节点 A URL 得到 286ms、B URL 得到 376ms，两组各自显示；重新创建菜单后结果仍各自保留 |

这些数值是本地受控耗时，不表示任何实际机场/订阅的性能。

真实核心集成工作流通过。随后常规隔离回归 **140 项通过，0 失败**；该次常规运行显式排除了需要单独启动的真实核心用例。

## 运行中 App 与清理

验证前后 ClashFX PID 均为 35483、现有 Mihomo 核心 PID 均为 94503，系统代理配置的 SHA-256 摘要一致。独立测试核心 PID 50692 已退出，所有 Python 测试监听器已关闭，Go 构建 overlay 已清理。失败的第一轮也执行了同样的 finally 清理。

日志和可复查产物保留于：

`/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-real-core-menu-8zka8jew/`

其中 `result.json` 记录 passed=true、runningAppUnchanged=true、fixtureCoreStopped=true、fixtureListenersClosed=true；`tests.log` 包含实测结果和 TEST SUCCEEDED；`core.log` 是独立核心的启动日志。常规回归日志为 `/tmp/clashfx-real-core-followup-regression.log`。

## 仍未覆盖

- 原作者的真实订阅配置和远端节点网络条件。
- WebKit 605.1.15 / macOS 12.7.5 及 macOS 10.14 实机。
- 正式 App 安装包的签名、公证及 DMG 检查。

本轮未提交、推送、安装 App，也未准备或发布 Lab 包。

## 快照修复的追加 review

再次复核后收紧了测速动作的通知入口：仅接受同名、同类型、仍属于有效 enclosingResp 且与该快照 map 对象一致的组更新；进度 payload、脱离快照的对象及类型变化不会替换当前有效状态。新增测试确认旧快照替换后释放，菜单项释放后通知注册不造成引用残留。

追加验证：常规隔离回归 **142 项通过，0 失败**；独立真实核心再次通过，URL-A / URL-B 分别为 285ms / 363ms，连续测试及重开菜单保持正确。无本次修复范围内的剩余阻塞发现；仍保留前述旧系统、原作者配置及发布产物验证边界。

本轮真实核心 PID 51541 已退出、监听器关闭；当前 ClashFX PID 35483、原核心 PID 94503 和系统代理摘要未变化。日志目录：`/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-real-core-menu-kkyccolr/`；常规测试日志：`/tmp/clashfx-snapshot-review-tests.log`。

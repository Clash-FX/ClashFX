# 最新恢复候选的独立 macOS 验收（2026-10-19）

状态：当前候选的独立托管后端验收通过；完整 GUI 与授权弹窗未验收。仅临时测试分支，不发布、不替换应用。

- 账号：mixc6763-prog。
- 候选：9ee74ed9a19e265c62813348c6456eda6d5f2af2。
- 分支：codex/helper-tun-acceptance-20261019-recovery-631ddc。
- [托管运行 39202906194](https://github.com/Clash-FX/ClashFX/actions/runs/39202906194)。
- 本地证据：`/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-hosted-candidate-20261019-p1ojw2vd`；索引 /tmp/clashfx-hosted-candidate-acceptance-path。

## 本轮范围

在新鲜 GitHub-hosted macOS guest 构建当前候选 Helper、核心和 Cgo bridge，运行实际 Helper/TUN/DNS、连续配置切换、失败回滚和快速启停。新增恢复选择缓存、provider 节点移除/重新加入、显式 DIRECT、自定义 IPv6 DNS 真实 Cgo/核心夹具、实际重试菜单/lifecycle 提取回归，以及事件日志校验。不使用旧运行结果代表当前候选。

AppDelegate lifecycle 提取夹具验证实际生产方法的状态和重试逻辑，但不等于启动完整 GUI。动态 provider 测试通过私有 no-TUN 核心执行；真实 Helper/TUN 测试另行执行，不能合并声称 provider 在完整 App GUI/TUN 恢复过程中已经测过。

## 图形与授权边界

用户确认没有独立 Mac/macOS 虚拟机连接方式。限定检查没有发现现成 VM 应用、标准 VM 目录或仓库配置的远端图形 Mac。当前托管工作流通过 sudo 运行生成的 Legacy 安装脚本，完整 ClashFX App 没有启动，也没有真实 SMJobBless 授权弹窗。这些步骤无法验证接受/取消授权、完整 GUI 连续操作或完整 AppDelegate 的 TUN/DNS 切换。

因此本轮即使所有托管后端场景通过，也不能标记完整候选包 GUI/授权验收通过，不能由此发布新 Lab。仍需可交互、独立 macOS 及实际签名候选包。禁止用本机运行的 ClashFX 或修改本机网络补足缺口。

## 保护措施

原工作区不提交，不合并、不打 tag，不创建 Release。候选源码在私有临时工作树快照后推到单独测试分支；不上传本地规划文件、个人日志和本地代理配置。宿主仅执行读写源码、gh 和只读系统状态采集，不执行特权验收脚本、App/Helper/core 控制或系统配置写入。开始记录 App/Helper/core 的 PID、启动时间、安装二进制 SHA256，以及系统代理/DNS；结束进行比较。

## 本轮实际结果

运行 39202906194 成功。主报告 106 条、运行配置报告 25 条、生产事务报告 8 条，共 **139 条断言全部通过**，三份报告均为 passed，无失败，production controlPassed=true。

| 场景 | 结果与边界 |
| --- | --- |
| 冷启动 | 真实协议 6 Helper、root immutable 核心和批准客户端安装/启动，TUN/API/监听归属成立；非完整 App 冷启动 |
| 连续切换 | 生产 RuntimeConfigTransactionController 连续六次切换，确认端口复用、HTTP 204 代理转发及真实 UDP/TCP TUN DNS |
| 失败与回滚 | 语法/语义失败在 apply 前拒绝；TCP/UDP 端口冲突恢复旧配置和监听；失败 PATCH 保持原 TUN/访问策略；SCPreferencesLock 失败恢复代理检查点 |
| 重试 | 实际 AppDelegate checkpoint/retry/failure/readback 提取夹具通过，包括不确定运行状态、模式队列及超时/取消；未执行完整 GUI 重试按钮 |
| provider 移除/恢复 | 当前真实 no-TUN 核心：恢复节点移除后 REJECT，重新加入恢复可用，显式 DIRECT 仍允许；不是完整 App/TUN 联合场景 |
| 选择保护 | 缓存 DIRECT 重启后首个 API 已选择冻结的 Node；缺失目标退出 1 且 API 不发布；恢复失败不改坏原缓存 |
| IPv6 DNS | 同端口/变端口 native IPv6 和 mapped IPv4 经真实 Cgo/核心 UDP+TCP 查询通过；wildcard 仅投影检查、不启动 wildcard 监听 |
| 真实 TUN/系统 DNS | 实际 macOS resolver 查询经过 fake-IP 与当前 utun 路由；结束系统 DNS 与代理精确恢复 |
| 快速启停 | 三轮真实 Helper/core stop/start，确认旧进程/监听/TUN 路由释放及新 PID/launch 成立 |
| 清理 | 核心经 Helper 停止，Helper job 卸载，安装路径、批准核心和信任收据移除；无本轮遗留资源 |
| 完整 GUI/授权 | **未验收**。fullClashFXAppLaunched=false，productionTransactionDNSOverrideRestore=false；sudo 安装不代表实际授权弹窗通过 |

本轮没有发现需要修改生产代码的新问题；仅补强验收工作流并记录证据。三份 JSON 报告、完整工作流日志、运行元数据、源码清单和宿主对比均已下载保存在本地证据目录。托管路由恢复按持久路由与转发路径判定，不声称临时内核路由缓存逐字节一致。

最终 489 个快照输入与当前工作区及已推送候选一致（不计有意增加的工作流步骤和排除的本地 AI 助手配置目录）。本机 App/Helper/核心 PID、启动时间、已安装二进制 SHA256、系统代理与 DNS 均与开始时完全一致。

完整候选包验收仍未完成：需要独立、可交互 macOS 环境与实际签名包才能完成授权接受/取消、完整 GUI 配置切换与 AppDelegate TUN/DNS 联合场景。当前结果不作为新 Lab 发布许可；未发布、未替换本机应用。

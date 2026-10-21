# Issue #221：旧 WebKit 对比度兼容修复与验证

日期：2026-09-19。对应 [9 月 15 日最新反馈](https://github.com/Clash-FX/ClashFX/issues/221#issuecomment-5677668200)。

## 本次修改

- 兼容脚本版本更新为 `2026.09.19.1`。仍由原有实际渲染能力探测决定是否安装回退样式，现代 WebKit 保持上游样式。
- 为打包面板 MobileBottomNav 的底栏及“更多”弹层补充背景与边框，覆盖旧 WebKit 无法渲染的内联 color-mix。
- 根据主题的实际前景色和标准背景层计算可读颜色。中性色辅助文字与导航文本使用可读前景；底栏小字不再重复乘以 opacity-80。选中态主题色在保留色调的基础上调整到可读范围。
- 为塌缩到同一近黑色的背景层提供适度区分。普通正文与辅助文字保持层级，未统一改成纯白。
- 观察普通元素 class 变化及新增元素。每次重建缓存主题颜色解析，批量 DOM 更新合并处理；避免对每次 class 变化扫描整棵子树。
- 没有调整图表调色盘或禁用控件的透明度。

## 测试环境和边界

`DashboardContrastIntegrationTests` 在独立 XCTest 进程中使用非持久化 WKWebView，加载仓库中实际打包的 `entry.*.css` 和对应的底栏、弹层、规则标签 DOM 结构，运行生产兼容脚本。夹具 CSP 禁止外部加载，不运行 Dashboard 应用脚本、不访问 Mihomo API，也不使用当前控制台的存储。

测试通过注入让 rendered color-mix 能力探测失败，强制进入旧引擎回退路径。为避免隐藏 WKWebView 节流，夹具将 requestAnimationFrame 调度替换为零延迟定时器。其余 DOM、CSS 级联、computed style、MutationObserver 来自真实 WKWebView。

这证明了当前 WebKit 上回退样式的计算和集成行为，**不等价于在 WebKit 605.1.15 / macOS 12.7.5 实机上完成复测**，也没有覆盖每个上游页面。传统 10.14 发布目标未修改；本机 Xcode 27 测试命令临时覆盖 deployment target 为 12.0。

## 结果

| 测试主题 | 实测夹具导航最小对比度 |
|---|---:|
| black | 4.79:1 |
| dark | 4.95:1 |
| night | 4.88:1 |
| coffee | 5.36:1 |
| dracula | 4.78:1 |
| dim | 6.42:1 |
| light | 4.73:1 |
| nord | 4.73:1 |

以上由 computed style 的最终 RGB 与透明度计算，目标为至少 4.5:1。规则标签和弹层文字也通过 4.5:1 断言。另验证了：

- 既有元素切换到新的文字颜色 class 后生成相应兼容规则；
- 批量插入 100 个元素触发合并更新，随后停止刷新，没有观察器自循环；
- 导航选中态及“更多”按钮前景/背景可读；
- 禁用控件 opacity 仍为 0.3，图表示例颜色 alpha 仍为 0.5；
- 未强制旧引擎路径时，现代 WebKit 不安装兼容 stylesheet，保留上游 opacity。

新增 4 项渲染集成测试全部通过。与之前的测速和 AppKit 菜单测试合跑，总计 **134 项测试、0 失败**。

测试前后 ClashFX PID 均为 35483、核心 PID 均为 94503，系统代理配置输出的 SHA-256 摘要一致。本次没有提交、推送、安装 App 或准备/发布 Lab 包。

测试日志：`/tmp/clashfx-221-full-regression.log`。

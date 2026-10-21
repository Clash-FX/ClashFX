# 2026-09-26 Xcode 增强模式启动失败修复

## 证据与根因
本次粘贴日志反复出现 API/TUN ready but current launch DNS ownership/protocol is not ready。对应 launch 20260926-033445-535-f8fa42e6 的核心日志显示：11:34:45 API49888、DNS TCP/UDP49887、Mixed7890和SOCKS7891已监听，utun7已获得198.18.0.1。说明新核心已经建立TUN，客户端仍未接受启动完成。

生产DNS解析器把QDCOUNT读成ARCOUNT（错误使用10/11字节，应为4/5），并从flags高字节读取RCODE（应为第3字节的低4位）。普通DNS响应ARCOUNT=0被拒绝，合法成功响应也可能被误读为非零响应码。

独立启动本机工作区Mihomo1.19.24，使用临时home、随机loopback DNS端口、fake-IP、TUN关闭、无Helper。实测UDP/TCP均得到报文头c1a5 8580 0001 0001 0000 0000。旧生产解析器对两个响应均返回nil；修正后均返回rcode0、answers1、response=true。临时核心已经停止，没有改动系统网络设置。

## 修改
- 正确读取QDCOUNT与RCODE，允许无EDNS附加记录的标准响应；保持question、事务ID和QR/TC检查。
- 解析前统一Data索引，避免Data切片的起始索引影响。
- 修正旧SERVFAIL夹具，显式断言RCODE=2；增加真实Mihomo响应回归，包含无附加记录、EDNS记录以及QDCOUNT不能由ARCOUNT替代的场景。
- 启动失败日志增加ownsListeners和protocolResponding，区分Helper归属检查失败与DNS协议检查失败。

## 验证
167项隔离XCTest通过，0失败。真实DNS响应旧/新解析器对照已通过。完整临时副本构建另见/tmp/clashfx-tun-dns-fix-build.log。
证据：/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-dns-wire-sw3akqd5
XCTest日志：/tmp/clashfx-tun-dns-fix-tests.log。

## 当前边界
没有自动重启用户应用、安装Helper、切换TUN或修改系统DNS。本机macOS14.0临时构建设置保留。需要用户重新Run最新版并再次启用增强模式，才能确认此次真实TUN验收通过；发布继续暂停。

次级源码风险：Helper状态收集串行运行两个lsof，客户端只等1秒。现有材料无法确认本次是否也发生超时；新增日志将帮助区分。不把该推断写成已发生根因。

完整App/Helper macOS14诊断构建通过（BUILD SUCCEEDED）。验证前后已安装App/核心进程及启动时间、系统代理和DNS完全一致。


## 2026-09-26 12:02 本机真实启动复测

本轮Xcode App PID72230，外部核心PID72291，二者路径均为Xcode DerivedData。
12:00:46.446日志确认API+TUN+接口+本launch DNS协议全部就绪，UDP=(0,1)、TCP=(0,1)、upstreamHealthy=true；12:00:48 TUN接口/API复核通过。
只读实时检查：mixed7890/socks7891，tun.enable=true，device=utun7，接口IPv4=198.18.0.1且UP；系统DNS为198.18.0.2，DNS API查询成功（2个Answer）。核心报告57个连接及非零累计流量。日志截至12:02:41未出现本轮TUN就绪失败/重建，核心本launch无error/fatal。
因此本轮“增强模式开启”验收通过；不代表关闭恢复、唤醒换网或发布验收已通过。

独立异常：12:00:48系统代理启用失败，captureFailed(current proxy settings already belong to ClashFX; no original snapshot is available)。实测HTTP/HTTPS/SOCKS系统代理均关闭。当前TUN运行不依赖这些开关，但普通模式及关闭后代理恢复必须单独验收。其他启动期订阅格式/下载问题不等同于TUN失败。

下一步由用户关闭增强模式，核对TUN撤销、DNS还原、用户端口恢复（本轮启动前52606）；本次检查未更改任何网络状态。


## 2026-09-26 12:16 关闭并重新开启检查
用户确认关闭一段时间后重新开启。日志12:14:03 DNS恢复完成，12:14:04端口回52606且Enhanced Mode disabled；12:15:36重新启用成功并回7890。关闭窗口没有实时scutil快照，DNS恢复以应用完成日志为证，尚不能声称已独立验证当时系统DNS值。
当前只读实测：HTTPEnable/HTTPSEnable/SOCKSEnable均为1，三者均127.0.0.1:7890；核心mixed-port7890，TUN启用utun7，7890接受连接。系统代理已开启，无需额外切换。该次切换后未见新的system proxy captureFailed。关闭时有CacheFile database not open告警，保留为后续观察项。
本次未改动任何系统代理/DNS或应用开关。


## 12:22–12:26 双实例/Helper 冲突：停止验收
12:21:58收到didWake，12:22:01 debug核心健康，12:22:03 TUN确认。12:22:52 /Applications正式版1.1.11.6另行启动，系统日志显示CoreServicesUIAgent经quarantine-resolver客户端80837发起LaunchServices启动（正式版PID80839）。没有足够证据确定最初调用者，不能归因于登录项、Sparkle或用户点击。
正式版发现已安装Helper与自身包不一致，12:23:07走legacy安装，之后恢复其核心，造成两个共享com.clashfx.app.Helper和用户配置目录的实例争用。当前仅旧正式版PID80982及其核心80997运行。
Xcode27重新构建还受到之前发布准备恢复10.14的影响；本轮已重新恢复主工程/所有Pods/Podfile14.0和工作区测试Go产物。安装版及其联网未被修改。发布准备和唤醒/换网验收暂停，无PR/tag/release。
后续切换测试必须先正常退出现用正式版，确认只剩一个GUI实例，再从XcodeRun并只为该测试实例完成Helper更新。为排除自动入口，测试期间临时关闭正式版开机启动，避免Dock/通知/启动器按共享bundleID拉起安装版；这属于防冲突操作，不是对本次触发来源的确认。若安装版再次被拉起应取消其Helper安装，记录时间并继续查调用者。
单实例启动防护及Helper操作归属保护尚是独立改进项，不能声称恢复14.0已经修复跨版本并发。


## 12:38 系统代理启用被闲置网卡阻断
当前仅XcodeApp84275/核心85027运行，scutil显示当前Wi-Fi HTTP/HTTPS/SOCKS均关闭。12:37:17、41、54三次enable均以captureFailed(no original snapshot)拒绝。
读取SystemConfiguration确认当前PrimaryInterface=en0/Wi-Fi；另一个AX88179A Ethernet服务仍保存三种代理开启、loopback7890。原始快照标记无效且无快照。Helper捕获所有服务，旧判断将任何服务匹配ClashFX都当成全局已接管，误拒绝当前Wi-Fi启用。
修复：只有当前生效的系统代理及捕获快照均匹配ClashFX时，才按缺少原始快照拒绝。当前生效状态判断同时检查Enable、loopback地址及端口；闲置服务旧配置原样保存并恢复，不直接清除。保留真正已接管时的保护。
新增真实SystemProxyManager+fakeHelper行为测试：Wi-Fi关闭、闲置USB代理匹配时启用成功并完整恢复原快照；当前网络已接管且无快照时仍拒绝。169项隔离XCTest和完整App/Helper构建通过。日志/tmp/clashfx-proxy-snapshot-fix-tests.log、/tmp/clashfx-proxy-snapshot-fix-build.log。
本轮不直接更改系统设置，验证前后现用App/核心进程及系统代理相同。需重新运行Xcode最新版再点击开启系统代理验证。14.0测试配置保留，发布暂停。


## 12:48 系统代理修复实测通过
用户重新Run后开启系统代理。仅XcodeApp86050及其核心86065运行。scutil确认HTTP/HTTPS/SOCKS均开启且指向127.0.0.1:7890；liveAPI mixed-port7890、TUN开启utun7，代理端口可连接。保存的原始代理快照有效标记为true。本次启动日志无captureFailed；ownedDNS检查成功、upstreamHealthy=true。下一步在系统代理保持开启时关闭TUN，确认系统代理切回配置端口及DNS恢复。


## 12:54 普通系统代理接续联网确认
用户确认关闭TUN、保持系统代理开启期间可打开网页。日志12:52:49 DNS恢复完成、12:52:50端口52606并disabled；12:53:27重开就绪、端口7890。当前仅XcodeApp86050和核心86624，liveAPI TUNenabled utun7、DNS查询2答案，scutil三种代理均7890。普通模式联网按用户实测确认；未取得关闭窗口的scutil原始快照。下一步准备换网验收，已记录基线，保持14.0配置。

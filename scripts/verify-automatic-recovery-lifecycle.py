#!/usr/bin/env python3
"""Exercise actual AppDelegate recovery methods with inert Foundation fakes.
No app, helper, user preferences, network sockets or system settings are used.
"""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
s = (ROOT/'ClashFX/AppDelegate.swift').read_text()
def method(marker):
    a=s.index(marker); b=s.index('{',a); depth=1; end=b+1
    while depth:
        depth += (s[end]=='{')-(s[end]=='}');end+=1
    return s[a:end].replace('private func ', 'func ')
methods='\n'.join(method(x) for x in [
    '    private func restartEnhancedModeAfterWake(',
    '    private func continueEnhancedModeRecovery(',
    '    private func finishFailedEnhancedModeRestore(',
    '    private func verifyAutomaticRecoverySelections(',
    '    private func checkedResumeBuiltInCore()',
    '    private func automaticRecoveryConfigurationReloadError()',
    '    var isRestoringProxySelection:',
    '    private func retryAutomaticRecoveryIfNeeded()',
    '    private func deferAutomaticRecoveryForModeQueue(',
    '    func switchProxyMode(',
])
action_start=s.index('    @IBAction func actionToggleEnhancedMode(')
action_brace=s.index('{',action_start)
action_end=s.index('        if startupCoreHandoffRetryAvailable',action_brace)
action_prefix=s[action_brace+1:action_end]
methods += '\nfunc clickEnhancedModeMenu() {' + action_prefix + '\nnormalToggleCalls += 1\n}\n'
policy_source=(ROOT/'ClashFX/General/Managers/StartupProxyRecoveryPolicy.swift').read_text()
policy_start=policy_source.index('enum EnhancedModeMenuAvailabilityPolicy')
policy_brace=policy_source.index('{',policy_start);policy_depth=1;policy_end=policy_brace+1
while policy_depth:
    policy_depth+=(policy_source[policy_end]=='{')-(policy_source[policy_end]=='}');policy_end+=1
menu_policy=policy_source[policy_start:policy_end]
validation_start=s.index('return EnhancedModeMenuAvailabilityPolicy.shouldEnableToggle(',s.index('func validateMenuItem('))
validation_end=s.index('\n            )',validation_start)+len('\n            )')
methods += '\nfunc enhancedMenuValidated() -> Bool { '+s[validation_start:validation_end]+'\n}\n'
header=r"""
import Darwin
import Foundation
func check(_ p: @autoclosure () -> Bool, _ m: String) { if !p() { fatalError(m) } }
enum Mode { case global, rule, direct }
typealias ClashProxyMode = Mode
enum OutboundModeChangeSource { case menu }
enum Settings { static var enhancedMode = true; static var claudeProxyLockEnabled = false }
enum ConfigManager {
    struct Record { var config: String; var group: String; var selected: String }
    static var selectConfigName = "A"
    static var selectOutBoundMode = Mode.rule
    static var selectedProxyRecords = [Record(config:"A",group:"TAGSS",selected:"Node")]
    static let shared = State()
    class State { var isEnhancedModeActive = true;var isRunning = true }
}
enum ProxyGroupSelectionController { static var isAnyOperationInProgress = false }
enum Yams { static func load(yaml: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(yaml.utf8)) } }
enum Logger {
    enum Level { case warning, error }
    static var events = [String]()
    static func log(_ s: String, level: Level = .warning) {events.append(s)}
}
class Menu { enum State { case on, off, mixed };var isEnabled=true;var state=State.on }
class Lifecycle { var generation:UInt64=0;func invalidate(){generation += 1} }
class NSUserNotificationCenter {
    static let `default`=NSUserNotificationCenter();var messages=[String]()
    func post(title:String, info:String){messages.append(info)}
    func postConfigErrorNotice(msg:String){messages.append(msg)}
}
enum ApiRequest {
    struct RuntimeConfigContext:Equatable { var direct:Bool;var apiURL:String;var secret:String }
    static func runtimeConfigContext()->RuntimeConfigContext { .init(direct:false,apiURL:"fixture://A",secret:"") }
    static var reads=[(Data?,String?)->Void]()
    static func readRuntimeProxySnapshot(context:RuntimeConfigContext,requireCurrentContext:Bool=true,completion:@escaping(Data?,String?)->Void){reads.append(completion)}
    static func cancelRuntimeConfigOperations(){}
}
class Transactions {func invalidate(){}}
var bridgeResumeCalls=0
func clashResumeCore()->UnsafeMutablePointer<CChar>? {bridgeResumeCalls+=1;return strdup("success")}
class Probe {
    static let wakeEnhancedModeRestartMaxAttempts=2
    static let enhancedModeRestoreRetryDelay=0.0
    var claudeLockChange:Int?
    var ownsRuntimeControl=true;var deferredAutomaticRecoveryID:UUID?;var automaticRecoveryNeedsRetry=false
    var isEnhancedModeTransitionInProgress:Bool {isWakeEnhancedModeRestarting || isEnhancedModeRuntimeRecoveryPending || deferredAutomaticRecoveryID != nil}
    var normalToggleCalls=0
    var modeWrites=0
    func presentClaudeProxyLockProtectionNotice(){}
    func enqueueOutboundModeChange(mode:Mode,source:OutboundModeChangeSource,closeConnections:Bool){modeWrites+=1}
    var isTerminating=false;var isRestarting=false;var isWakeEnhancedModeRestarting=false
    var isEnhancedModeRuntimeRecoveryPending=false;var isConfigUpdating=false
    var isConfigUpdateQueued=false;var selectionMemoryRestoration:Int?;var isOutboundModeChangeInFlight=false;var outboundModeChangeQueue=[Int]()
    var enhancedModeLifecycle=Lifecycle();var enhancedModeGeneration:UInt64 {enhancedModeLifecycle.generation}
    var automaticRecoverySelections:[String:String]?
    var automaticRecoveryConfigName:String?;var automaticRecoveryID:UUID?;var automaticRecoveryTrigger="fixture"
    var lastConfirmedEnhancedData:Data? = Data(#"{"proxy-groups":[{"name":"TAGSS","type":"select"}],"mode":"rule"}"#.utf8)
    var desiredOutboundMode:Mode?
    var didRestartHelperDuringEnhancedLaunch=false
    var enhancedModeMenuItem=Menu();var enhancedModeRuntimeHealthSummary=""
    var activeEnhancedModeClientLaunchID:UUID?;var activeEnhancedModeConfigPath:String?
    var activeEnhancedModeLaunchID:UUID?=UUID();var enhancedModeOwnershipBlock:Int?
    var startupCoreHandoffRetryAvailable=false
    var isCoreConfigSnapshotVerified=false;var runtimeCoreSessionID=UUID()
    var startupConfigurationFailure:(profile:String,reason:String)?
    var confirmedRuntimeProfileName:String?
    var runtimeConfigTransactions=Transactions();var isBuiltInCoreResumeRetryAvailable=false
    var stops=0;var launches=0;var launchError:String?;var launchCompletion:((String?)->Void)?
    var stopCallbacks=[(String?)->Void]();var holdStop=false;var holdLaunch=false
    var cancelledReloads=0
    func cancelDeferredConfigUpdate(reason:String){cancelledReloads+=1;isConfigUpdateQueued=false}
    func cancelActiveSpeedTest(reason:String){}
    func refreshStatusItemViewStatus(){}
    func blockActiveEnhancedModeOwnership(generation:UInt64,reason:String){enhancedModeOwnershipBlock=1}
    func restoreDNSAfterTun(reapplyTunIfLate:Bool=false,expectedGeneration:UInt64?=nil,completion:@escaping(String?)->Void){completion(nil)}
    func stopExternalCoreBounded(isCurrent:@escaping()->Bool,completion:@escaping(String?)->Void){stops+=1;if holdStop {stopCallbacks.append(completion)}else{completion(nil)}}
    func attemptEnableEnhancedMode(attemptsLeft:Int,alreadySuspended:Bool,generation:UInt64,completion:@escaping(String?)->Void){
        launches+=1;launchCompletion=completion
        if !holdLaunch{completion(launchError)}
    }
    func scheduleEnhancedModePostToggleRefresh(){}
    func restoreBuiltInRecoveryCheckpoint()->String?{nil}
    func fenceFailedBuiltInRecovery(){ConfigManager.shared.isRunning=false;isCoreConfigSnapshotVerified=false}
"""
tests=r"""
}
let snapshot=Data(#"{"proxies":{"TAGSS":{"name":"TAGSS","type":"Selector","now":"DIRECT","all":["DIRECT","Node"]},"DIRECT":{"name":"DIRECT","type":"Direct"},"Node":{"name":"Node","type":"Shadowsocks"}}}"#.utf8)
func reset(){ApiRequest.reads=[];ConfigManager.selectConfigName="A";Settings.enhancedMode=true;ConfigManager.shared.isEnhancedModeActive=true;ConfigManager.shared.isRunning=true}
reset()
let app=Probe();app.holdLaunch=true
check(app.automaticRecoveryConfigurationReloadError()==nil,"normal reload must remain allowed")
app.restartEnhancedModeAfterWake(attemptsLeft:2)
check(app.stops==0,"must freeze intent before stopping")
app.restartEnhancedModeAfterWake(attemptsLeft:2)
check(ApiRequest.reads.count==1,"reentrant recovery must not duplicate capture")
ApiRequest.reads[0](snapshot,nil)
check(app.automaticRecoverySelections?["TAGSS"]=="Node","saved intent must defeat cached DIRECT")
check(app.stops==1 && app.launches==1,"checkpoint precedes restart")
check(app.automaticRecoveryConfigurationReloadError()==nil,"active recovery should retain existing deferred reload behavior")
check(app.checkedResumeBuiltInCore() != nil && bridgeResumeCalls==0,"never resume fallback during recovery")
let id=app.automaticRecoveryID
app.finishFailedEnhancedModeRestore(error:"injected restore failure")
check(app.automaticRecoveryID==id && app.automaticRecoverySelections?["TAGSS"]=="Node","failure must retain original intent")
check(app.isRestoringProxySelection,"failed checkpoint must reserve menu selection interactions")
app.isWakeEnhancedModeRestarting=false
check(app.automaticRecoveryConfigurationReloadError() != nil,"failed checkpoint must reject reload even if old core stop is uncertain")
check(!ConfigManager.shared.isRunning && app.enhancedModeMenuItem.state == .mixed,"failure must remain visible/stopped")
check(!NSUserNotificationCenter.default.messages.isEmpty,"failure must notify")
app.isWakeEnhancedModeRestarting=false
app.restartEnhancedModeAfterWake(attemptsLeft:2)
check(ApiRequest.reads.count==1 && app.launches==2,"retry must reuse checkpoint, not recapture fallback")
app.launchCompletion?(nil)
check(app.automaticRecoverySelections==nil && app.automaticRecoveryID==nil,"only success clears checkpoint")
reset()
let unavailable=Probe();ConfigManager.selectedProxyRecords=[]
unavailable.restartEnhancedModeAfterWake(attemptsLeft:2);ApiRequest.reads[0](nil,"offline")
check(unavailable.stops==0 && unavailable.launches==0,"missing checkpoint must not stop and guess DIRECT")
check(!unavailable.isWakeEnhancedModeRestarting,"capture failure must unlock retry")
check(unavailable.isRestoringProxySelection,"retry-only capture failure must fence proxy selection")
check(unavailable.automaticRecoveryConfigurationReloadError() != nil,"retry-only capture failure must fence reload")
check(unavailable.checkedResumeBuiltInCore() != nil && bridgeResumeCalls==0,"retry-only capture failure must fence embedded fallback")
unavailable.switchProxyMode(mode:.direct)
check(unavailable.modeWrites==0,"retry-only capture failure must fence direct-mode changes")
reset();ConfigManager.selectedProxyRecords=[.init(config:"A",group:"TAGSS",selected:"Node")]
let stale=Probe();stale.restartEnhancedModeAfterWake(attemptsLeft:2)
stale.enhancedModeLifecycle.invalidate();ApiRequest.reads[0](snapshot,nil)
check(stale.stops==0,"late old-generation capture must not stop replacement")
reset()
let verify=Probe();verify.automaticRecoverySelections=["TAGSS":"Node"];verify.automaticRecoveryConfigName="A"
var error:String?;var done=false
verify.verifyAutomaticRecoverySelections(port:"1",secret:"",generation:0,launchID:verify.activeEnhancedModeLaunchID!){error=$0;done=true}
ApiRequest.reads[0](snapshot,nil)
check(done && error != nil,"DIRECT readback must fail protected Node checkpoint")
verify.verifyAutomaticRecoverySelections(port:"1",secret:"",generation:0,launchID:verify.activeEnhancedModeLaunchID!){error=$0}
let selected=Data(String(data:snapshot,encoding:.utf8)!.replacingOccurrences(of:"\"now\":\"DIRECT\"",with:"\"now\":\"Node\"").utf8)
ApiRequest.reads[1](selected,nil);check(error==nil,"matching readback should verify")
var late=false
verify.verifyAutomaticRecoverySelections(port:"1",secret:"",generation:0,launchID:verify.activeEnhancedModeLaunchID!){_ in late=true}
verify.activeEnhancedModeLaunchID=UUID();ApiRequest.reads[2](selected,nil)
check(!late,"late old-launch readback cannot publish success")
func spin(_ condition: ()->Bool) {
    let end=Date().addingTimeInterval(2)
    while !condition() && Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
    check(condition(),"bounded asynchronous mode-queue test timed out")
}
reset()
let menuRetry=Probe();ConfigManager.shared.isRunning=false
check(!menuRetry.enhancedMenuValidated(),"a stopped core without retry state should not enable a normal toggle")
menuRetry.automaticRecoveryNeedsRetry=true
check(menuRetry.enhancedMenuValidated(),"AppKit validator must allow stopped-core retry notice")
menuRetry.automaticRecoveryNeedsRetry=false;menuRetry.automaticRecoverySelections=["TAGSS":"Node"]
check(menuRetry.enhancedMenuValidated(),"AppKit validator must allow stopped-core checkpoint retry")
menuRetry.isTerminating=true
check(!menuRetry.enhancedMenuValidated(),"termination still blocks recovery menu")
reset()
let uncertain=Probe();uncertain.automaticRecoverySelections=["TAGSS":"Node"];uncertain.automaticRecoveryConfigName="A"
uncertain.enhancedModeOwnershipBlock=1;uncertain.holdStop=true
ConfigManager.shared.isRunning=true
uncertain.isConfigUpdateQueued=true
uncertain.clickEnhancedModeMenu()
check(uncertain.normalToggleCalls==0,"running-but-uncertain retry must not reach ordinary toggle")
check(uncertain.stops==1 && Settings.enhancedMode,"retry must not become disable")
check(!uncertain.isConfigUpdateQueued && uncertain.cancelledReloads==1,"failed queued reload must not deadlock explicit recovery retry")
reset()
let queued=Probe();queued.isOutboundModeChangeInFlight=true
queued.restartEnhancedModeAfterWake(attemptsLeft:2)
check(queued.deferredAutomaticRecoveryID != nil && queued.stops==0,"busy mode queue must defer without dropping recovery")
queued.switchProxyMode(mode:.direct)
check(queued.modeWrites==0,"pending recovery must reserve new mode changes")
queued.isOutboundModeChangeInFlight=false
spin {ApiRequest.reads.count==1}
ApiRequest.reads[0](snapshot,nil)
check(queued.launches==1 && queued.automaticRecoverySelections==nil,"recovery must resume after acknowledgement")
queued.switchProxyMode(mode:.direct);check(queued.modeWrites==1,"normal mode changes must remain allowed")
reset()
let timed=Probe();timed.isOutboundModeChangeInFlight=true
var timeoutOperation=false
check(timed.deferAutomaticRecoveryForModeQueue({timeoutOperation=true},timeout:0.001),"queue should defer")
spin {timed.deferredAutomaticRecoveryID==nil}
check(timed.automaticRecoveryNeedsRetry && timed.enhancedModeMenuItem.state == .mixed,"queue timeout must expose retry state")
check(timed.isRestoringProxySelection && timed.automaticRecoveryConfigurationReloadError() != nil,"queue timeout must fence configuration and selection")
check(timed.checkedResumeBuiltInCore() != nil,"queue timeout must not resume default embedded routing")
check(!timeoutOperation && timed.enhancedModeRuntimeHealthSummary.contains("timed out"),"timeout must report blocked recovery, not run/drop silently")
timed.isOutboundModeChangeInFlight=false
timed.isConfigUpdateQueued=true
timed.clickEnhancedModeMenu()
check(timed.normalToggleCalls==0 && !timed.isConfigUpdateQueued,"queue-timeout action must reach retry before the queued-config guard")
check(ApiRequest.reads.count==1,"queue-timeout retry should capture a new checkpoint")
reset()
let normalQueued=Probe();normalQueued.isConfigUpdateQueued=true
normalQueued.clickEnhancedModeMenu()
check(normalQueued.normalToggleCalls==0 && normalQueued.stops==0,"normal toggle must still wait for a queued configuration")
normalQueued.isConfigUpdateQueued=false;normalQueued.clickEnhancedModeMenu()
check(normalQueued.normalToggleCalls==1,"healthy idle menu must retain ordinary toggle behavior")
reset()
let cancelled=Probe();cancelled.isOutboundModeChangeInFlight=true
var cancelledOperation=false
_ = cancelled.deferAutomaticRecoveryForModeQueue({cancelledOperation=true})
cancelled.enhancedModeLifecycle.invalidate();cancelled.isOutboundModeChangeInFlight=false
spin {cancelled.deferredAutomaticRecoveryID==nil}
check(!cancelledOperation,"old generation must not restart after queue drains")
print("PASS: actual AppDelegate checkpoint/retry/failure/readback, uncertain-running retry and mode-queue deferral/reservation/timeout/cancellation")
"""
with tempfile.TemporaryDirectory(prefix='clashfx-auto-recovery-lifecycle-') as d:
    d=Path(d); main=d/'main.swift';main.write_text(header+menu_policy+"\n"+methods+tests)
    exe=d/'probe'
    subprocess.run(['swiftc',str(ROOT/'ClashFX/General/Utils/RuntimeProxySelectionRestoreSequence.swift'),str(ROOT/'ClashFX/General/Utils/RuntimeConfigApplyDiagnostics.swift'),str(main),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True,timeout=20)

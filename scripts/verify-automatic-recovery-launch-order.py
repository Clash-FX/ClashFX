#!/usr/bin/env python3
"""Run the actual successful-readiness block with inert dependencies.
Proves selection readback gates metadata, callbacks and DNS; no network/app I/O.
"""
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'ClashFX/AppDelegate.swift').read_text()
start=source.index('                        if success {',source.index('    private func finishEnhancedModeLaunchPreparation('))
brace=source.index('{',start);depth=1;end=brace+1
while depth:
    depth+=(source[end]=='{')-(source[end]=='}');end+=1
body=source[brace+1:end-1]
header=r"""
import Foundation
func check(_ p:@autoclosure()->Bool,_ m:String){if !p(){fatalError(m)}}
var events=[String]()
func clashResumeCallbacks(){events.append("resume")}
enum Settings {static var enhancedModeUseCustomConfig=false}
enum ConfigManager {
    static let shared=State()
    class State {var apiPort="old";var apiSecret="old-secret";var isEnhancedModeActive=false;var isRunning=false}
}
enum Logger {enum Level{case error};static func log(_ s:String,level:Level = .error){}}
class Recovery {func cancel(){}}
class Disposable {func dispose(){}}
struct Endpoints {var apiPort=1;var dnsPort=2;var proxyPorts=[3]}
struct LaunchContext {var dnsHost="127.0.0.1";var dnsPort=2}
class Probe {
    var enhancedModeGeneration:UInt64=7;var activeEnhancedModeLaunchID:UUID?=UUID();var isTerminating=false
    var didCompleteStaleEnhancedCoreCleanup=false;var startupCoreRecovery=Recovery()
    var startupCoreHandoffRetryAvailable=true;var startupHelperRecoveryDisposable:Disposable?
    var verification:((String?)->Void)?;var completions=[String?]()
    func refreshStatusItemViewStatus(){events.append("publish")}
    func overrideDNSForTun(generation:UInt64,launchID:UUID,completion:@escaping(String?)->Void){events.append("dns");completion(nil)}
    func verifySystemDNSTakeover(generation:UInt64,launchID:UUID,completion:@escaping(String?)->Void){events.append("dns-readback");completion(nil)}
    func rollbackEnhancedModeDNSFailure(error:String,generation:UInt64,launchID:UUID,completion:@escaping(String?)->Void,resumeGate:Int){events.append("rollback");completion(error)}
    func verifyTunStatus(port:String,secret:String,generation:UInt64,launchID:UUID){}
    func restoreSelectedOutboundModeAfterCoreChange(completion:@escaping()->Void){completion()}
    func confirmEnhancedRuntimeConfiguration(at:String,completion:@escaping(String?)->Void){completion(nil)}
    func clearEnhancedModeOwnershipBlock(requestID:UUID){}
    func verifyAutomaticRecoverySelections(port:String,secret:String,generation:UInt64,launchID:UUID,completion:@escaping(String?)->Void){events.append("selection-read");verification=completion}
    func readinessSucceeded(){
        let port="new";let secret="new-secret";let generation=enhancedModeGeneration
        let launchID=activeEnhancedModeLaunchID!;let launchContext=LaunchContext();let endpoints=Endpoints()
        let requestID=UUID();let configPath="fixture://private";let resumeGate=0
        let completion:(String?)->Void={self.completions.append($0)}
"""
tests=r"""
    }
}
func reset(){events=[];ConfigManager.shared.apiPort="old";ConfigManager.shared.apiSecret="old-secret";ConfigManager.shared.isRunning=false;ConfigManager.shared.isEnhancedModeActive=false}
reset()
let delayed=Probe();delayed.readinessSucceeded()
check(events==["selection-read"],"closure definition must not execute metadata/DNS publication")
check(!ConfigManager.shared.isRunning && ConfigManager.shared.apiPort=="old","readback pending must retain old metadata")
delayed.verification?("injected mismatch")
check(events==["selection-read","rollback"],"mismatch must reject before callbacks or DNS")
check(!ConfigManager.shared.isRunning && ConfigManager.shared.apiSecret=="old-secret","mismatch must not publish candidate state")
reset()
let accepted=Probe();accepted.readinessSucceeded();accepted.verification?(nil)
check(events==["selection-read","publish","resume","dns","dns-readback"],"successful readback must precede all candidate exposure")
check(ConfigManager.shared.isRunning && ConfigManager.shared.apiPort=="new","verified candidate should publish")
check(accepted.completions.count==1 && accepted.completions[0]==nil,"verified candidate should complete once")
reset()
let oldGeneration=Probe();oldGeneration.readinessSucceeded();oldGeneration.enhancedModeGeneration+=1
oldGeneration.verification?(nil)
check(events==["selection-read"] && !ConfigManager.shared.isRunning,"old-generation readback must not publish candidate")
reset()
let oldLaunch=Probe();oldLaunch.readinessSucceeded();oldLaunch.activeEnhancedModeLaunchID=UUID()
oldLaunch.verification?(nil)
check(events==["selection-read"] && !ConfigManager.shared.isRunning,"old-launch readback must not publish candidate")
reset()
let terminating=Probe();terminating.readinessSucceeded();terminating.isTerminating=true
terminating.verification?(nil)
check(events==["selection-read"] && !ConfigManager.shared.isRunning,"termination must prevent candidate exposure")
print("PASS: actual launch block gates metadata/callbacks/DNS on successful selection readback; mismatch/old generation/old launch/termination stay unpublished")
"""
with tempfile.TemporaryDirectory(prefix='clashfx-launch-order-') as directory:
    d=Path(directory);p=d/'main.swift';p.write_text(header+body+tests);binary=d/'probe'
    subprocess.run(['swiftc',str(p),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=10)

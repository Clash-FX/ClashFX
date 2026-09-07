//
//  StartupProxyRecoveryPolicy.swift
//  ClashFX
//

import Foundation

struct StartupProxyRecoveryObservation {
    let wantsSystemProxy: Bool
    let proxyPaused: Bool
    let enhancedModeActive: Bool
    let initialConfigLoaded: Bool
    let coreRunning: Bool
    let httpPort: Int
    let socksPort: Int
    let helperReady: Bool
    let primaryInterfaceReady: Bool
}

enum StartupProxyRecoveryDecision: Equatable {
    case stop
    case waitForConfig
    case waitForCore
    case waitForHelper
    case waitForNetwork
    case verifyAndApply
}

enum StartupProxyRecoveryPolicy {
    static func decide(_ observation: StartupProxyRecoveryObservation) -> StartupProxyRecoveryDecision {
        guard observation.wantsSystemProxy,
              !observation.proxyPaused,
              !observation.enhancedModeActive else {
            return .stop
        }
        guard observation.initialConfigLoaded,
              observation.httpPort > 0,
              observation.socksPort > 0 else {
            return .waitForConfig
        }
        guard observation.coreRunning else { return .waitForCore }
        guard observation.helperReady else { return .waitForHelper }
        guard observation.primaryInterfaceReady else { return .waitForNetwork }
        return .verifyAndApply
    }
}

enum RuntimeDataPlaneProbeOutcome {
    case healthy
    case confirmedCoreFailure
    case baselineUnavailable
}

enum RuntimeDataPlaneFailurePolicy {
    static func nextFailureCount(
        current: Int,
        outcome: RuntimeDataPlaneProbeOutcome
    ) -> Int {
        switch outcome {
        case .healthy:
            return 0
        case .confirmedCoreFailure:
            return current + 1
        case .baselineUnavailable:
            // An unavailable independent baseline is inconclusive. Preserve the
            // prior evidence but neither forgive it nor count a new failure.
            return current
        }
    }
}

struct CoreCPUWatchdogSample: Equatable {
    let launchID: String
    let processIdentifier: Int
    let cpuTime: TimeInterval
    let sampleUptime: TimeInterval
}

enum CoreCPUWatchdogDecision: Equatable {
    case invalid
    case baseline
    case normal(utilization: Double)
    case elevated(utilization: Double, consecutiveSamples: Int)
    case captureDiagnostic(utilization: Double, consecutiveSamples: Int)
    case recover(utilization: Double, consecutiveSamples: Int)
}

/// Detects a process consuming approximately one complete CPU core over a
/// sustained period. Samples are tied to the helper launch identity and PID so
/// delayed replies from an older core cannot accumulate toward recovery.
struct CoreCPUWatchdogPolicy {
    let utilizationThreshold: Double
    let diagnosticSampleCount: Int
    let recoverySampleCount: Int
    let maximumSampleInterval: TimeInterval

    private var previousSample: CoreCPUWatchdogSample?
    private var consecutiveElevatedSamples = 0
    private var didRequestDiagnostic = false

    init(utilizationThreshold: Double = 0.90,
         diagnosticSampleCount: Int = 8,
         recoverySampleCount: Int = 12,
         maximumSampleInterval: TimeInterval = 45) {
        let validatedDiagnosticSampleCount = max(1, diagnosticSampleCount)
        self.utilizationThreshold = utilizationThreshold
        self.diagnosticSampleCount = validatedDiagnosticSampleCount
        self.recoverySampleCount = max(
            validatedDiagnosticSampleCount + 1,
            recoverySampleCount
        )
        self.maximumSampleInterval = maximumSampleInterval
    }

    mutating func reset() {
        previousSample = nil
        consecutiveElevatedSamples = 0
        didRequestDiagnostic = false
    }

    mutating func observe(_ sample: CoreCPUWatchdogSample) -> CoreCPUWatchdogDecision {
        guard sample.processIdentifier > 0,
              !sample.launchID.isEmpty,
              sample.cpuTime.isFinite,
              sample.sampleUptime.isFinite,
              sample.cpuTime >= 0,
              sample.sampleUptime >= 0 else {
            reset()
            return .invalid
        }

        guard let previousSample,
              previousSample.launchID == sample.launchID,
              previousSample.processIdentifier == sample.processIdentifier else {
            reset()
            previousSample = sample
            return .baseline
        }

        let elapsed = sample.sampleUptime - previousSample.sampleUptime
        let consumedCPU = sample.cpuTime - previousSample.cpuTime
        self.previousSample = sample
        guard elapsed > 0,
              elapsed <= maximumSampleInterval,
              consumedCPU >= 0,
              consumedCPU.isFinite else {
            consecutiveElevatedSamples = 0
            didRequestDiagnostic = false
            return .baseline
        }

        let utilization = consumedCPU / elapsed
        guard utilization.isFinite, utilization >= 0 else {
            reset()
            return .invalid
        }
        guard utilization >= utilizationThreshold else {
            consecutiveElevatedSamples = 0
            didRequestDiagnostic = false
            return .normal(utilization: utilization)
        }

        consecutiveElevatedSamples += 1
        if consecutiveElevatedSamples >= recoverySampleCount {
            let count = consecutiveElevatedSamples
            consecutiveElevatedSamples = 0
            didRequestDiagnostic = false
            return .recover(utilization: utilization, consecutiveSamples: count)
        }
        if consecutiveElevatedSamples >= diagnosticSampleCount,
           !didRequestDiagnostic {
            didRequestDiagnostic = true
            return .captureDiagnostic(
                utilization: utilization,
                consecutiveSamples: consecutiveElevatedSamples
            )
        }
        return .elevated(
            utilization: utilization,
            consecutiveSamples: consecutiveElevatedSamples
        )
    }
}

enum WakeRecoveryRetryPolicy {
    static func delay(
        baseDelay: TimeInterval,
        maximumAttempts: Int,
        attemptsLeft: Int
    ) -> TimeInterval {
        let completedAttempts = max(0, maximumAttempts - attemptsLeft)
        return min(baseDelay * pow(2, Double(completedAttempts)), 8)
    }
}

enum PortPreferencePolicy {
    static func editableText(configuredPort: Int) -> String {
        configuredPort > 0 ? String(configuredPort) : ""
    }

    static func configuredPort(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        guard let port = Int(trimmed), (1 ... 65_535).contains(port) else {
            return nil
        }
        return port
    }

    static func runtimeFallback(
        configuredPort: Int,
        runtimePort: Int
    ) -> (configured: Int, runtime: Int)? {
        guard configuredPort > 0,
              runtimePort > 0,
              configuredPort != runtimePort else { return nil }
        return (configuredPort, runtimePort)
    }
}

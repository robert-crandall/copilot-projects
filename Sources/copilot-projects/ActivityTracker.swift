import Foundation
import CopilotProjectsCore

enum FooterActivity: Equatable {
    case working
    case idle
    case unknown
}

/// Reducer for advisory status evidence. Hooks remain authoritative; a sustained
/// working footer may recover missed running state, while liveness and an observed
/// return to the idle footer may demote stale activity.
struct ActivityTracker {
    private var footerIdleTicks: [String: Int] = [:]
    private var footerWorkingTicks: [String: Int] = [:]
    private var footerSawWorking: Set<String> = []
    private var foregroundIdleTicks: [String: Int] = [:]
    private var disconnectIdleTicks: [String: Int] = [:]

    /// Demote a running session whose foreground turn has ended but whose scheduled
    /// or subagent work keeps `session.idle` from firing — so the hook path never
    /// demotes it and the tab stays falsely "working". Gated behind two
    /// consecutive scans reporting the foreground turn inactive: `assistant.turn_end`
    /// fires once per agentic-loop iteration, so a normal inter-iteration gap flips
    /// `foregroundTurnActive` false only momentarily and the next `turn_start`
    /// republishes before a second scan lands. Returns true once the ended-turn
    /// condition has persisted, at which point the caller drops the session to idle
    /// while leaving `activeSubagents` intact.
    mutating func observeForegroundIdle(
        sessionId: String,
        currentStatus: SessionStatus,
        foregroundTurnActive: Bool
    ) -> Bool {
        guard currentStatus == .running, !foregroundTurnActive else {
            foregroundIdleTicks[sessionId] = nil
            return false
        }
        let ticks = (foregroundIdleTicks[sessionId] ?? 0) + 1
        foregroundIdleTicks[sessionId] = ticks
        guard ticks >= 2 else { return false }
        foregroundIdleTicks[sessionId] = nil
        return true
    }

    mutating func observeDisconnectIdle(
        sessionId: String,
        currentStatus: SessionStatus
    ) -> Bool {
        guard currentStatus == .running else {
            disconnectIdleTicks[sessionId] = nil
            return false
        }
        let ticks = (disconnectIdleTicks[sessionId] ?? 0) + 1
        disconnectIdleTicks[sessionId] = ticks
        guard ticks >= 2 else { return false }
        disconnectIdleTicks[sessionId] = nil
        return true
    }

    mutating func shouldPromoteFromFooter(
        sessionId: String,
        currentStatus: SessionStatus,
        activity: FooterActivity
    ) -> Bool {
        guard currentStatus == .idle else {
            footerWorkingTicks[sessionId] = nil
            return false
        }
        guard activity == .working else {
            footerWorkingTicks[sessionId] = nil
            return false
        }
        let ticks = (footerWorkingTicks[sessionId] ?? 0) + 1
        footerWorkingTicks[sessionId] = ticks
        guard ticks >= 2 else { return false }
        footerWorkingTicks[sessionId] = nil
        footerSawWorking.insert(sessionId)
        footerIdleTicks[sessionId] = 0
        return true
    }

    mutating func observeFooter(
        sessionId: String,
        currentStatus: SessionStatus,
        activity: FooterActivity
    ) -> Bool {
        guard currentStatus == .running || currentStatus == .waiting else {
            reset(sessionId: sessionId)
            return false
        }

        switch activity {
        case .working:
            footerSawWorking.insert(sessionId)
            footerIdleTicks[sessionId] = 0
        case .unknown:
            footerIdleTicks[sessionId] = 0
        case .idle:
            guard footerSawWorking.contains(sessionId) else { return false }
            let ticks = (footerIdleTicks[sessionId] ?? 0) + 1
            footerIdleTicks[sessionId] = ticks
            if ticks >= 2 {
                reset(sessionId: sessionId)
                return true
            }
        }

        return false
    }

    mutating func retain(activeSessionIds: Set<String>) {
        footerIdleTicks = footerIdleTicks.filter { activeSessionIds.contains($0.key) }
        footerWorkingTicks = footerWorkingTicks.filter { activeSessionIds.contains($0.key) }
        footerSawWorking = footerSawWorking.intersection(activeSessionIds)
        foregroundIdleTicks = foregroundIdleTicks.filter { activeSessionIds.contains($0.key) }
        disconnectIdleTicks = disconnectIdleTicks.filter { activeSessionIds.contains($0.key) }
    }

    mutating func reset(sessionId: String) {
        footerIdleTicks[sessionId] = nil
        footerWorkingTicks[sessionId] = nil
        footerSawWorking.remove(sessionId)
        foregroundIdleTicks[sessionId] = nil
        disconnectIdleTicks[sessionId] = nil
    }

    mutating func resetForegroundIdle(sessionId: String) {
        foregroundIdleTicks[sessionId] = nil
    }

    mutating func resetDisconnectIdle(sessionId: String) {
        disconnectIdleTicks[sessionId] = nil
    }

    static func livenessShouldDemote(
        currentStatus: SessionStatus,
        hasLiveAgent: Bool
    ) -> Bool {
        (currentStatus == .running || currentStatus == .waiting) && !hasLiveAgent
    }

    static func canPromoteIdleFromFooter(
        backgroundAgentsActive: Bool,
        hasLiveAgent: Bool,
        supportsSessionIdleHook: Bool
    ) -> Bool {
        !backgroundAgentsActive && hasLiveAgent && !supportsSessionIdleHook
    }
}

struct StatusEventClock {
    private var latestTimestamp: [String: Int64] = [:]

    mutating func shouldApply(sessionId: String, timestamp: Int64?) -> Bool {
        guard let timestamp else { return true }
        if let latest = latestTimestamp[sessionId], timestamp < latest {
            return false
        }
        latestTimestamp[sessionId] = timestamp
        return true
    }

    mutating func seed(sessionId: String, timestamp: Int64?) {
        guard let timestamp else { return }
        latestTimestamp[sessionId] = max(latestTimestamp[sessionId] ?? timestamp, timestamp)
    }

    func timestamp(for sessionId: String) -> Int64? {
        latestTimestamp[sessionId]
    }

    mutating func reset(sessionId: String) {
        latestTimestamp[sessionId] = nil
    }
}

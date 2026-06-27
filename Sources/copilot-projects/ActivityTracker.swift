import Foundation
import CopilotProjectsCore

enum FooterActivity: Equatable {
    case working
    case idle
    case unknown
}

/// Reducer for advisory status evidence. Hooks remain authoritative for positive
/// transitions (running/waiting/idle). Liveness and footer observations may only
/// demote an existing active state to idle.
struct ActivityTracker {
    private var footerIdleTicks: [String: Int] = [:]
    private var footerSawWorking: Set<String> = []

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
        footerSawWorking = footerSawWorking.intersection(activeSessionIds)
    }

    mutating func reset(sessionId: String) {
        footerIdleTicks[sessionId] = nil
        footerSawWorking.remove(sessionId)
    }

    static func livenessShouldDemote(
        currentStatus: SessionStatus,
        hasLiveAgent: Bool
    ) -> Bool {
        (currentStatus == .running || currentStatus == .waiting) && !hasLiveAgent
    }
}

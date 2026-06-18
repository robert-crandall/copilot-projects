import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Minimal read-only view of the process tree, used to decide whether a coding
/// agent is still alive inside a session's shell.
enum ProcessTree {
    struct Snapshot {
        var childrenOf: [pid_t: [pid_t]] = [:]
        var nameOf: [pid_t: String] = [:]
    }

    /// One pass over all processes: parent links + short process names.
    static func snapshot() -> Snapshot {
        var snap = Snapshot()
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return snap }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride + 128
        var pids = [pid_t](repeating: 0, count: capacity)
        let returned = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                     Int32(capacity * MemoryLayout<pid_t>.stride))
        guard returned > 0 else { return snap }
        let count = min(Int(returned) / MemoryLayout<pid_t>.stride, pids.count)

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            let got = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
            guard got == size else { continue }
            let ppid = pid_t(bitPattern: info.pbsi_ppid)
            let name = withUnsafeBytes(of: info.pbsi_comm) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            snap.childrenOf[ppid, default: []].append(pid)
            snap.nameOf[pid] = name
        }
        return snap
    }

    /// True if any descendant of `root` has a process name in `names`.
    static func hasDescendant(under root: pid_t, named names: Set<String>, in snap: Snapshot) -> Bool {
        guard root > 0, !names.isEmpty else { return false }
        var stack = snap.childrenOf[root] ?? []
        var visited = Set<pid_t>()
        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            if let name = snap.nameOf[pid], names.contains(name) { return true }
            if let kids = snap.childrenOf[pid] { stack.append(contentsOf: kids) }
        }
        return false
    }
}

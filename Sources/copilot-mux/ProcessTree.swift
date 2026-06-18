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

    /// argv + environment of a process via KERN_PROCARGS2 (same-uid only).
    static func inspect(_ pid: pid_t) -> (args: [String], env: [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size < MemoryLayout<Int32>.size {
            return ([], [:])
        }
        var buffer = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 { return ([], [:]) }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: src[0..<4]))
            }
        }

        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }      // skip exec_path
        while i < size && buffer[i] == 0 { i += 1 }      // skip alignment nulls

        func nextCString() -> String {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            let s = String(decoding: buffer[start..<i], as: UTF8.self)
            if i < size { i += 1 }
            return s
        }

        var args: [String] = []
        var n = 0
        while n < Int(max(0, argc)) && i < size {
            args.append(nextCString())
            n += 1
        }

        var env: [String: String] = [:]
        while i < size {
            let kv = nextCString()
            if let eq = kv.firstIndex(of: "=") {
                env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
            }
        }
        return (args, env)
    }

    /// Sessions (by COPILOT_MUX_SESSION env) that currently host a live agent
    /// process. Works regardless of how the shell is wrapped (dtach or direct).
    static func agentSessions(agentNames: Set<String>, in snap: Snapshot) -> Set<String> {
        var sessions = Set<String>()
        for (pid, name) in snap.nameOf where agentNames.contains(name) {
            if let sid = inspect(pid).env["COPILOT_MUX_SESSION"], !sid.isEmpty {
                sessions.insert(sid)
            }
        }
        return sessions
    }

    /// The dtach master process owning a given session socket (for kill).
    static func dtachMaster(forSocket socket: String, in snap: Snapshot) -> pid_t? {
        for (pid, name) in snap.nameOf where name == "dtach" {
            if inspect(pid).args.contains(socket) { return pid }
        }
        return nil
    }
}

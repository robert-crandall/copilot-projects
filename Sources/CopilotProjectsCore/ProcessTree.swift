import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Minimal read-only view of the process tree, used to decide whether a coding
/// agent is still alive inside a session's shell.
public enum ProcessTree {
    public struct Snapshot {
        public var childrenOf: [pid_t: [pid_t]] = [:]
        public var parentOf: [pid_t: pid_t] = [:]
        public var nameOf: [pid_t: String] = [:]

        public init() {}
    }

    /// One pass over all processes: parent links + short process names.
    public static func snapshot() -> Snapshot {
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
            snap.parentOf[pid] = ppid
            snap.nameOf[pid] = name
        }
        return snap
    }

    /// True if any descendant of `root` has a process name in `names`.
    public static func hasDescendant(under root: pid_t, named names: Set<String>, in snap: Snapshot) -> Bool {
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
    public static func inspect(_ pid: pid_t) -> (args: [String], env: [String: String]) {
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

    /// Sessions (by COPILOT_PROJECTS_SESSION env) that currently host a live agent
    /// process. Works regardless of how the shell is wrapped (dtach or direct).
    public static func agentSessions(agentNames: Set<String>, in snap: Snapshot) -> Set<String> {
        var sessions = Set<String>()
        for (pid, name) in snap.nameOf where agentNames.contains(name) {
            if let sid = Env.sessionId(inspect(pid).env) {
                sessions.insert(sid)
            }
        }
        return sessions
    }

    /// The dtach master owning a given session socket (for kill). A newly-created
    /// master is initially a child of the creating/attached dtach client; after that
    /// client exits it is reparented to launchd (PID 1). A later reattach creates an
    /// unrelated client. In every state the client and master share the socket argv.
    public static func dtachMaster(forSocket socket: String, in snap: Snapshot) -> pid_t? {
        dtachMaster(forSocket: socket, among: dtachProcesses(in: snap))
    }

    public struct DtachProcess {
        public let pid: pid_t
        public let parentPID: pid_t
        public let socketPath: String?
        public let isMaster: Bool

        public init(pid: pid_t, parentPID: pid_t, socketPath: String?, isMaster: Bool) {
            self.pid = pid
            self.parentPID = parentPID
            self.socketPath = socketPath
            self.isMaster = isMaster
        }
    }

    public static func dtachProcesses(in snap: Snapshot) -> [DtachProcess] {
        let raw: [DtachProcess] = snap.nameOf.compactMap { pid, name in
            guard name == "dtach" else { return nil }
            let args = inspect(pid).args
            let socket = args.first {
                $0.hasSuffix(".sock") && $0.contains("/sessions/")
            }
            let parent = snap.parentOf[pid] ?? 0
            return DtachProcess(
                pid: pid,
                parentPID: parent,
                socketPath: socket,
                isMaster: false
            )
        }
        return raw.map { process in
            DtachProcess(
                pid: process.pid,
                parentPID: process.parentPID,
                socketPath: process.socketPath,
                isMaster: isDtachMaster(process, among: raw)
            )
        }
    }

    public static func dtachMaster(
        forSocket socket: String,
        among processes: [DtachProcess]
    ) -> pid_t? {
        let matching = processes.filter { $0.socketPath == socket }
        return matching.first { isDtachMaster($0, among: matching) }?.pid
    }

    private static func isDtachMaster(
        _ process: DtachProcess,
        among processes: [DtachProcess]
    ) -> Bool {
        process.parentPID == 1
            || processes.contains {
                $0.pid == process.parentPID && $0.socketPath == process.socketPath
            }
    }
}

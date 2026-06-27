import Foundation
import Darwin
import CopilotProjectsCore

/// Process-lifetime exclusive lock for the GUI instance sharing a state directory.
final class AppInstanceLock {
    private var fd: Int32 = -1

    func acquire(path: String = Paths.instanceLockPath) -> Bool {
        guard fd < 0 else { return true }
        Paths.ensureStateDir()
        let candidate = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard candidate >= 0 else {
            NSLog("copilot-projects: could not open instance lock \(path), errno \(errno)")
            return false
        }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            close(candidate)
            return false
        }
        fd = candidate
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    deinit {
        if fd >= 0 {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
    }
}

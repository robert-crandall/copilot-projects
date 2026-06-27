import Foundation
import Darwin
import CopilotProjectsCore

enum SessionArtifacts {
    static func destroy(sessionId: String, snapshot: ProcessTree.Snapshot? = nil) {
        let socket = Paths.dtachSocketPath(sessionId: sessionId)
        if Paths.dtachExecutable != nil {
            let processes = snapshot ?? ProcessTree.snapshot()
            // Kill both the attached client and master. This also closes the tiny
            // creation race where only the client is visible before it forks the
            // master; killing just a selected master could miss that case.
            for process in ProcessTree.dtachProcesses(in: processes)
                where process.socketPath == socket {
                kill(process.pid, SIGTERM)
            }
        }
        removeFiles(sessionId: sessionId)
    }

    static func removeFiles(sessionId: String) {
        let fm = FileManager.default
        for path in [
            Paths.dtachSocketPath(sessionId: sessionId),
            Paths.statusMarkerPath(sessionId: sessionId),
            Paths.copilotSessionMarkerPath(sessionId: sessionId),
        ] {
            try? fm.removeItem(atPath: path)
        }
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#endif
import CopilotProjectsCore

/// Accepts one-shot JSON-line requests on a Unix domain socket and replies with
/// one JSON-line response. The handler runs on the server's background queue;
/// it is responsible for any main-actor hop it needs.
final class ControlServer {
    private let socketPath: String
    private let handler: (ControlRequest) -> ControlResponse
    private var listenFD: Int32 = -1
    private var running = false
    private var boundSocket = false
    private let queue = DispatchQueue(label: "com.obvioussean.copilot-projects.control")

    init(socketPath: String = Paths.socketPath,
         handler: @escaping (ControlRequest) -> ControlResponse) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() {
        Paths.ensureStateDir()
        // Don't steal the socket from a still-running instance (possible during the
        // bundle-id transition, when macOS no longer treats old + new as one app):
        // only remove a stale socket file that nothing is listening on.
        if socketIsAlive(socketPath) {
            NSLog("copilot-projects control: another instance is already listening on \(socketPath); not starting a second control server")
            return
        }
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("copilot-projects control: socket() failed errno \(errno)")
            return
        }
        // Don't let spawned children (each dtach helper, and the shells under them)
        // inherit the listening socket. Without FD_CLOEXEC every dtach we launch keeps
        // a copy of this fd open, leaking one descriptor per session/relaunch and
        // pinning the socket inode — over a long-lived app that grows without bound.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else {
            NSLog("copilot-projects control: socket path too long")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }

        let bound = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            NSLog("copilot-projects control: bind failed errno \(errno)")
            close(fd)
            return
        }
        chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            NSLog("copilot-projects control: listen failed errno \(errno)")
            close(fd)
            return
        }

        listenFD = fd
        running = true
        boundSocket = true
        queue.async { [weak self] in self?.acceptLoop() }
        NSLog("copilot-projects control: listening on \(socketPath)")
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if boundSocket {
            unlink(socketPath)
            boundSocket = false
        }
    }

    /// True if a process is currently accepting on `path` (a live listener), vs. a
    /// stale leftover socket file that connect() refuses with ECONNREFUSED.
    private func socketIsAlive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let r = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return r == 0
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            // Spawned children must not inherit live client connections either.
            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
            handleClient(clientFD)
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }
        guard !data.isEmpty else { return }

        let line = data.firstIndex(of: 0x0A)
            .map { data.subdata(in: data.startIndex..<$0) } ?? data

        let response: ControlResponse
        do {
            let req = try Wire.decode(ControlRequest.self, from: line)
            response = handler(req)
        } catch {
            response = .failure("bad request: \(error)")
        }

        guard let out = try? Wire.encodeLine(response) else { return }
        out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(fd, base + off, raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum SocketOptions {
    /// Prevent a write to a disconnected peer from terminating the process with
    /// SIGPIPE. The write still fails with EPIPE so callers can handle it normally.
    @discardableResult
    public static func suppressSigPipe(on fd: Int32) -> Bool {
        #if canImport(Darwin)
        var enabled: Int32 = 1
        return setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0
        #else
        return true
        #endif
    }
}

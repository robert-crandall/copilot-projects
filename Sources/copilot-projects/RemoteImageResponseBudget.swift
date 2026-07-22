import Foundation

/// Process/gateway-wide bound on the total bytes of terminal-image response
/// *bodies* currently queued for write across every open NIO connection at
/// once — independent of, and in addition to, `RemoteKittyImageCaptureBudget`
/// (which bounds retained/in-flight-transmission bytes per terminal). Without
/// this, N concurrent terminal-image requests — each up to
/// `remoteKittyMaxDecodedImageBytes` (5 MiB) — could each have their PNG
/// bytes handed to NIO to queue into a slow/backed-up client's outbound
/// buffer, and that per-request cost multiplies unbounded by however many
/// concurrent image requests happen to be in flight process-wide.
///
/// `RemoteGateway`'s NIO event loop group can run more than one thread, and a
/// reservation for one connection's response can race a release for another
/// connection's on a different event loop, so — unlike the main-actor-only
/// `RemoteKittyImageCaptureBudget` — this type guards its state with a plain
/// lock (mirroring `RemoteWriterLeases` below) rather than actor isolation,
/// making it safe to call from any thread.
final class RemoteImageResponseBudget: @unchecked Sendable {
    /// The real process-wide instance `RemoteGateway` uses by default. Tests
    /// inject their own isolated instance (with a much smaller bound) so an
    /// assertion about the shared budget being exhausted is never at the
    /// mercy of unrelated tests' leftover reservations.
    static let shared = RemoteImageResponseBudget(maxTotalBytes: 16 * 1_024 * 1_024)

    let maxTotalBytes: Int

    private let lock = NSLock()
    private var reservedBytes = 0

    init(maxTotalBytes: Int = 16 * 1_024 * 1_024) {
        self.maxTotalBytes = maxTotalBytes
    }

    var totalReservedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return reservedBytes
    }

    /// Attempts to reserve `bytes` more of the shared budget for one
    /// about-to-be-queued image response body. Returns `false` (reserving
    /// nothing at all — never a partial amount) if this would push the
    /// process-wide total over `maxTotalBytes`; the caller must then reject
    /// the request outright (e.g. 429/503) rather than writing the body.
    func reserve(bytes: Int) -> Bool {
        guard bytes > 0 else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard reservedBytes + bytes <= maxTotalBytes else { return false }
        reservedBytes += bytes
        return true
    }

    /// Releases exactly the bytes previously granted by a matching
    /// successful `reserve` call. Callers must only invoke this once that
    /// reservation's body write future has completed or failed — never
    /// earlier (e.g. not merely once the write call returns), since until
    /// then the bytes may still be sitting in the channel's own outbound
    /// buffer consuming real memory. Idempotent-safe against being called
    /// with `0`.
    func release(bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        reservedBytes = max(0, reservedBytes - bytes)
    }
}

import Foundation

/// Process-wide memory budget shared across every `RemoteKittyImageCapture`
/// instance (one per open terminal session). A per-session cap alone can't
/// bound total memory — N open terminals each retaining their own per-session
/// cap scales with N — so this tracks every retained (owner, id, version)
/// entry across the whole process and evicts oldest-first (preferring already
/// -superseded versions over any still-current one) once either the shared
/// byte or entry-count bound is exceeded, regardless of which capture(s) the
/// evicted entries belong to.
///
/// Owners are held weakly: a capture that's deallocated (its terminal session
/// closed) is never explicitly unregistered, it just naturally drops out of
/// accounting the next time any registration triggers `enforceBounds()`,
/// which prunes any entry whose owner has already gone away.
///
/// Main-actor-only, matching every `RemoteKittyImageCapture` access, so there
/// is no data race between one terminal's capture retaining data and another's
/// eviction reclaiming it.
@MainActor
final class RemoteKittyImageCaptureBudget {
    /// The real process-wide instance every `RemoteKittyImageCapture` uses by
    /// default. Tests inject their own isolated instance instead, so a
    /// process-wide assertion about "global" bounds is never at the mercy of
    /// unrelated tests' leftover captures.
    static let shared = RemoteKittyImageCaptureBudget()

    let maxTotalBytes: Int
    let maxTotalEntries: Int
    /// Process-wide cap on *in-flight, undecoded* base64 bytes across every
    /// still-open transmission of every owner combined — independent of
    /// `maxTotalBytes`, which only bounds already-finalized, retained decoded
    /// images. Without this, each open terminal could separately buffer up to
    /// its own local `remoteKittyMaxAccumulatedBase64Bytes` (8 MiB) worth of
    /// pending, never-finalized transmission data, and that per-terminal cap
    /// multiplies unbounded by however many terminals happen to be open.
    let maxTotalPendingBytes: Int

    init(
        maxTotalBytes: Int = 32 * 1_024 * 1_024,
        maxTotalEntries: Int = 32,
        maxTotalPendingBytes: Int = 8 * 1_024 * 1_024
    ) {
        self.maxTotalBytes = maxTotalBytes
        self.maxTotalEntries = maxTotalEntries
        self.maxTotalPendingBytes = maxTotalPendingBytes
    }

    private struct GlobalKey: Hashable {
        let ownerId: ObjectIdentifier
        let imageId: UInt32
        let version: UInt64
    }

    private struct Entry {
        weak var owner: RemoteKittyImageCapture?
        let imageId: UInt32
        let version: UInt64
        let bytes: Int
    }

    // Oldest-first, mirroring each capture's own local `order`; `entries` and
    // `totalBytes` are kept in lockstep with it.
    private var order: [GlobalKey] = []
    private var entries: [GlobalKey: Entry] = [:]

    private(set) var totalBytes = 0
    var totalEntries: Int { order.count }

    /// Registers exactly one retained `(imageId, version)` entry for `owner`
    /// with its exact byte size, then enforces the shared bound — which may
    /// synchronously evict this or any other owner's entry (including,
    /// rarely, the one just registered) if the process-wide budget is now
    /// exceeded.
    func register(owner: RemoteKittyImageCapture, imageId: UInt32, version: UInt64, bytes: Int) {
        let key = GlobalKey(ownerId: ObjectIdentifier(owner), imageId: imageId, version: version)
        guard entries[key] == nil else { return }
        order.append(key)
        entries[key] = Entry(owner: owner, imageId: imageId, version: version, bytes: bytes)
        totalBytes += bytes
        enforceBounds()
    }

    /// Removes accounting for an entry `owner` already evicted locally (its
    /// own per-session cap, or an explicit Kitty delete command) — so the
    /// shared totals never double-count data that's no longer retained
    /// anywhere.
    func unregister(owner: RemoteKittyImageCapture, imageId: UInt32, version: UInt64) {
        remove(GlobalKey(ownerId: ObjectIdentifier(owner), imageId: imageId, version: version))
    }

    private func remove(_ key: GlobalKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalBytes -= entry.bytes
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
    }

    private func enforceBounds() {
        pruneOrphanedOwners()
        while order.count > maxTotalEntries || totalBytes > maxTotalBytes {
            guard let victim = pickEvictionVictim() else { break }
            evict(victim)
        }
    }

    /// An owner that's already been deallocated can never be asked to evict
    /// itself, so its stale accounting is reclaimed unconditionally, ahead of
    /// any age/superseded-based comparison against still-live owners.
    private func pruneOrphanedOwners() {
        let orphaned = order.filter { entries[$0]?.owner == nil }
        for key in orphaned { remove(key) }
    }

    /// Oldest-first, but a still-live owner's already-superseded version
    /// (i.e. not that id's `currentVersion` any more) is always preferred for
    /// eviction over any still-current entry, no matter how much older that
    /// current entry is — so hitting the shared bound never drops a version a
    /// client might currently be looking at as long as some obsolete version
    /// exists anywhere in the process to sacrifice instead.
    private func pickEvictionVictim() -> GlobalKey? {
        guard !order.isEmpty else { return nil }
        for key in order {
            guard let entry = entries[key], let owner = entry.owner else { continue }
            if owner.currentVersion(for: entry.imageId) != entry.version {
                return key
            }
        }
        return order.first
    }

    private func evict(_ key: GlobalKey) {
        guard let entry = entries[key] else { return }
        let owner = entry.owner
        remove(key)
        owner?.evictForBudget(imageId: entry.imageId, version: entry.version)
    }

    // MARK: - Pending (in-flight, undecoded) transmission bytes

    private struct PendingEntry {
        weak var owner: RemoteKittyImageCapture?
        var bytes: Int
    }

    // Keyed by owner identity (never by image id/version — a transmission
    // isn't retained data yet, just bytes accumulating toward one), so an
    // owner's whole in-flight buffer is tracked as a single reservation that
    // grows/shrinks with each chunk rather than one entry per chunk.
    private var pendingByOwner: [ObjectIdentifier: PendingEntry] = [:]
    // Oldest-first, mirroring `order` for retained entries above and kept in
    // lockstep with `pendingByOwner`'s keys, so eviction can always find the
    // oldest *other* in-flight owner deterministically rather than at the
    // mercy of dictionary iteration order.
    private var pendingOrder: [ObjectIdentifier] = []

    private(set) var totalPendingBytes = 0

    /// Attempts to reserve `additionalBytes` more in-flight bytes on top of
    /// whatever `owner` already has reserved. If `owner`'s own request alone
    /// (its existing reservation plus `additionalBytes`) already exceeds
    /// `maxTotalPendingBytes`, this fails immediately without touching any
    /// other owner's reservation — see the fast-path check below. Otherwise,
    /// if the process-wide pending total would be pushed over the bound,
    /// this next tries to make room by aborting the oldest *other* in-flight
    /// owner(s) — safe to discard unconditionally, since unvalidated pending
    /// data isn't real data any other owner could be relying on yet, unlike
    /// the retained-bytes budget above which must pick an eviction victim
    /// carefully. Only if every other owner has been aborted and `owner`'s
    /// own reservation still wouldn't fit does this return `false`, in which
    /// case the caller must abort its own in-flight transmission instead —
    /// this prevents one stalled/never-finalized transfer from permanently
    /// monopolizing the shared pending budget and starving every other
    /// terminal's ability to ever complete one.
    func reservePending(owner: RemoteKittyImageCapture, additionalBytes: Int) -> Bool {
        pruneOrphanedPendingOwners()
        guard additionalBytes > 0 else { return true }
        let key = ObjectIdentifier(owner)
        // Fast path: if `owner`'s own existing reservation plus this request
        // already exceeds the whole shared bound on its own, no amount of
        // evicting *other* owners can ever make it fit — so bail out before
        // touching any of them. Without this check, an owner requesting an
        // unsatisfiable reservation would first collaterally abort every
        // other innocent in-flight owner's transmission (each a real,
        // independent client's in-progress upload) for no benefit whatsoever,
        // since the reservation was always going to fail regardless.
        let currentOwnerBytes = pendingByOwner[key]?.bytes ?? 0
        guard currentOwnerBytes + additionalBytes <= maxTotalPendingBytes else { return false }
        if totalPendingBytes + additionalBytes > maxTotalPendingBytes {
            evictOldestOtherPendingOwners(except: key, toFit: additionalBytes)
        }
        guard totalPendingBytes + additionalBytes <= maxTotalPendingBytes else {
            // Only `owner` itself (or nobody) is left reserved and it still
            // doesn't fit — nothing left to sacrifice.
            return false
        }
        if pendingByOwner[key] == nil {
            pendingOrder.append(key)
        }
        let current = pendingByOwner[key]?.bytes ?? 0
        pendingByOwner[key] = PendingEntry(owner: owner, bytes: current + additionalBytes)
        totalPendingBytes += additionalBytes
        return true
    }

    /// Aborts oldest *other* (never `exceptKey`, the owner making the new
    /// reservation) in-flight owners, one at a time, until `additionalBytes`
    /// more would fit within `maxTotalPendingBytes` or there's no other owner
    /// left to abort.
    private func evictOldestOtherPendingOwners(except exceptKey: ObjectIdentifier, toFit additionalBytes: Int) {
        for candidateKey in pendingOrder where candidateKey != exceptKey {
            guard totalPendingBytes + additionalBytes > maxTotalPendingBytes else { break }
            abortPendingEntry(for: candidateKey)
        }
    }

    /// Removes one owner's pending accounting and tells it to abort its own
    /// in-flight transmission — the pending-bytes counterpart to `evict(_:)`
    /// for retained entries above. Never called for the owner currently
    /// reserving (see `evictOldestOtherPendingOwners`).
    private func abortPendingEntry(for key: ObjectIdentifier) {
        guard let entry = pendingByOwner.removeValue(forKey: key) else { return }
        totalPendingBytes -= entry.bytes
        if let index = pendingOrder.firstIndex(of: key) { pendingOrder.remove(at: index) }
        entry.owner?.abortPendingForBudget()
    }

    /// Releases every pending byte currently reserved for `owner` — the exact
    /// counterpart to every successful `reservePending` call for it — called
    /// whenever its in-flight transmission ends for any reason (begins a new
    /// one, overflows, finalizes successfully or not, or is discarded by an
    /// explicit delete/clear). Idempotent: a no-op if nothing is reserved.
    func releasePending(owner: RemoteKittyImageCapture) {
        let key = ObjectIdentifier(owner)
        guard let entry = pendingByOwner.removeValue(forKey: key) else { return }
        totalPendingBytes -= entry.bytes
        if let index = pendingOrder.firstIndex(of: key) { pendingOrder.remove(at: index) }
    }

    /// A deallocated owner (its terminal session closed mid-transmission)
    /// never calls `releasePending` itself, so its reservation is reclaimed
    /// unconditionally the next time any owner attempts to reserve more.
    private func pruneOrphanedPendingOwners() {
        let orphaned = pendingByOwner.filter { $0.value.owner == nil }
        for (key, entry) in orphaned {
            totalPendingBytes -= entry.bytes
            pendingByOwner.removeValue(forKey: key)
            if let index = pendingOrder.firstIndex(of: key) { pendingOrder.remove(at: index) }
        }
    }
}

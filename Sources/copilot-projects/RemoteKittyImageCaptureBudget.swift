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

    init(
        maxTotalBytes: Int = 32 * 1_024 * 1_024,
        maxTotalEntries: Int = 32
    ) {
        self.maxTotalBytes = maxTotalBytes
        self.maxTotalEntries = maxTotalEntries
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
}

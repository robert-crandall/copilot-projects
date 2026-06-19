import Foundation

enum LegacyDefaults {
    /// The app's UserDefaults live in a domain keyed by the bundle id. The rebrand
    /// changes the bundle id, which would otherwise reset everything persisted
    /// there — most visibly the saved sidebar width and window frame. This makes a
    /// one-time copy of the old domain into the current one. Notification
    /// authorization is keyed to the bundle id by macOS and cannot be copied, so it
    /// re-prompts once.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        let flag = "legacyDefaultsMigrated.v1"
        guard !defaults.bool(forKey: flag) else { return }
        if let old = defaults.persistentDomain(forName: "com.obvioussean.copilot-mux") {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: flag)
    }
}

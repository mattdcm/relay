import AppKit

/// Remembers the last time you interacted with each app, that is, the last
/// time it was in front (the app in front receives the keyboard and clicks).
/// In memory only: nothing is saved.
final class Activity {
    private var lastUsed: [pid_t: Date] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        if let front = NSWorkspace.shared.frontmostApplication {
            lastUsed[front.processIdentifier] = Date()
        }
        // An app counts as "used" until it leaves the front.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.lastUsed[app.processIdentifier] = Date()
            })
        }
    }

    /// Apps used less than `interval` ago (nil: no limit), among those that have
    /// windows (`windowOrder`, from front to back).
    /// There are always at least two, the active app and the previous one, so that
    /// ⌘⇥ can always switch between them.
    func recentApps(within interval: TimeInterval?, windowOrder: [pid_t]) -> Set<pid_t> {
        var order: [pid_t] = []
        for pid in windowOrder where !order.contains(pid) { order.append(pid) }
        guard let interval else { return Set(order) }

        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var recent = Set(order.filter { pid in
            pid == front || lastUsed[pid].map { Date().timeIntervalSince($0) <= interval } ?? false
        })
        // Not enough apps: add the last used one, otherwise the next one on screen.
        while recent.count < 2,
              let previous = order.filter({ !recent.contains($0) })
                  .max(by: { (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast) }) {
            recent.insert(previous)
        }
        return recent
    }
}

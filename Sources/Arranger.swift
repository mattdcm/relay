import AppKit

/// Applies a layout: opens its apps and moves their windows into their
/// zones, through the Accessibility API.
enum Arranger {
    private typealias Place = (title: String, rect: CGRect)

    static func apply(_ layout: Layout) {
        // Target places for each app: one per window reference.
        var targets: [String: [Place]] = [:]
        for display in Displays.current() {
            for zone in layout.screens[display.id] ?? [] {
                let rect = zone.frame(in: display.frame)
                for window in zone.windows { targets[window.app, default: []].append((window.title, rect)) }
            }
        }
        for (bundleID, places) in targets { place(bundleID, places, attemptsLeft: 10) }
    }

    /// Moves the app's windows into their zones.
    /// A specific window is found by its title, or else takes the next free
    /// window of the app (titles change, in a browser for example). A reference
    /// to the whole app takes all the windows left, spread over its zones.
    /// If the app is not running or has no window yet, opens it and tries
    /// again every second, ten times at most.
    private static func place(_ bundleID: String, _ places: [Place], attemptsLeft: Int) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            var windows = WindowList.standardWindows(of: app)
            if !windows.isEmpty {
                let title = { (window: AXUIElement) -> String in WindowList.attribute(window, kAXTitleAttribute) ?? "" }
                // Exact titles first, so that a fallback never takes a window
                // that another reference names.
                var unmatched: [Place] = []
                for place in places where !place.title.isEmpty {
                    if let index = windows.firstIndex(where: { title($0) == place.title }) {
                        WindowList.setFrame(windows.remove(at: index), place.rect)
                    } else {
                        unmatched.append(place)
                    }
                }
                for place in unmatched where !windows.isEmpty {
                    WindowList.setFrame(windows.removeFirst(), place.rect)
                }
                let wholeApp = places.filter { $0.title.isEmpty }
                if !wholeApp.isEmpty {
                    for (index, window) in windows.enumerated() {
                        WindowList.setFrame(window, wholeApp[index % wholeApp.count].rect)
                    }
                }
                return
            }
        } else if attemptsLeft == 10, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            place(bundleID, places, attemptsLeft: attemptsLeft - 1)
        }
    }
}

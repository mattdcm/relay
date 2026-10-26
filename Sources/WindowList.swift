import AppKit
import ApplicationServices

/// A window that can be shown in the switcher.
struct WindowItem {
    let element: AXUIElement        // the window, as seen by the Accessibility API
    let app: NSRunningApplication
    let title: String
    let windowID: CGWindowID?       // window number for the WindowServer (used for previews)
    let isOnScreen: Bool            // false if minimized, hidden…
    let isMinimized: Bool
    /// One of Relay's own windows (the layout editor). Handled with AppKit:
    /// Relay does not query itself through the Accessibility API.
    var own: NSWindow? = nil
}

/// Lists windows and brings them to the front, only through the public
/// Accessibility API. No screen image is read here.
enum WindowList {

    /// Window numbers in the order you used them, most recent first. Bringing an
    /// app to the front raises all its windows, so the stacking order alone would
    /// put the app's other windows before the window you came from.
    private static var recent: [CGWindowID] = []
    private static var activationObserver: NSObjectProtocol?

    /// Records a window as the one used most recently.
    private static func touch(_ id: CGWindowID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 300 { recent.removeLast() }
    }

    /// The front window of an app, in the stacking order.
    private static func touchFront(of pid: pid_t) {
        if let front = windows(onScreenOnly: true).first(where: { $0.pid == pid }) { touch(front.id) }
    }

    /// Follows the apps you bring to the front, however you do it (click, Dock…).
    static func startTracking() {
        guard activationObserver == nil else { return }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { touchFront(of: pid) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Once the app has raised its windows, its front one is the one in use.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { WindowList.touchFront(of: app.processIdentifier) }
        }
    }

    /// Windows of all applications, from most recent to oldest.
    static func current() -> [WindowItem] {
        let order = windows(onScreenOnly: true)   // stacking order, visible only
        // The window in front is the one in use, even if you reached it with a
        // click inside the same app.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let front = order.first(where: { $0.pid == pid }) { touch(front.id) }
        let all = windows(onScreenOnly: false)    // including minimized and hidden
        var used = Set<CGWindowID>()
        var result: [(rank: Int, item: WindowItem)] = []

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid()
        }
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            let windows: [AXUIElement] = attribute(axApp, kAXWindowsAttribute) ?? []
            for window in windows {
                // Skip palettes, panels and other floating windows.
                guard attribute(window, kAXSubroleAttribute) as String? == kAXStandardWindowSubrole else { continue }
                let minimized = attribute(window, kAXMinimizedAttribute) as Bool? ?? false
                let frame = WindowList.frame(of: window)
                // Find the window number from its app and position.
                let isSame = { (w: ServerWindow) in
                    w.pid == app.processIdentifier && w.frame.isClose(to: frame) && !used.contains(w.id)
                }
                let rank = minimized ? nil : order.firstIndex(where: isSame)
                let id = rank.map { order[$0].id } ?? all.first(where: isSame)?.id
                if let id { used.insert(id) }
                let title = attribute(window, kAXTitleAttribute) as String? ?? ""
                let item = WindowItem(element: window, app: app,
                                      title: title.isEmpty ? (app.localizedName ?? "") : title,
                                      windowID: id, isOnScreen: rank != nil,
                                      isMinimized: minimized)
                result.append((rank ?? Int.max, item))
            }
        }
        // Relay's own windows, such as the layout editor (not its menus or panels).
        for window in NSApp.windows where window.isVisible || window.isMiniaturized {
            guard window.styleMask.contains(.titled), !(window is NSPanel) else { continue }
            let id = CGWindowID(window.windowNumber)
            let rank = window.isMiniaturized ? nil : order.firstIndex { $0.id == id }
            let item = WindowItem(element: AXUIElementCreateApplication(getpid()), app: .current,
                                  title: window.title, windowID: id, isOnScreen: rank != nil,
                                  isMinimized: window.isMiniaturized, own: window)
            result.append((rank ?? Int.max, item))
        }
        // Windows you used first, from most recent; then the others, front to back.
        func lastUse(_ item: WindowItem) -> Int { item.windowID.flatMap { recent.firstIndex(of: $0) } ?? Int.max }
        return result
            .sorted { (lastUse($0.item), $0.rank, $0.item.app.localizedName ?? "") < (lastUse($1.item), $1.rank, $1.item.app.localizedName ?? "") }
            .map(\.item)
    }

    /// Brings the window to the front.
    static func focus(_ item: WindowItem) {
        if let id = item.windowID { touch(id) }
        if let window = item.own {
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        if item.app.isHidden { item.app.unhide() }
        if item.isMinimized {
            AXUIElementSetAttributeValue(item.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let axApp = AXUIElementCreateApplication(item.app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(item.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
    }

    /// Normal windows (neither minimized nor palettes) of an app.
    static func standardWindows(of app: NSRunningApplication) -> [AXUIElement] {
        let windows: [AXUIElement] = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) ?? []
        return windows.filter {
            attribute($0, kAXSubroleAttribute) as String? == kAXStandardWindowSubrole &&
            !(attribute($0, kAXMinimizedAttribute) as Bool? ?? false)
        }
    }

    /// Moves and resizes a window (rectangle with top-left origin).
    static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = AXUIElementCreateApplication(pid)
        // Some apps (Chromium and Electron based ones, for example) ignore size
        // changes while their "enhanced user interface" is on, which other
        // accessibility tools turn on. It is turned off during the change.
        let enhanced: Bool = attribute(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        apply(rect, to: window)
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }

        // Some apps resize asynchronously or refuse a size while the window is
        // still on another screen: check shortly after and try once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let frame = WindowList.frame(of: window)
            guard abs(frame.width - rect.width) > 2 || abs(frame.height - rect.height) > 2
                    || abs(frame.minX - rect.minX) > 2 || abs(frame.minY - rect.minY) > 2 else { return }
            WindowList.apply(rect, to: window)
        }
    }

    /// Moves and resizes a window at once, without the checks of setFrame:
    /// for live changes that are repeated while the mouse moves.
    static func setFrameNow(_ window: AXUIElement, _ rect: CGRect) {
        apply(rect, to: window)
    }

    /// Size, position, size, then position again: macOS limits the size to the
    /// screen the window is on, and changing the size can shift the window
    /// when it moves from one screen to another.
    private static func apply(_ rect: CGRect, to window: AXUIElement) {
        var origin = rect.origin, size = rect.size
        guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }

    /// The window in front.
    static func focusedWindow() -> AXUIElement? {
        // Never Relay itself: it cannot answer its own Accessibility requests
        // while it is busy asking.
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Called on each click: an app that does not respond must not block Relay.
        AXUIElementSetMessagingTimeout(element, 0.3)
        return attribute(element, kAXFocusedWindowAttribute)
    }

    // MARK: - Details

    private typealias ServerWindow = (id: CGWindowID, pid: pid_t, frame: CGRect)

    /// Windows known to the WindowServer, from front to back.
    /// Without the Screen Recording permission, macOS only gives here the
    /// number, app and position of each window: that is all we need.
    private static func windows(onScreenOnly: Bool) -> [ServerWindow] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return (id, pid, frame)
        }
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func frame(of window: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let value: AXValue = attribute(window, kAXPositionAttribute) { AXValueGetValue(value, .cgPoint, &origin) }
        if let value: AXValue = attribute(window, kAXSizeAttribute) { AXValueGetValue(value, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }
}

private extension CGRect {
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 2 && abs(minY - other.minY) < 2 &&
        abs(width - other.width) < 2 && abs(height - other.height) < 2
    }
}

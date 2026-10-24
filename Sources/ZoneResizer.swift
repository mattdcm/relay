import AppKit

/// When a window that fills a zone of the current layout is resized by hand,
/// the zone follows it: the lines it shares with its neighbours move, the
/// neighbouring zones shrink or grow, and the windows in them follow, live
/// while the mouse moves. When the button is released, the layout is saved
/// with its new lines.
final class ZoneResizer {
    /// How far (in points) an edge may be from a zone's edge and still match it.
    private static let tolerance: CGFloat = 12
    private static let minSize: CGFloat = 0.05      // as a fraction of the screen
    private static let epsilon: CGFloat = 0.001

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "resizeNeighbours") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "resizeNeighbours") }
    }

    /// A window being resized in its zone.
    private struct Session {
        let window: AXUIElement
        let before: CGRect
        let screen: CGRect
        let zone: Zone
        let zones: [Zone]
        let original: [CGRect]                               // zones before the resize (fractions)
        let followers: [(window: AXUIElement, zone: Zone)]   // windows filling the other zones
        var shown: [CGRect]                                  // where the followers were last put
    }

    private var session: Session?
    private var notInZone = false    // the window being resized is not in a zone

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.maxX - b.maxX) < tolerance && abs(a.maxY - b.maxY) < tolerance
    }

    /// Starts following a window whose size is changing, if it fills a zone.
    private func begin(_ window: AXUIElement, from before: CGRect, layout: Layout) -> Bool {
        if session != nil { return true }
        if notInZone { return false }
        guard Self.isEnabled,
              let display = Displays.current().first(where: { $0.frame.contains(CGPoint(x: before.midX, y: before.midY)) }),
              let zones = layout.screens[display.id],
              let zone = zones.first(where: { Self.matches($0.frame(in: display.frame), before) })
        else {
            notInZone = true
            return false
        }
        let screen = display.frame
        var followers: [(window: AXUIElement, zone: Zone)] = []
        for item in WindowList.current() where item.own == nil && !item.isMinimized && !CFEqual(item.element, window) {
            let frame = WindowList.frame(of: item.element)
            if let other = zones.first(where: { $0 !== zone && Self.matches($0.frame(in: screen), frame) }) {
                followers.append((item.element, other))
            }
        }
        session = Session(window: window, before: before, screen: screen, zone: zone, zones: zones,
                          original: zones.map(\.rect), followers: followers,
                          shown: followers.map { $0.zone.frame(in: screen) })
        return true
    }

    /// Puts the zones back as they were, then moves the lines the window's
    /// edges moved. Returns true if a line moved.
    private func compute(_ session: Session, after: CGRect) -> Bool {
        for (zone, rect) in zip(session.zones, session.original) { zone.rect = rect }
        let screen = session.screen, before = session.before, zone = session.zone
        var changed = false
        // Each edge of the window that moved, and is not on the screen's border.
        let edges: [(vertical: Bool, end: Bool, old: CGFloat, new: CGFloat)] = [
            (true, false, before.minX, after.minX), (true, true, before.maxX, after.maxX),
            (false, false, before.minY, after.minY), (false, true, before.maxY, after.maxY),
        ]
        for edge in edges where abs(edge.new - edge.old) > 3 {
            let origin: CGFloat = edge.vertical ? screen.minX : screen.minY
            let length: CGFloat = edge.vertical ? screen.width : screen.height
            let position: CGFloat = edge.vertical
                ? (edge.end ? zone.rect.maxX : zone.rect.minX)
                : (edge.end ? zone.rect.maxY : zone.rect.minY)
            guard position > Self.epsilon, position < 1 - Self.epsilon else { continue }
            let wanted: CGFloat = (edge.new - origin) / length
            if Self.moveLine(at: position, vertical: edge.vertical, from: zone, to: wanted, in: session.zones) { changed = true }
        }
        return changed
    }

    /// While the mouse moves: the other windows follow the lines.
    func update(_ window: AXUIElement, from before: CGRect, layout: Layout) {
        guard begin(window, from: before, layout: layout), var session else { return }
        _ = compute(session, after: WindowList.frame(of: window))
        for (index, follower) in session.followers.enumerated() {
            let target = follower.zone.frame(in: session.screen)
            guard target != session.shown[index] else { continue }
            WindowList.setFrameNow(follower.window, target)
            session.shown[index] = target
        }
        self.session = session
    }

    /// When the button is released: returns the layout with its new zones, or
    /// nil if the window was not in a zone or nothing changed.
    func finish(_ window: AXUIElement, from before: CGRect, to after: CGRect, layout: Layout) -> Layout? {
        defer {
            session = nil
            notInZone = false
        }
        guard begin(window, from: before, layout: layout), let session else { return nil }
        let changed = compute(session, after: after)
        // The resized window fits its zone exactly, the others theirs.
        WindowList.setFrame(window, session.zone.frame(in: session.screen))
        for follower in session.followers { WindowList.setFrame(follower.window, follower.zone.frame(in: session.screen)) }
        return changed ? layout : nil
    }

    /// The button was released without any resize.
    func cancel() {
        session = nil
        notInZone = false
    }

    /// Moves the line at `position` that the zone touches, with every zone
    /// along it that is joined to the zone. Returns false if it could not move.
    private static func moveLine(at position: CGFloat, vertical: Bool, from zone: Zone, to wanted: CGFloat, in zones: [Zone]) -> Bool {
        func start(_ z: Zone) -> CGFloat { vertical ? z.rect.minX : z.rect.minY }
        func end(_ z: Zone) -> CGFloat { vertical ? z.rect.maxX : z.rect.maxY }
        func low(_ z: Zone) -> CGFloat { vertical ? z.rect.minY : z.rect.minX }
        func high(_ z: Zone) -> CGFloat { vertical ? z.rect.maxY : z.rect.maxX }
        func onLine(_ z: Zone) -> Bool { abs(start(z) - position) < epsilon || abs(end(z) - position) < epsilon }
        func overlaps(_ a: Zone, _ b: Zone) -> Bool { min(high(a), high(b)) - max(low(a), low(b)) > epsilon }

        let line: [Zone] = zones.filter(onLine)
        var group: [Zone] = [zone]
        var added = true
        while added {
            added = false
            for other in line where !group.contains(where: { $0 === other }) {
                if group.contains(where: { overlaps($0, other) }) {
                    group.append(other)
                    added = true
                }
            }
        }
        let before: [Zone] = group.filter { abs(end($0) - position) < epsilon }
        let after: [Zone] = group.filter { abs(start($0) - position) < epsilon }
        guard !before.isEmpty, !after.isEmpty else { return false }
        var lowest: CGFloat = 0, highest: CGFloat = 1
        for z in before { lowest = max(lowest, start(z) + minSize) }
        for z in after { highest = min(highest, end(z) - minSize) }
        guard lowest <= highest else { return false }
        let new: CGFloat = min(highest, max(lowest, wanted))
        guard abs(new - position) > epsilon else { return false }
        for z in before {
            if vertical { z.rect.size.width = new - z.rect.minX } else { z.rect.size.height = new - z.rect.minY }
        }
        for z in after {
            if vertical {
                z.rect = CGRect(x: new, y: z.rect.minY, width: z.rect.maxX - new, height: z.rect.height)
            } else {
                z.rect = CGRect(x: z.rect.minX, y: new, width: z.rect.width, height: z.rect.maxY - new)
            }
        }
        return true
    }
}

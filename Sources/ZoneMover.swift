import AppKit

/// Zone mode of the switcher: during ⌘⇥, pressing the arrows (⌘ still held)
/// shows the zones of the current layout on every screen and moves the
/// selected window from zone to zone, live. Releasing ⌘ keeps it there;
/// ⇥ keeps it there and goes back to the switcher to pick another window;
/// Esc puts it back where it was.
final class ZoneMover {
    enum Direction { case left, right, up, down }

    private(set) var isActive = false
    private var window: AXUIElement?
    private var original = CGRect.zero
    private var wasMinimized = false
    private var previousApp: NSRunningApplication?
    private var zones: [CGRect] = []      // every zone, on every screen (origin at the top left)
    private var current: Int?             // zone the window is in
    private var overlays: [NSPanel] = []
    /// Each screen and the range of its zones in `zones` (numbered per screen).
    private var screens: [(frame: CGRect, range: Range<Int>)] = []
    private var typedNumber = 0
    private var typingTimer: Timer?

    /// Zones of a screen in reading order, or its left and right halves when
    /// the layout has fewer than two zones there.
    static func zones(on display: Display, layout: Layout?) -> [CGRect] {
        let rects = Zone.sorted(layout?.screens[display.id] ?? []).map { $0.frame(in: display.frame) }
        if rects.count >= 2 { return rects }
        return [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
            .map { Zone(rect: $0).frame(in: display.frame) }
    }

    /// Starts with the window chosen in the switcher, and brings it to the front.
    func start(_ item: WindowItem, layout: Layout?) {
        previousApp = NSWorkspace.shared.frontmostApplication
        wasMinimized = item.isMinimized
        original = WindowList.frame(of: item.element)
        window = item.element
        WindowList.focus(item)

        zones = []
        screens = []
        current = nil
        for display in Displays.current() {
            let rects = Self.zones(on: display, layout: layout)
            screens.append((display.frame, zones.count..<(zones.count + rects.count)))
            zones += rects
            showOverlay(on: display, zones: rects)
        }
        isActive = true
    }

    /// Moves the window to the nearest zone in that direction.
    func move(_ direction: Direction) {
        guard isActive, let window else { return }
        let from: CGPoint
        if let current {
            from = CGPoint(x: zones[current].midX, y: zones[current].midY)
        } else {
            from = CGPoint(x: original.midX, y: original.midY)
        }
        var best: (index: Int, score: CGFloat)?
        for (index, zone) in zones.enumerated() where index != current {
            let dx: CGFloat = zone.midX - from.x
            let dy: CGFloat = zone.midY - from.y   // grows downwards
            let along: CGFloat
            let across: CGFloat
            switch direction {
            case .right: along = dx; across = dy
            case .left: along = -dx; across = dy
            case .down: along = dy; across = dx
            case .up: along = -dy; across = dx
            }
            guard along > 1 else { continue }
            // Straight ahead counts more than off to the side.
            let score: CGFloat = along + 2 * abs(across)
            if let best, best.score <= score { continue }
            best = (index, score)
        }
        // First press with nothing in that direction: the zone the window is in.
        if best == nil, current == nil, let inside = zones.firstIndex(where: { $0.contains(from) }) {
            best = (inside, 0)
        }
        guard let target = best?.index else { return }
        current = target
        WindowList.setFrame(window, zones[target])
        for panel in overlays { (panel.contentView as? ZoneOverlayView)?.highlighted = zones[target] }
    }

    /// A digit typed with ⌘ held: moves the window to the zone with that
    /// number on the screen it is on. With 10 zones or more, waits a moment
    /// for a second digit (to type 10, 11…) unless no longer number exists.
    func typed(_ digit: Int) {
        guard isActive, let screen = currentScreen else { return }
        typingTimer?.invalidate()
        typedNumber = typedNumber * 10 + digit
        let number = typedNumber
        if number * 10 > screen.range.count {
            go(to: number)
        } else {
            typingTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.go(to: number) }
        }
    }

    /// The screen the window is on (by its center).
    private var currentScreen: (frame: CGRect, range: Range<Int>)? {
        let rect = current.map { zones[$0] } ?? original
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return screens.first { $0.frame.contains(center) } ?? screens.first
    }

    private func go(to number: Int) {
        typingTimer?.invalidate()
        typingTimer = nil
        typedNumber = 0
        guard isActive, let window, let screen = currentScreen, number >= 1, number <= screen.range.count else { return }
        let target = screen.range.lowerBound + number - 1
        current = target
        WindowList.setFrame(window, zones[target])
        for panel in overlays { (panel.contentView as? ZoneOverlayView)?.highlighted = zones[target] }
    }

    /// Keeps the window where it is.
    func commit() {
        guard isActive else { return }
        reset()
    }

    /// Puts the window back where it was, and returns to the previous app.
    func cancel() {
        guard isActive else { return }
        if let window {
            WindowList.setFrame(window, original)
            if wasMinimized {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
        previousApp?.activate()
        reset()
    }

    private func reset() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        zones = []
        screens = []
        typingTimer?.invalidate()
        typingTimer = nil
        typedNumber = 0
        current = nil
        window = nil
        previousApp = nil
        isActive = false
    }

    private func showOverlay(on display: Display, zones: [CGRect]) {
        let panel = NSPanel(contentRect: Displays.cocoaRect(display.frame),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = ZoneOverlayView(frame: NSRect(origin: .zero, size: display.frame.size))
        view.origin = display.frame.origin
        view.zones = zones
        panel.contentView = view
        panel.orderFrontRegardless()
        overlays.append(panel)
    }
}

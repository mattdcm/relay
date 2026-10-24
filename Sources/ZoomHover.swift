import AppKit

/// When the pointer rests on a window's green button, shows next to it a
/// strip of thumbnails: one per zone of the current layout. A click moves
/// the window into that zone.
/// Apple's menu is not modified (it belongs to each app): Relay shows its
/// own panel next to it. Only reads the pointer position and, through
/// Accessibility, the type of button under it.
final class ZoomHover {
    var currentLayout: () -> Layout? = { nil }

    private var timer: Timer?
    private let systemWide = AXUIElementCreateSystemWide()
    private var lastMouse = CGPoint(x: -1, y: -1)
    private var hovered: (button: CGRect, since: Date)?   // green button under the pointer
    private var panel: NSPanel?
    private var panelButton = CGRect.null                  // button the panel is open for
    private var panelRect = CGRect.null                    // the panel, origin at the top left
    private var outsideSince: Date?
    /// The window and the zones the panel is open for, and digits typed so far.
    private var target: (window: AXUIElement, zones: [CGRect])?
    private var typedNumber = 0
    private var typingTimer: Timer?

    var isShowing: Bool { panel != nil }

    private let delay: TimeInterval = 0.5       // time resting on the button before showing
    private let hideDelay: TimeInterval = 0.8   // time outside the button and the panel before hiding

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "zoomHover") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "zoomHover"); newValue ? start() : stop() }
    }

    func start() {
        guard isEnabled, timer == nil else { return }
        // An app that does not respond must not block Relay.
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hide()
    }

    private func tick() {
        let cocoa = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouse = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)   // origin at the top left

        if panel != nil {
            // Panel open: keep it while the pointer is on the button, the panel, or
            // on its way between them (across Apple's menu).
            let inside = panelButton.union(panelRect).insetBy(dx: -8, dy: -8).contains(mouse)
            if inside { outsideSince = nil } else if let since = outsideSince {
                if Date().timeIntervalSince(since) > hideDelay { hide() }
            } else {
                outsideSince = Date()
            }
            return
        }

        guard mouse != lastMouse || hovered != nil else { return }
        let moved = mouse != lastMouse
        lastMouse = mouse
        if moved {
            if let hovered, hovered.button.contains(mouse) { return }
            hovered = greenButton(at: mouse).map { (button: $0, since: Date()) }
            return
        }
        // The pointer has rested on the button long enough.
        if let hovered, Date().timeIntervalSince(hovered.since) >= delay {
            self.hovered = nil
            show(for: hovered.button, at: mouse)
        }
    }

    /// Halves, thirds and full screen, in fractions of the screen.
    private static let presets: [CGRect] = [
        CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
        CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1), CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1),
        CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1), CGRect(x: 0, y: 0, width: 1, height: 1),
    ]

    /// The window a button belongs to: its window attribute, or else the first
    /// parent whose role is a window.
    private static func window(of element: AXUIElement) -> AXUIElement? {
        if let window: AXUIElement = WindowList.attribute(element, kAXWindowAttribute) { return window }
        var current = element
        for _ in 0..<5 {
            guard let parent: AXUIElement = WindowList.attribute(current, kAXParentAttribute) else { return nil }
            if WindowList.attribute(parent, kAXRoleAttribute) as String? == kAXWindowRole { return parent }
            current = parent
        }
        return nil
    }

    /// Frame of the green button under this point, if any.
    private func greenButton(at point: CGPoint) -> CGRect? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element,
              let subrole: String = WindowList.attribute(element, kAXSubroleAttribute),
              subrole == kAXFullScreenButtonSubrole || subrole == kAXZoomButtonSubrole
        else { return nil }
        return WindowList.frame(of: element)
    }

    private func show(for button: CGRect, at mouse: CGPoint) {
        // The window is the button's window: find it by asking for the element again.
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(mouse.x), Float(mouse.y), &element) == .success,
              let element, let window = Self.window(of: element)
        else { return }

        let windowFrame = WindowList.frame(of: window)
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        let displays = Displays.current()
        guard let display = displays.first(where: { $0.frame.contains(center) }) ?? displays.first else { return }
        // Zones of the current layout, or common presets when there is none for this screen.
        let layout = currentLayout()
        var zones: [CGRect] = Zone.sorted(layout?.screens[display.id] ?? []).map { $0.frame(in: display.frame) }
        var title = "Your current Relay layout: \(layout?.name ?? "")"
        if zones.count < 2 {
            zones = Self.presets.map { Zone(rect: $0).frame(in: display.frame) }
            title = "No Relay layout for this screen. Quick positions:"
        }

        target = (window, zones)
        let strip = ZoneStrip(zones: zones, screen: display.frame)
        strip.onPick = { [weak self] rect in
            self?.hide()
            WindowList.setFrame(window, rect)
        }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        let size = NSSize(width: max(strip.frame.width, label.frame.width + 16), height: strip.frame.height + 20)
        label.frame.origin = NSPoint(x: 8, y: size.height - 20)
        strip.frame.origin = NSPoint(x: (size.width - strip.frame.width) / 2, y: 0)

        let origin = Self.position(size: size, button: button, screen: display.frame)
        let panel = NSPanel(contentRect: Displays.cocoaRect(CGRect(origin: origin, size: size)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.addSubview(label)
        background.addSubview(strip)
        panel.contentView = background
        panel.acceptsMouseMovedEvents = true
        panel.orderFrontRegardless()
        self.panel = panel
        panelButton = button
        panelRect = CGRect(origin: origin, size: size)
        outsideSince = nil
    }

    /// Size of Apple's own menu under the green button (an estimate: macOS does
    /// not give it).
    private static let appleMenu = CGSize(width: 250, height: 230)

    /// Where to put the panel (origin at the top left): below Apple's menu if
    /// there is room on the screen, otherwise to its right, otherwise above the button.
    private static func position(size: CGSize, button: CGRect, screen: CGRect) -> CGPoint {
        let below = CGPoint(x: button.minX - 8, y: button.maxY + appleMenu.height + 8)
        let right = CGPoint(x: button.minX + appleMenu.width + 8, y: button.maxY + 4)
        let above = CGPoint(x: button.minX - 8, y: button.minY - size.height - 8)
        var origin: CGPoint
        if below.y + size.height <= screen.maxY {
            origin = below
        } else if right.x + size.width <= screen.maxX, right.y + size.height <= screen.maxY {
            origin = right
        } else {
            origin = above
        }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        return origin
    }

    /// A digit typed while the panel is shown: moves the window to the zone
    /// with that number. With 10 zones or more, waits a moment for a second
    /// digit (to type 10, 11…) unless no longer number exists.
    func typed(_ digit: Int) {
        guard let target else { return }
        typingTimer?.invalidate()
        typedNumber = typedNumber * 10 + digit
        let number = typedNumber
        if number * 10 > target.zones.count {
            pick(number)
        } else {
            typingTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.pick(number) }
        }
    }

    private func pick(_ number: Int) {
        typingTimer?.invalidate()
        typingTimer = nil
        typedNumber = 0
        guard let target, number >= 1, number <= target.zones.count else { return }
        hide()
        WindowList.setFrame(target.window, target.zones[number - 1])
    }

    private func hide() {
        target = nil
        typedNumber = 0
        typingTimer?.invalidate()
        typingTimer = nil
        panel?.orderOut(nil)
        panel = nil
        panelButton = .null
        panelRect = .null
        outsideSince = nil
    }
}

/// The strip of thumbnails: each one shows the screen with one zone in color.
private final class ZoneStrip: NSView {
    var onPick: (CGRect) -> Void = { _ in }

    private let zones: [CGRect]
    private let screen: CGRect
    private let tile: NSSize
    private let padding: CGFloat = 6, spacing: CGFloat = 4
    private var hoveredIndex: Int? { didSet { needsDisplay = true } }

    init(zones: [CGRect], screen: CGRect) {
        self.zones = zones
        self.screen = screen
        let height: CGFloat = 40
        tile = NSSize(width: (height * screen.width / max(screen.height, 1)).rounded(), height: height)
        let count = CGFloat(zones.count)
        let width: CGFloat = 2 * padding + count * tile.width + (count - 1) * spacing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height + 2 * padding))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func tileRect(_ index: Int) -> CGRect {
        CGRect(x: padding + CGFloat(index) * (tile.width + spacing), y: padding, width: tile.width, height: tile.height)
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return zones.indices.first { tileRect($0).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) { hoveredIndex = index(at: event) }
    override func mouseExited(with event: NSEvent) { hoveredIndex = nil }
    override func mouseDown(with event: NSEvent) {
        if let index = index(at: event) { onPick(zones[index]) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = tile.width / max(screen.width, 1)
        for (index, zone) in zones.enumerated() {
            let rect = tileRect(index)
            let outline = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            NSColor.labelColor.withAlphaComponent(index == hoveredIndex ? 0.25 : 0.1).setFill()
            outline.fill()
            NSColor.labelColor.withAlphaComponent(0.4).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            let x: CGFloat = rect.minX + (zone.minX - screen.minX) * scale
            let y: CGFloat = rect.minY + (zone.minY - screen.minY) * scale
            let inner = CGRect(x: x, y: y, width: zone.width * scale, height: zone.height * scale).insetBy(dx: 1.5, dy: 1.5)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2).fill()
            // Zone number, as in the layout editor.
            let number = "\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white,
            ]
            let textSize = number.size(withAttributes: attributes)
            number.draw(at: CGPoint(x: inner.midX - textSize.width / 2, y: inner.midY - textSize.height / 2),
                        withAttributes: attributes)
        }
    }
}

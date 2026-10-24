import AppKit

/// Mouse snapping: when you drag a window by its title bar, the zones of the
/// current layout appear. Released over the central half of a zone, the
/// window takes the place of that zone; released anywhere else, it simply
/// stays where macOS moved it.
/// Also notices when a window is resized with the mouse (see ZoneResizer).
/// Only watches mouse clicks and drags, and never blocks them.
final class Snapper {
    var currentLayout: () -> Layout? = { nil }
    /// A window was resized with the mouse: its frame before and after.
    var onResize: (_ window: AXUIElement, _ before: CGRect, _ after: CGRect) -> Void = { _, _, _ in }
    /// The size of the window changes while the mouse moves (live).
    var onResizing: (_ window: AXUIElement, _ before: CGRect) -> Void = { _, _ in }
    /// The button was released without resizing a window.
    var onNoResize: () -> Void = {}
    private var resizeTick = Date.distantPast
    private var resizePending = false
    private var pressed: (window: AXUIElement, frame: CGRect)?   // focused window when the button was pressed

    private var tap: CFMachPort?
    private var downPoint: CGPoint?        // where the button was pressed
    private var dragged: AXUIElement?      // window being moved
    private var overlays: [NSPanel] = []
    private var zones: [CGRect] = []
    private var target: CGRect?

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "dragZones") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dragZones"); if !newValue { hideOverlays() } }
    }

    /// The central part of a zone, half of its area, where a drop snaps.
    static func center(of zone: CGRect) -> CGRect {
        let side: CGFloat = 0.5.squareRoot()
        return zone.insetBy(dx: zone.width * (1 - side) / 2, dy: zone.height * (1 - side) / 2)
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                Unmanaged<Snapper>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .leftMouseDown:
            downPoint = event.location
            dragged = nil
            pressed = WindowList.focusedWindow().map { ($0, WindowList.frame(of: $0)) }

        case .leftMouseDragged:
            // Only react once the pointer has really moved, and if the drag
            // started in a window's title bar (not on its top edge, which resizes).
            if let start = downPoint, hypot(event.location.x - start.x, event.location.y - start.y) > 6 {
                downPoint = nil
                if isEnabled, let window = WindowList.focusedWindow() {
                    let frame = WindowList.frame(of: window)
                    let titleBar = CGRect(x: frame.minX, y: frame.minY + 5, width: frame.width, height: 35)
                    dragged = titleBar.contains(start) ? window : nil
                }
            }
            // Not a title bar: maybe the window is being resized by one of its edges.
            if dragged == nil, downPoint == nil, let pressed, !resizePending,
               Date().timeIntervalSince(resizeTick) > 0.06 {
                resizeTick = Date()
                resizePending = true
                let window = pressed.window, before = pressed.frame
                DispatchQueue.main.async { [weak self] in
                    self?.resizePending = false
                    let now = WindowList.frame(of: window)
                    if abs(now.width - before.width) > 3 || abs(now.height - before.height) > 3 {
                        self?.onResizing(window, before)
                    }
                }
            }
            guard isEnabled, dragged != nil else { return }
            showOverlays()
            target = zones.first { Self.center(of: $0).contains(event.location) }
            for panel in overlays { (panel.contentView as? ZoneOverlayView)?.highlighted = target }

        case .leftMouseUp:
            if let target, let window = dragged, !overlays.isEmpty {
                // macOS finishes the move first, then the window is placed.
                DispatchQueue.main.async { WindowList.setFrame(window, target) }
            }
            // A window whose size changed during the drag was resized by hand.
            if dragged == nil, downPoint == nil, let pressed {
                let window = pressed.window, before = pressed.frame
                DispatchQueue.main.async { [weak self] in
                    let after = WindowList.frame(of: window)
                    if abs(after.width - before.width) > 3 || abs(after.height - before.height) > 3 {
                        self?.onResize(window, before, after)
                    } else {
                        self?.onNoResize()
                    }
                }
            }
            pressed = nil
            dragged = nil
            downPoint = nil
            hideOverlays()

        default: break
        }
    }

    private func showOverlays() {
        guard overlays.isEmpty, let layout = currentLayout() else { return }
        for display in Displays.current() {
            let rects = ZoneMover.zones(on: display, layout: layout)
            zones += rects
            let panel = NSPanel(contentRect: Displays.cocoaRect(display.frame),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = ZoneOverlayView(frame: NSRect(origin: .zero, size: display.frame.size))
            view.origin = display.frame.origin
            view.zones = rects
            view.showsCenters = true
            panel.contentView = view
            panel.orderFrontRegardless()
            overlays.append(panel)
        }
    }

    private func hideOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        zones = []
        target = nil
    }
}

/// Draws the zones of a screen above the windows.
final class ZoneOverlayView: NSView {
    var origin = CGPoint.zero            // screen corner, to convert to local coordinates
    var zones: [CGRect] = []
    var highlighted: CGRect? { didSet { needsDisplay = true } }
    /// Draws the central half of each zone, where a dragged window snaps.
    var showsCenters = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for zone in zones {
            let path = NSBezierPath(roundedRect: zone.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 6, dy: 6),
                                    xRadius: 10, yRadius: 10)
            let fill = zone == highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.35)
                                           : NSColor.black.withAlphaComponent(0.12)
            fill.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
            if showsCenters {
                let center = NSBezierPath(roundedRect: Snapper.center(of: zone).offsetBy(dx: -origin.x, dy: -origin.y),
                                          xRadius: 8, yRadius: 8)
                center.setLineDash([8, 6], count: 2, phase: 0)
                center.lineWidth = 2
                NSColor.white.withAlphaComponent(0.7).setStroke()
                center.stroke()
            }
        }
        // Zone numbers, in reading order as in the editor (⌘ + number during ⌘⇥).
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .strokeColor: NSColor.black.withAlphaComponent(0.5), .strokeWidth: -2,
        ]
        for (index, zone) in zones.enumerated() {
            let text = "\(index + 1)" as NSString
            let size = text.size(withAttributes: attributes)
            let rect = zone.offsetBy(dx: -origin.x, dy: -origin.y)
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

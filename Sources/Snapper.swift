import AppKit

/// Mouse snapping: when you drag a window while holding ⇧, the zones of the
/// current layout appear. On release, the window takes the place of the zone
/// under the pointer.
/// Only watches mouse clicks and drags, and never blocks them.
final class Snapper {
    var currentLayout: () -> Layout? = { nil }

    private var tap: CFMachPort?
    private var downPoint: CGPoint?        // where the button was pressed
    private var dragged: AXUIElement?      // window being moved
    private var overlays: [NSPanel] = []
    private var zones: [CGRect] = []
    private var target: CGRect?

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

        case .leftMouseDragged:
            // Only react if the drag started in a window's title bar (and not,
            // for example, during a text selection with ⇧).
            if let start = downPoint, let window = WindowList.focusedWindow() {
                let frame = WindowList.frame(of: window)
                let titleBar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 40)
                dragged = titleBar.contains(start) ? window : nil
                downPoint = nil
            }
            guard dragged != nil, event.flags.contains(.maskShift) else { return hideOverlays() }
            showOverlays()
            target = zones.first { $0.contains(event.location) }
            for panel in overlays { (panel.contentView as? OverlayView)?.highlighted = target }

        case .leftMouseUp:
            if let target, let window = dragged, !overlays.isEmpty {
                // macOS finishes the move first, then the window is placed.
                DispatchQueue.main.async { WindowList.setFrame(window, target) }
            }
            dragged = nil
            downPoint = nil
            hideOverlays()

        default: break
        }
    }

    private func showOverlays() {
        guard overlays.isEmpty, let layout = currentLayout() else { return }
        for display in Displays.current() {
            guard let screenZones = layout.screens[display.id] else { continue }
            let rects = screenZones.map { $0.frame(in: display.frame) }
            zones += rects
            let panel = NSPanel(contentRect: Displays.cocoaRect(display.frame),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = OverlayView(frame: NSRect(origin: .zero, size: display.frame.size))
            view.origin = display.frame.origin
            view.zones = rects
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
private final class OverlayView: NSView {
    var origin = CGPoint.zero            // screen corner, to convert to local coordinates
    var zones: [CGRect] = []
    var highlighted: CGRect? { didSet { needsDisplay = true } }

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
        }
    }
}

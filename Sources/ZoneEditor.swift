import AppKit

/// Layout editing window: each screen is cut into zones, their size is
/// adjusted, and open windows are dragged from the list below onto a zone.
/// A window belongs to one zone at most.
/// Several zones can be selected together (⇧ or ⌘ + click) to merge them,
/// cut them with one line, or move the line they share.
final class ZoneEditor: NSObject, NSWindowDelegate {
    /// Keeps the editor alive while its window is open.
    private static var current: ZoneEditor?

    private var layout: Layout
    private let onSave: (Layout) -> Void
    private let window: NSWindow
    private let canvas = ZoneCanvas()
    private let tray = NSScrollView()
    /// Open windows shown in the list below the screen, with their app icon.
    private let openWindows: [(ref: WindowRef, icon: NSImage)]
    private let nameField = NSTextField()
    private let screenPopup = NSPopUpButton()
    private let screenIDs: [String]
    private var screenID: String?
    private var buttons: [String: NSButton] = [:]

    static func open(_ layout: Layout, onSave: @escaping (Layout) -> Void) {
        current?.window.close()
        current = ZoneEditor(layout: layout, onSave: onSave)
        NSApp.activate()
        current?.window.center()
        current?.window.makeKeyAndOrderFront(nil)
    }

    private init(layout original: Layout, onSave: @escaping (Layout) -> Void) {
        var copy = original
        copy.screens = original.screens.mapValues { Zone.sorted(Zone.copy($0)) }
        layout = copy
        var seen: [WindowRef] = []
        var list: [(ref: WindowRef, icon: NSImage)] = []
        for item in WindowList.current() where item.own == nil {
            guard let app = item.app.bundleIdentifier else { continue }
            let ref = WindowRef(app: app, title: item.title)
            guard !seen.contains(ref) else { continue }
            seen.append(ref)
            list.append((ref: ref, icon: item.app.icon ?? NSImage()))
        }
        openWindows = list
        self.onSave = onSave
        screenIDs = copy.screens.keys.sorted { (copy.screenNames[$0] ?? "") < (copy.screenNames[$1] ?? "") }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 660),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Edit Layout"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildInterface()
        showScreen(0)
    }

    func windowWillClose(_ notification: Notification) {
        if ZoneEditor.current === self { ZoneEditor.current = nil }
    }

    // MARK: - Interface

    private func buildInterface() {
        let content = window.contentView!

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 20, y: 621, width: 50, height: 20)
        content.addSubview(nameLabel)
        nameField.stringValue = layout.name
        nameField.frame = NSRect(x: 72, y: 618, width: 300, height: 24)
        content.addSubview(nameField)

        screenPopup.frame = NSRect(x: 500, y: 616, width: 260, height: 26)
        screenPopup.addItems(withTitles: screenIDs.map { layout.screenNames[$0] ?? "Screen" })
        screenPopup.target = self
        screenPopup.action = #selector(screenChanged)
        screenPopup.isHidden = screenIDs.count < 2
        content.addSubview(screenPopup)

        var x: CGFloat = 20
        for (key, title, action) in [
            ("vertical", "Split Left | Right", #selector(splitVertically)),
            ("horizontal", "Split Top / Bottom", #selector(splitHorizontally)),
            ("merge", "Merge", #selector(merge)),
            ("clear", "Remove Windows", #selector(removeWindows)),
        ] {
            let button = NSButton(title: title, target: self, action: action)
            button.sizeToFit()
            button.frame.origin = NSPoint(x: x, y: 574)
            x += button.frame.width + 8
            content.addSubview(button)
            buttons[key] = button
        }

        canvas.frame = NSRect(x: 20, y: 60, width: 760, height: 504)
        canvas.onChange = { [weak self] in self?.updateButtons() }
        canvas.onDrop = { [weak self] index, zone in self?.place(index, in: zone) }
        canvas.registerForDraggedTypes([.relayWindow])
        content.addSubview(canvas)

        let trayLabel = NSTextField(wrappingLabelWithString: "Open windows: drag each one onto a zone. A window goes in one zone at most.")
        trayLabel.font = .systemFont(ofSize: 11, weight: .medium)
        trayLabel.frame = NSRect(x: 800, y: 616, width: 280, height: 30)
        content.addSubview(trayLabel)
        tray.frame = NSRect(x: 800, y: 60, width: 280, height: 548)
        tray.hasVerticalScroller = true
        tray.borderType = .bezelBorder
        tray.drawsBackground = false
        content.addSubview(tray)

        let hint = NSTextField(labelWithString:
            "Click a zone to select it, ⇧-click to select several. Drag a line to resize: it moves only\n"
            + "where it touches the zone under the pointer, or along all selected zones.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.frame = NSRect(x: 20, y: 14, width: 760, height: 32)
        content.addSubview(hint)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 890, y: 14, width: 90, height: 32)
        content.addSubview(cancel)
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 990, y: 14, width: 90, height: 32)
        content.addSubview(save)
    }

    private func showScreen(_ index: Int) {
        guard screenIDs.indices.contains(index) else { return }
        storeScreen()
        let id = screenIDs[index]
        screenID = id
        canvas.zones = layout.screens[id] ?? [Zone()]
        canvas.screenSize = layout.screenSizes[id] ?? CGSize(width: 16, height: 10)
        canvas.selection = Array(canvas.zones.prefix(1))
        changed()
    }

    /// Copies the zones of the displayed screen back into the layout.
    private func storeScreen() {
        if let screenID { layout.screens[screenID] = canvas.zones }
    }

    private func updateButtons() {
        let selection = canvas.selection
        buttons["vertical"]?.isEnabled = !selection.isEmpty
        buttons["horizontal"]?.isEnabled = !selection.isEmpty
        buttons["merge"]?.isEnabled = selection.count > 1 && ZoneCanvas.rectangle(of: selection) != nil
        buttons["clear"]?.isEnabled = selection.contains { !$0.windows.isEmpty }
    }

    private func changed() {
        canvas.needsDisplay = true
        updateButtons()
        fillTray()
    }

    // MARK: - Windows

    /// Rebuilds the list of open windows: placed ones are dimmed and show their zone.
    private func fillTray() {
        // Two columns, top to bottom.
        let size = NSSize(width: 128, height: 100)
        let rows = (openWindows.count + 1) / 2
        let list = FlippedView(frame: NSRect(x: 0, y: 0, width: tray.contentSize.width,
                                             height: max(tray.contentSize.height, CGFloat(rows) * (size.height + 4) + 4)))
        for (index, window) in openWindows.enumerated() {
            let origin = NSPoint(x: 6 + CGFloat(index % 2) * (size.width + 6), y: 4 + CGFloat(index / 2) * (size.height + 4))
            let item = TrayItem(frame: NSRect(origin: origin, size: size),
                                index: index, icon: window.icon, title: window.ref.label, location: location(of: window.ref))
            item.onRemove = { [weak self] in
                self?.unassign(window.ref)
                self?.changed()
            }
            list.addSubview(item)
        }
        if openWindows.isEmpty {
            let empty = NSTextField(labelWithString: "No open window.")
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 8, y: 8, width: 250, height: 18)
            list.addSubview(empty)
        }
        // Keep the list where it was scrolled to.
        let scrolled = tray.contentView.bounds.origin
        tray.documentView = list
        tray.contentView.scroll(to: scrolled)
        tray.reflectScrolledClipView(tray.contentView)
    }

    /// Zones of the other screens of the layout.
    private var otherScreens: [(id: String, zones: [Zone])] {
        screenIDs.filter { $0 != screenID }.map { ($0, layout.screens[$0] ?? []) }
    }

    /// Where this window is placed, as shown in the list ("Zone 2"), or nil.
    private func location(of ref: WindowRef) -> String? {
        if let index = canvas.zones.firstIndex(where: { $0.windows.contains(ref) }) { return "Zone \(index + 1)" }
        for screen in otherScreens {
            if let index = screen.zones.firstIndex(where: { $0.windows.contains(ref) }) {
                return "\(layout.screenNames[screen.id] ?? "Screen") · Zone \(index + 1)"
            }
        }
        return nil
    }

    /// Removes the window from every zone, on every screen.
    private func unassign(_ ref: WindowRef) {
        for zone in canvas.zones + otherScreens.flatMap({ $0.zones }) { zone.windows.removeAll { $0 == ref } }
    }

    /// Puts a window dropped from the list into a zone, out of any other zone.
    private func place(_ index: Int, in zone: Zone) {
        guard openWindows.indices.contains(index) else { return }
        let ref = openWindows[index].ref
        unassign(ref)
        zone.windows.append(ref)
        canvas.selection = [zone]
        changed()
    }

    // MARK: - Actions

    @objc private func screenChanged() { showScreen(screenPopup.indexOfSelectedItem) }

    @objc private func splitVertically() { split(vertical: true) }
    @objc private func splitHorizontally() { split(vertical: false) }

    /// Cuts the selected zones. If together they form a rectangle, a single
    /// line crosses them all, in the middle of that rectangle; otherwise each
    /// one is cut in its middle. Apps stay in the first part.
    private func split(vertical: Bool) {
        let selection = canvas.selection
        guard !selection.isEmpty else { return }
        func middle(_ rect: CGRect) -> CGFloat { vertical ? rect.midX : rect.midY }
        func low(_ rect: CGRect) -> CGFloat { vertical ? rect.minX : rect.minY }
        func high(_ rect: CGRect) -> CGFloat { vertical ? rect.maxX : rect.maxY }
        func crosses(_ rect: CGRect, _ line: CGFloat) -> Bool {
            line > low(rect) + ZoneCanvas.minSize && line < high(rect) - ZoneCanvas.minSize
        }
        // Common line if the zones form a rectangle and it crosses at least one of them.
        var common: CGFloat? = ZoneCanvas.rectangle(of: selection).map { middle($0) }
        if let line = common, !selection.contains(where: { crosses($0.rect, line) }) { common = nil }
        var created: [Zone] = []
        for zone in selection {
            let line: CGFloat = common ?? middle(zone.rect)
            guard crosses(zone.rect, line) else { continue }
            let (first, second) = zone.rect.divided(atDistance: line - low(zone.rect),
                                                    from: vertical ? .minXEdge : .minYEdge)
            zone.rect = first
            let other = Zone(rect: second)
            canvas.zones.append(other)
            created.append(other)
        }
        canvas.zones = Zone.sorted(canvas.zones)
        canvas.selection = selection + created
        changed()
    }

    /// Merges the selected zones, if together they form a rectangle.
    @objc private func merge() {
        let selection = canvas.selection
        guard selection.count > 1, let rect = ZoneCanvas.rectangle(of: selection) else { return }
        let merged = Zone(rect: rect)
        for zone in selection { merged.windows += zone.windows.filter { !merged.windows.contains($0) } }
        canvas.zones = Zone.sorted(canvas.zones.filter { zone in !selection.contains { $0 === zone } } + [merged])
        canvas.selection = [merged]
        changed()
    }

    @objc private func removeWindows() {
        for zone in canvas.selection { zone.windows = [] }
        changed()
    }

    @objc private func cancel() { window.close() }

    @objc private func save() {
        storeScreen()
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        layout.name = name.isEmpty ? "Untitled" : name
        onSave(layout)
        window.close()
    }
}

/// The drawing of the screen and its zones, with selection and movable lines.
/// Zones are in fractions of the screen (0 to 1, origin at the top left).
private final class ZoneCanvas: NSView {
    static let minSize: CGFloat = 0.05      // minimum size of a zone, as a fraction of the screen
    private static let epsilon: CGFloat = 0.001

    var zones: [Zone] = []
    var selection: [Zone] = []
    var screenSize = CGSize(width: 16, height: 10)
    var onChange: () -> Void = {}
    var onDrop: (_ index: Int, _ zone: Zone) -> Void = { _, _ in }
    private var dropTarget: Zone?           // zone under a window being dragged from the list

    /// Line being moved: its position, its direction, and the zones before it
    /// (right or bottom edge on the line) and after it.
    private var dragging: (vertical: Bool, position: CGFloat, before: [Zone], after: [Zone])?

    override var isFlipped: Bool { true }

    /// Rectangle formed by these zones, or nil if they do not form a full rectangle.
    static func rectangle(of zones: [Zone]) -> CGRect? {
        guard let first = zones.first else { return nil }
        var union: CGRect = first.rect
        var area: CGFloat = 0
        for zone in zones {
            union = union.union(zone.rect)
            area += zone.rect.width * zone.rect.height
        }
        return abs(area - union.width * union.height) < 0.0001 ? union : nil
    }

    /// The screen in the view, keeping its proportions.
    private var screenRect: CGRect {
        let scale = min((bounds.width - 20) / screenSize.width, (bounds.height - 20) / screenSize.height)
        let size = CGSize(width: screenSize.width * scale, height: screenSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A point of the view, as a fraction of the screen.
    private func fraction(_ point: CGPoint) -> CGPoint {
        let screen = screenRect
        return CGPoint(x: (point.x - screen.minX) / screen.width, y: (point.y - screen.minY) / screen.height)
    }

    private func isSelected(_ zone: Zone) -> Bool { selection.contains { $0 === zone } }

    override func draw(_ dirtyRect: NSRect) {
        let screen = screenRect
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: screen.insetBy(dx: -4, dy: -4), xRadius: 8, yRadius: 8).fill()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ]
        for (index, zone) in zones.enumerated() {
            let rect = zone.frame(in: screen).insetBy(dx: 3, dy: 3)
            let color = isSelected(zone) ? NSColor.controlAccentColor.withAlphaComponent(0.55)
                                         : NSColor.windowBackgroundColor.withAlphaComponent(0.9)
            color.setFill()
            let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            shape.fill()
            if zone === dropTarget {
                NSColor.controlAccentColor.setStroke()
                shape.lineWidth = 3
                shape.stroke()
            }

            let names = zone.windows.map(\.shortLabel)
            let text = (["Zone \(index + 1)"] + names).joined(separator: "\n") as NSString
            let height = text.boundingRect(with: rect.size, options: .usesLineFragmentOrigin, attributes: attributes, context: nil).height
            text.draw(in: CGRect(x: rect.minX + 4, y: rect.midY - height / 2, width: rect.width - 8, height: height),
                      withAttributes: attributes)
        }
    }

    // MARK: - Dropping windows

    private func zone(at point: CGPoint) -> Zone? {
        let target = fraction(point)
        return zones.first { $0.rect.contains(target) }
    }

    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget = zone(at: convert(sender.draggingLocation, from: nil))
        needsDisplay = true
        return dropTarget == nil ? [] : .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            dropTarget = nil
            needsDisplay = true
        }
        guard let zone = zone(at: convert(sender.draggingLocation, from: nil)),
              let text = sender.draggingPasteboard.string(forType: .relayWindow), let index = Int(text)
        else { return false }
        onDrop(index, zone)
        return true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let line = lineUnder(point) {
            dragging = line
            return
        }
        let target = fraction(point)
        guard let zone = zones.first(where: { $0.rect.contains(target) }) else { return }
        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) {
            if isSelected(zone) { selection.removeAll { $0 === zone } } else { selection.append(zone) }
        } else {
            selection = [zone]
        }
        needsDisplay = true
        onChange()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let line = dragging else { return }
        let target = fraction(convert(event.locationInWindow, from: nil))
        let wanted = line.vertical ? target.x : target.y
        // Each zone keeps a minimum size on both sides of the line.
        var low: CGFloat = 0, high: CGFloat = 1
        for zone in line.before {
            let edge: CGFloat = line.vertical ? zone.rect.minX : zone.rect.minY
            low = max(low, edge + Self.minSize)
        }
        for zone in line.after {
            let edge: CGFloat = line.vertical ? zone.rect.maxX : zone.rect.maxY
            high = min(high, edge - Self.minSize)
        }
        guard low <= high else { return }
        let position = min(high, max(low, wanted))
        for zone in line.before {
            if line.vertical { zone.rect.size.width = position - zone.rect.minX }
            else { zone.rect.size.height = position - zone.rect.minY }
        }
        for zone in line.after {
            if line.vertical { zone.rect = CGRect(x: position, y: zone.rect.minY, width: zone.rect.maxX - position, height: zone.rect.height) }
            else { zone.rect = CGRect(x: zone.rect.minX, y: position, width: zone.rect.width, height: zone.rect.maxY - position) }
        }
        dragging?.position = position
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragging != nil { zones = Zone.sorted(zones) }
        dragging = nil
    }

    /// The line under the point, with the zones it moves.
    /// A line starts with the zones along it under the pointer. If one of them
    /// is selected, all selected zones along the same line are added. Then the
    /// zones on the other side that touch them are added, step by step, so that
    /// zones stay joined.
    private func lineUnder(_ point: CGPoint) -> (vertical: Bool, position: CGFloat, before: [Zone], after: [Zone])? {
        let screen = screenRect
        let target = fraction(point)
        let epsilon = Self.epsilon
        for vertical in [true, false] {
            let along: CGFloat = vertical ? target.y : target.x
            let across: CGFloat = vertical ? target.x : target.y
            let tolerance: CGFloat = vertical ? 5 / screen.width : 5 / screen.height
            func start(_ zone: Zone) -> CGFloat { vertical ? zone.rect.minX : zone.rect.minY }
            func end(_ zone: Zone) -> CGFloat { vertical ? zone.rect.maxX : zone.rect.maxY }
            func low(_ zone: Zone) -> CGFloat { vertical ? zone.rect.minY : zone.rect.minX }
            func high(_ zone: Zone) -> CGFloat { vertical ? zone.rect.maxY : zone.rect.maxX }
            func isOnLine(_ zone: Zone, _ position: CGFloat) -> Bool {
                abs(start(zone) - position) < epsilon || abs(end(zone) - position) < epsilon
            }
            func overlaps(_ a: Zone, _ b: Zone) -> Bool {
                min(high(a), high(b)) - max(low(a), low(b)) > epsilon
            }
            func contains(_ list: [Zone], _ zone: Zone) -> Bool { list.contains { $0 === zone } }

            // Inner edge closest to the pointer.
            var found: CGFloat?
            for zone in zones {
                for edge in [start(zone), end(zone)] {
                    let distance: CGFloat = abs(edge - across)
                    guard edge > epsilon, edge < 1 - epsilon, distance < tolerance else { continue }
                    if let best = found, abs(best - across) <= distance { continue }
                    found = edge
                }
            }
            guard let position = found else { continue }

            let onLine: [Zone] = zones.filter { isOnLine($0, position) }
            var group: [Zone] = onLine.filter { along >= low($0) - epsilon && along <= high($0) + epsilon }
            guard !group.isEmpty else { continue }
            if group.contains(where: { isSelected($0) }) {
                for zone in onLine where isSelected(zone) && !contains(group, zone) { group.append(zone) }
            }
            var added = true
            while added {
                added = false
                for zone in onLine where !contains(group, zone) {
                    if group.contains(where: { overlaps($0, zone) }) {
                        group.append(zone)
                        added = true
                    }
                }
            }
            let before: [Zone] = group.filter { abs(end($0) - position) < epsilon }
            let after: [Zone] = group.filter { abs(start($0) - position) < epsilon }
            return (vertical, position, before, after)
        }
        return nil
    }

    // Resize cursor above the lines.
    override func resetCursorRects() {
        let screen = screenRect
        for zone in zones {
            let rect = zone.frame(in: screen)
            if zone.rect.maxX < 1 - Self.epsilon {
                addCursorRect(CGRect(x: rect.maxX - 4, y: rect.minY, width: 8, height: rect.height), cursor: .resizeLeftRight)
            }
            if zone.rect.maxY < 1 - Self.epsilon {
                addCursorRect(CGRect(x: rect.minX, y: rect.maxY - 4, width: rect.width, height: 8), cursor: .resizeUpDown)
            }
        }
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { window?.invalidateCursorRects(for: self) } }
    }
}

private extension NSPasteboard.PasteboardType {
    static let relayWindow = NSPasteboard.PasteboardType("local.relais.window")
}

/// A window in the list below the screen: app icon, title and zone. Dragged
/// onto a zone to place it there; dimmed once placed, with a button to remove it.
private final class TrayItem: NSView, NSDraggingSource {
    var onRemove: () -> Void = {}

    private let index: Int
    private let icon: NSImage
    private let iconView = NSImageView()
    private var dragging = false

    init(frame: NSRect, index: Int, icon: NSImage, title: String, location: String?) {
        self.index = index
        self.icon = icon
        super.init(frame: frame)
        toolTip = title

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: (frame.width - 40) / 2, y: frame.height - 46, width: 40, height: 40)
        addSubview(iconView)

        let name = NSTextField(wrappingLabelWithString: title)
        name.font = .systemFont(ofSize: 10)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 2, y: 18, width: frame.width - 4, height: 28)
        addSubview(name)

        let zone = NSTextField(labelWithString: location ?? "Not placed")
        zone.font = .systemFont(ofSize: 10, weight: location == nil ? .regular : .semibold)
        zone.textColor = location == nil ? .tertiaryLabelColor : .controlAccentColor
        zone.alignment = .center
        zone.lineBreakMode = .byTruncatingTail
        zone.frame = NSRect(x: 2, y: 2, width: frame.width - 4, height: 14)
        addSubview(zone)

        if location != nil {
            iconView.alphaValue = 0.35
            name.alphaValue = 0.45
            let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from zone")!,
                                  target: self, action: #selector(removeFromZone))
            remove.isBordered = false
            remove.toolTip = "Remove from its zone"
            remove.frame = NSRect(x: frame.width - 22, y: frame.height - 22, width: 18, height: 18)
            addSubview(remove)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeFromZone() { onRemove() }

    override func mouseDown(with event: NSEvent) { dragging = false }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        dragging = true
        let item = NSPasteboardItem()
        item.setString(String(index), forType: .relayWindow)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(iconView.frame, contents: icon)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

/// A view whose origin is at the top left, so that the list starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

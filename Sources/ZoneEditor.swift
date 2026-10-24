import AppKit

/// Layout editing window: all the screens of the layout are shown side by
/// side, as they are arranged on the desk. Each screen is cut into zones,
/// their size is adjusted, and open windows are dragged from the list on the
/// right onto a zone of any screen. A window belongs to one zone at most.
/// Several zones of a screen can be selected together (⇧ or ⌘ + click) to
/// merge them, cut them with one line, or move the line they share.
/// A screen can be dragged by its name next to another one: on Save, macOS
/// arranges the screens that way (as in System Settings > Displays).
final class ZoneEditor: NSObject, NSWindowDelegate {
    /// Keeps the editor alive while its window is open.
    private static var current: ZoneEditor?

    private var layout: Layout
    private let onSave: (Layout) -> Void
    private let window: NSWindow
    private let screensView = FlippedView()
    private let tray = NSScrollView()
    /// Open windows shown in the list on the right, with their app icon.
    private let openWindows: [(ref: WindowRef, icon: NSImage, windowID: CGWindowID?)]
    /// Window previews, when they are turned on in Relay's menu (memory only).
    private var previews: [CGWindowID: NSImage] = [:]
    private let nameField = NSTextField()
    /// Screens in the order they are shown, with one drawing each.
    private var screenIDs: [String]
    /// Screens side by side (true) or stacked (false).
    private var horizontal: Bool
    /// The user moved a screen: macOS arranges the screens that way on Save.
    private var arranged = false
    private var canvases: [String: ZoneCanvas] = [:]
    private var titles: [String: ScreenTitle] = [:]
    /// Button next to each screen that swaps its zones with another screen's.
    private var swapButtons: [String: NSButton] = [:]
    /// Screen the buttons act on: the last one clicked or dropped onto.
    private var activeID: String
    private var buttons: [String: NSButton] = [:]

    private var canvas: ZoneCanvas { canvases[activeID] ?? ZoneCanvas() }

    static func open(_ layout: Layout, previews: Bool, onSave: @escaping (Layout) -> Void) {
        current?.window.close()
        current = ZoneEditor(layout: layout, onSave: onSave)
        if previews { current?.capturePreviews() }
        NSApp.activate()
        current?.window.center()
        current?.window.makeKeyAndOrderFront(nil)
    }

    private init(layout original: Layout, onSave: @escaping (Layout) -> Void) {
        var copy = original
        copy.screens = original.screens.mapValues { Zone.sorted(Zone.copy($0)) }
        layout = copy
        var seen: [WindowRef] = []
        var list: [(ref: WindowRef, icon: NSImage, windowID: CGWindowID?)] = []
        for item in WindowList.current() where item.own == nil {
            guard let app = item.app.bundleIdentifier else { continue }
            let ref = WindowRef(app: app, title: item.title)
            guard !seen.contains(ref) else { continue }
            seen.append(ref)
            list.append((ref: ref, icon: item.app.icon ?? NSImage(), windowID: item.windowID))
        }
        openWindows = list
        self.onSave = onSave
        screenIDs = Self.ordered(Array(copy.screens.keys), names: copy.screenNames)
        activeID = screenIDs.first ?? ""
        let frames = Displays.current().filter { copy.screens[$0.id] != nil }.map(\.frame)
        horizontal = Self.isHorizontal(frames)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 720),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Edit Layout"
        window.contentMinSize = NSSize(width: 1100, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildInterface()
        activate(activeID)
    }

    /// The screens grow with the window, the list of windows stays on the right.
    func windowDidResize(_ notification: Notification) {
        layoutScreens()
        fillTray()
    }

    func windowWillClose(_ notification: Notification) {
        if ZoneEditor.current === self { ZoneEditor.current = nil }
    }

    // MARK: - Screens

    /// Connected screens from left to right (or top to bottom), then the
    /// screens that are not plugged in.
    private static func ordered(_ ids: [String], names: [String: String]) -> [String] {
        let frames = Dictionary(Displays.current().map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let horizontal = isHorizontal(ids.compactMap { frames[$0] })
        return ids.sorted { a, b in
            switch (frames[a], frames[b]) {
            case let (x?, y?): return horizontal ? x.midX < y.midX : x.midY < y.midY
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return (names[a] ?? "") < (names[b] ?? "")
            }
        }
    }

    /// Whether these screens are side by side rather than stacked.
    private static func isHorizontal(_ frames: [CGRect]) -> Bool {
        guard frames.count > 1 else { return true }
        let xs = frames.map(\.midX), ys = frames.map(\.midY)
        return xs.max()! - xs.min()! >= ys.max()! - ys.min()!
    }

    /// Box of each screen in the screens area, at the same scale for all
    /// screens so that their sizes compare as they really do (a small screen
    /// is enlarged up to a minimum size so that it stays easy to edit). Side by side,
    /// they are aligned at the bottom; stacked, they are centered (as Relay
    /// arranges them in macOS).
    private func screenBoxes(in area: CGSize) -> [CGRect] {
        let label: CGFloat = 30, gap: CGFloat = 28
        let sizes: [CGSize] = screenIDs.map { layout.screenSizes[$0] ?? CGSize(width: 16, height: 10) }
        let count = CGFloat(screenIDs.count)
        let maxWidth: CGFloat = sizes.map(\.width).max() ?? 1
        let maxHeight: CGFloat = sizes.map(\.height).max() ?? 1
        let sumWidth: CGFloat = sizes.map(\.width).reduce(0, +)
        let sumHeight: CGFloat = sizes.map(\.height).reduce(0, +)
        // A small screen next to a big one keeps a usable size: at least
        // `minimum` points high (side by side) or wide (stacked), and a big
        // screen is at most 1.6 times as high (or wide) as the smallest one.
        let minimum: CGFloat = 170
        func scales(_ scale: CGFloat) -> [CGFloat] {
            let side: [CGFloat] = sizes.map { max(horizontal ? $0.height : $0.width, 1) }
            let raised: [CGFloat] = side.map { max(scale, minimum / $0) }
            var smallest: CGFloat = .greatestFiniteMagnitude
            for (length, s) in zip(side, raised) { smallest = min(smallest, length * s) }
            return zip(side, raised).map { length, s in min(s, 1.6 * smallest / length) }
        }
        var boxes: [CGRect] = []
        if horizontal {
            var scale: CGFloat = min((area.width - gap * (count - 1)) / sumWidth, (area.height - label) / maxHeight)
            func total(_ scale: CGFloat) -> (width: CGFloat, height: CGFloat) {
                let each = scales(scale)
                var width: CGFloat = gap * (count - 1), height: CGFloat = 0
                for (size, s) in zip(sizes, each) {
                    width += size.width * s
                    height = max(height, size.height * s)
                }
                return (width, height)
            }
            while scale > 0.001, total(scale).width > area.width || total(scale).height > area.height - label { scale *= 0.97 }
            let each = scales(scale)
            let used = total(scale)
            var x: CGFloat = (area.width - used.width) / 2
            // Room for the names above the screens.
            let bottom: CGFloat = area.height - (area.height - label - used.height) / 2
            for (size, s) in zip(sizes, each) {
                boxes.append(CGRect(x: x, y: bottom - size.height * s, width: size.width * s, height: size.height * s))
                x += size.width * s + gap
            }
        } else {
            var scale: CGFloat = min(area.width / maxWidth, (area.height - label * count - gap * (count - 1)) / sumHeight)
            func total(_ scale: CGFloat) -> (width: CGFloat, height: CGFloat) {
                let each = scales(scale)
                var width: CGFloat = 0, height: CGFloat = (label + gap) * count - gap
                for (size, s) in zip(sizes, each) {
                    width = max(width, size.width * s)
                    height += size.height * s
                }
                return (width, height)
            }
            while scale > 0.001, total(scale).width > area.width || total(scale).height > area.height { scale *= 0.97 }
            let each = scales(scale)
            var y: CGFloat = (area.height - total(scale).height) / 2 + label
            for (size, s) in zip(sizes, each) {
                boxes.append(CGRect(x: (area.width - size.width * s) / 2, y: y, width: size.width * s, height: size.height * s))
                y += size.height * s + label + gap
            }
        }
        return boxes
    }

    /// Puts each screen and its name in its box.
    private func layoutScreens() {
        for (id, box) in zip(screenIDs, screenBoxes(in: screensView.frame.size)) {
            canvases[id]?.frame = box.insetBy(dx: -10, dy: -10)
            titles[id]?.frame = NSRect(x: box.minX, y: box.minY - 26, width: box.width, height: 18)
            swapButtons[id]?.frame = NSRect(x: box.maxX + 4, y: box.minY - 28, width: 20, height: 20)
        }
        for view in canvases.values { view.needsDisplay = true }
    }

    /// A screen follows the pointer while it is dragged by its name.
    private func drag(_ id: String, by delta: CGSize) {
        for view in [canvases[id], titles[id], swapButtons[id]] as [NSView?] {
            guard let view else { continue }
            view.frame.origin.x += delta.width
            view.frame.origin.y += delta.height
        }
        if let view = canvases[id] { screensView.addSubview(view, positioned: .above, relativeTo: nil) }
        if let title = titles[id] { screensView.addSubview(title, positioned: .above, relativeTo: nil) }
        if let swap = swapButtons[id] { screensView.addSubview(swap, positioned: .above, relativeTo: nil) }
    }

    /// A screen dropped next to another one: it goes on the side of the
    /// nearest screen it was dropped on (left, right, above or below).
    private func dropScreen(_ id: String) {
        defer { layoutScreens() }
        guard let moved = canvases[id]?.frame else { return }
        let center = CGPoint(x: moved.midX, y: moved.midY)
        var target: (id: String, distance: CGFloat)?
        for other in screenIDs where other != id {
            guard let frame = canvases[other]?.frame else { continue }
            let distance: CGFloat = hypot(center.x - frame.midX, center.y - frame.midY)
            if target == nil || distance < target!.distance { target = (other, distance) }
        }
        guard let target, let frame = canvases[target.id]?.frame else { return }
        let dx: CGFloat = (center.x - frame.midX) / max(frame.width, 1)
        let dy: CGFloat = (center.y - frame.midY) / max(frame.height, 1)
        let sideways = abs(dx) >= abs(dy)
        let after = sideways ? dx > 0 : dy > 0    // to the right, or below (the view is flipped)
        var order = screenIDs.filter { $0 != id }
        guard let index = order.firstIndex(of: target.id) else { return }
        order.insert(id, at: after ? index + 1 : index)
        guard order != screenIDs || sideways != horizontal else { return }
        screenIDs = order
        horizontal = sideways
        arranged = true
    }

    /// Makes this screen the one the buttons act on, and clears the selection
    /// of the others.
    private func activate(_ id: String) {
        activeID = id
        for (other, view) in canvases where other != id && !view.selection.isEmpty {
            view.selection = []
            view.needsDisplay = true
        }
        changed()
    }

    // MARK: - Interface

    private func buildInterface() {
        let content = window.contentView!

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 20, y: 681, width: 50, height: 20)
        nameLabel.autoresizingMask = [.minYMargin]
        content.addSubview(nameLabel)
        nameField.formatter = LayoutNameFormatter()
        nameField.stringValue = layout.name
        nameField.placeholderString = "Up to 30 characters"
        nameField.frame = NSRect(x: 72, y: 678, width: 300, height: 24)
        nameField.autoresizingMask = [.minYMargin]
        content.addSubview(nameField)

        var x: CGFloat = 20
        for (key, title, action) in [
            ("vertical", "Split Left | Right", #selector(splitVertically)),
            ("horizontal", "Split Top / Bottom", #selector(splitHorizontally)),
            ("merge", "Merge", #selector(merge)),
            ("delete", "Delete Zone", #selector(deleteZone)),
            ("clear", "Remove Windows", #selector(removeWindows)),
        ] {
            let button = NSButton(title: title, target: self, action: action)
            button.sizeToFit()
            button.frame.origin = NSPoint(x: x, y: 634)
            button.autoresizingMask = [.minYMargin]
            x += button.frame.width + 8
            content.addSubview(button)
            buttons[key] = button
        }

        screensView.frame = NSRect(x: 20, y: 60, width: 960, height: 564)
        screensView.autoresizingMask = [.width, .height]
        content.addSubview(screensView)
        // Screens can be rearranged only when they are all plugged in.
        let connected = Set(Displays.current().map(\.id))
        let movable = screenIDs.count > 1 && Set(screenIDs) == connected
        for id in screenIDs {
            let view = ZoneCanvas()
            view.zones = layout.screens[id] ?? [Zone()]
            view.screenSize = layout.screenSizes[id] ?? CGSize(width: 16, height: 10)
            view.onChange = { [weak self] in self?.activate(id) }
            view.onDrop = { [weak self] index, zone in self?.place(index, in: zone, on: id) }
            view.onRemove = { [weak self] ref in
                self?.unassign(ref)
                self?.changed()
            }
            view.registerForDraggedTypes([.relayWindow])
            screensView.addSubview(view)
            canvases[id] = view
            if screenIDs.count > 1 {
                let title = ScreenTitle(name: layout.screenNames[id] ?? "Screen", movable: movable)
                title.onDrag = { [weak self] delta in self?.drag(id, by: delta) }
                title.onDrop = { [weak self] in self?.dropScreen(id) }
                screensView.addSubview(title)
                titles[id] = title
                let swap = NSButton(image: NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Swap zones")!,
                                    target: self, action: #selector(swapClicked(_:)))
                swap.isBordered = false
                swap.identifier = NSUserInterfaceItemIdentifier(id)
                swap.toolTip = screenIDs.count == 2 ? "Swap the zones of the two screens" : "Swap these zones with another screen's"
                screensView.addSubview(swap)
                swapButtons[id] = swap
            }
        }
        layoutScreens()
        canvas.selection = Array(canvas.zones.prefix(1))

        let trayLabel = NSTextField(wrappingLabelWithString: "Open windows: drag each one onto a zone, on any screen. A window goes in one zone at most.")
        trayLabel.font = .systemFont(ofSize: 11, weight: .medium)
        trayLabel.frame = NSRect(x: 1000, y: 672, width: 280, height: 30)
        trayLabel.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(trayLabel)
        tray.frame = NSRect(x: 1000, y: 60, width: 280, height: 604)
        tray.autoresizingMask = [.minXMargin, .height]
        tray.hasVerticalScroller = true
        tray.borderType = .bezelBorder
        tray.drawsBackground = false
        content.addSubview(tray)

        let hint = NSTextField(labelWithString:
            "Click a zone to select it, ⇧-click to select several on the same screen. Drag a line to resize: it moves only\n"
            + "where it touches the zone under the pointer, or along all selected zones. Drag a screen by its name to move it.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.frame = NSRect(x: 20, y: 14, width: 960, height: 32)
        content.addSubview(hint)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 1090, y: 14, width: 90, height: 32)
        cancel.autoresizingMask = [.minXMargin]
        content.addSubview(cancel)
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 1190, y: 14, width: 90, height: 32)
        save.autoresizingMask = [.minXMargin]
        content.addSubview(save)
    }

    private func updateButtons() {
        let selection = canvas.selection
        buttons["vertical"]?.isEnabled = !selection.isEmpty
        buttons["horizontal"]?.isEnabled = !selection.isEmpty
        buttons["merge"]?.isEnabled = selection.count > 1 && ZoneCanvas.rectangle(of: selection) != nil
        buttons["clear"]?.isEnabled = selection.contains { !$0.windows.isEmpty }
        buttons["delete"]?.isEnabled = selection.count == 1 && absorber(of: selection[0]) != nil
    }

    private func changed() {
        for view in canvases.values { view.needsDisplay = true }
        updateButtons()
        fillTray()
    }

    // MARK: - Windows

    /// Thumbnails of the open windows, shown in the list as they arrive.
    private func capturePreviews() {
        let ids = openWindows.compactMap(\.windowID)
        guard !ids.isEmpty else { return }
        Previews.capture(ids, maxSide: 128) { [weak self] id, image in
            guard let self else { return }
            self.previews[id] = NSImage(cgImage: image, size: .zero)
            self.fillTray()
        }
    }

    /// Rebuilds the list of open windows: windows not placed yet come first;
    /// placed ones are dimmed and show their zone.
    private func fillTray() {
        // Two columns, top to bottom.
        let size = NSSize(width: 128, height: 100)
        let rows = (openWindows.count + 1) / 2
        let list = FlippedView(frame: NSRect(x: 0, y: 0, width: tray.contentSize.width,
                                             height: max(tray.contentSize.height, CGFloat(rows) * (size.height + 4) + 4)))
        let locations: [String?] = openWindows.map { location(of: $0.ref) }
        let order: [Int] = openWindows.indices.filter { locations[$0] == nil } + openWindows.indices.filter { locations[$0] != nil }
        for (position, index) in order.enumerated() {
            let window = openWindows[index]
            let origin = NSPoint(x: 6 + CGFloat(position % 2) * (size.width + 6), y: 4 + CGFloat(position / 2) * (size.height + 4))
            let item = TrayItem(frame: NSRect(origin: origin, size: size), index: index, icon: window.icon,
                                preview: window.windowID.flatMap { previews[$0] },
                                title: window.ref.label, location: locations[index])
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

    /// Where this window is placed, as shown in the list ("Zone 2", or
    /// "DELL U2723QE · Zone 2" with several screens), or nil.
    private func location(of ref: WindowRef) -> String? {
        for id in screenIDs {
            guard let zones = canvases[id]?.zones,
                  let index = zones.firstIndex(where: { $0.windows.contains(ref) }) else { continue }
            return screenIDs.count > 1 ? "\(layout.screenNames[id] ?? "Screen") · Zone \(index + 1)" : "Zone \(index + 1)"
        }
        return nil
    }

    /// Removes the window from every zone, on every screen.
    private func unassign(_ ref: WindowRef) {
        for view in canvases.values {
            for zone in view.zones { zone.windows.removeAll { $0 == ref } }
        }
    }

    /// Puts a window dropped from the list into a zone, out of any other zone.
    private func place(_ index: Int, in zone: Zone, on id: String) {
        guard openWindows.indices.contains(index) else { return }
        let ref = openWindows[index].ref
        unassign(ref)
        zone.windows.append(ref)
        canvases[id]?.selection = [zone]
        activate(id)
    }

    // MARK: - Actions

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

    /// The zone that takes the space of a deleted zone: the zone with the
    /// previous number if together they form a rectangle, otherwise the
    /// nearest number that does.
    private func absorber(of zone: Zone) -> Zone? {
        let zones = canvas.zones
        guard let index = zones.firstIndex(where: { $0 === zone }) else { return nil }
        let candidates: [Int] = Array((0..<index).reversed()) + Array((index + 1)..<zones.count)
        for other in candidates where ZoneCanvas.rectangle(of: [zone, zones[other]]) != nil { return zones[other] }
        return nil
    }

    /// Deletes the selected zone: the zone with the previous number grows over
    /// its space and takes its windows.
    @objc private func deleteZone() {
        guard canvas.selection.count == 1, let zone = canvas.selection.first, let target = absorber(of: zone),
              let rect = ZoneCanvas.rectangle(of: [zone, target])
        else { return }
        target.rect = rect
        target.windows += zone.windows.filter { !target.windows.contains($0) }
        canvas.zones = Zone.sorted(canvas.zones.filter { $0 !== zone })
        canvas.selection = [target]
        changed()
    }

    /// Swaps the zones (and their windows) of a screen with another screen's:
    /// directly with two screens, through a menu with more.
    @objc private func swapClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let others = screenIDs.filter { $0 != id }
        if others.count == 1 {
            swapZones(id, others[0])
            return
        }
        let menu = NSMenu()
        for other in others {
            let item = NSMenuItem(title: "Swap with \(layout.screenNames[other] ?? "Screen")", action: #selector(swapChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [id, other]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: sender)
    }

    @objc private func swapChosen(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        swapZones(pair[0], pair[1])
    }

    private func swapZones(_ a: String, _ b: String) {
        guard let first = canvases[a], let second = canvases[b] else { return }
        (first.zones, second.zones) = (second.zones, first.zones)
        first.selection = []
        second.selection = Array(second.zones.prefix(1))
        activate(b)
    }

    @objc private func removeWindows() {
        for zone in canvas.selection { zone.windows = [] }
        changed()
    }

    @objc private func cancel() { window.close() }

    @objc private func save() {
        for (id, view) in canvases { layout.screens[id] = view.zones }
        let name = Layout.cleanName(nameField.stringValue)
        layout.name = name.isEmpty ? "Untitled" : name
        let layout = layout, onSave = onSave
        window.close()
        // macOS needs a moment to move the screens before the windows can follow.
        if arranged, Displays.arrange(screenIDs, horizontal: horizontal) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { onSave(layout) }
        } else {
            onSave(layout)
        }
    }
}

/// The drawing of one screen and its zones, with selection and movable lines.
/// Zones are in fractions of the screen (0 to 1, origin at the top left).
private final class ZoneCanvas: NSView {
    static let minSize: CGFloat = 0.05      // minimum size of a zone, as a fraction of the screen
    private static let epsilon: CGFloat = 0.001

    var zones: [Zone] = []
    var selection: [Zone] = []
    var screenSize = CGSize(width: 16, height: 10)
    var onChange: () -> Void = {}
    var onDrop: (_ index: Int, _ zone: Zone) -> Void = { _, _ in }
    /// A window taken out of its zone with the ✕ next to its name.
    var onRemove: (_ ref: WindowRef) -> Void = { _ in }
    private var dropTarget: Zone?
    /// Window names drawn in the zones, and the one under the pointer, which
    /// shows a ✕ to take it out of its zone.
    private var names: [(zone: Zone, ref: WindowRef, rect: CGRect)] = []
    private var hoveredName: (zone: Zone, ref: WindowRef, rect: CGRect)? { didSet { needsDisplay = true } }           // zone under a window being dragged from the list

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
        names = []
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

            // One line for the zone number, then one per window, centered.
            let lines: [String] = ["Zone \(index + 1)"] + zone.windows.map(\.shortLabel)
            let lineHeight: CGFloat = ("Zone" as NSString).size(withAttributes: attributes).height
            var y: CGFloat = rect.midY - lineHeight * CGFloat(lines.count) / 2
            for (line, text) in lines.enumerated() {
                let box = CGRect(x: rect.minX + 4, y: y, width: rect.width - 8, height: lineHeight)
                (text as NSString).draw(in: box, withAttributes: attributes)
                if line > 0 {
                    let width: CGFloat = min(box.width, (text as NSString).size(withAttributes: attributes).width)
                    names.append((zone, zone.windows[line - 1], CGRect(x: box.midX - width / 2, y: y, width: width, height: lineHeight)))
                }
                y += lineHeight
            }
        }
        if let hoveredName, let cross = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove") {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: hoveredName.rect.insetBy(dx: -3, dy: 0), xRadius: 4, yRadius: 4).fill()
            cross.draw(in: crossRect(hoveredName.rect))
        }
    }

    /// Where the ✕ of a window name is drawn: just after the name.
    private func crossRect(_ name: CGRect) -> CGRect {
        CGRect(x: name.maxX + 4, y: name.midY - 7, width: 14, height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Keep the ✕ while the pointer goes from the name to it.
        if let hoveredName, hoveredName.rect.union(crossRect(hoveredName.rect)).insetBy(dx: -2, dy: -2).contains(point) { return }
        let found = names.first { $0.rect.insetBy(dx: -2, dy: 0).contains(point) }
        if found?.ref != hoveredName?.ref || found?.zone !== hoveredName?.zone { hoveredName = found }
    }

    override func mouseExited(with event: NSEvent) { hoveredName = nil }

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
        if let hoveredName, crossRect(hoveredName.rect).insetBy(dx: -2, dy: -2).contains(point) {
            self.hoveredName = nil
            onRemove(hoveredName.ref)
            return
        }
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

/// A window in the list next to the screens: app icon, title and zone, or,
/// with previews, the window's thumbnail with its icon and title on top. Dragged
/// onto a zone to place it there; dimmed once placed, with a button to remove it.
private final class TrayItem: NSView, NSDraggingSource {
    var onRemove: () -> Void = {}

    private let index: Int
    private let icon: NSImage
    private let iconView = NSImageView()
    private var thumbnail: NSImageView?
    private var dragging = false

    init(frame: NSRect, index: Int, icon: NSImage, preview: NSImage?, title: String, location: String?) {
        self.index = index
        self.icon = icon
        super.init(frame: frame)
        toolTip = title

        let name: NSTextField
        if let preview {
            // Thumbnail over the whole item, with a band on top for the icon and the title.
            let thumbnail = NSImageView(image: preview)
            thumbnail.imageScaling = .scaleProportionallyUpOrDown
            thumbnail.frame = NSRect(x: 2, y: 18, width: frame.width - 4, height: frame.height - 20)
            addSubview(thumbnail)
            self.thumbnail = thumbnail
            let band = NSView(frame: NSRect(x: 2, y: frame.height - 22, width: frame.width - 4, height: 20))
            band.wantsLayer = true
            band.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            band.layer?.cornerRadius = 4
            addSubview(band)
            iconView.frame = NSRect(x: 4, y: frame.height - 20, width: 16, height: 16)
            name = NSTextField(labelWithString: title)
            name.font = .systemFont(ofSize: 10, weight: .medium)
            name.textColor = .white
            name.lineBreakMode = .byTruncatingTail
            name.frame = NSRect(x: 22, y: frame.height - 20, width: frame.width - 26, height: 15)
        } else {
            iconView.frame = NSRect(x: (frame.width - 40) / 2, y: frame.height - 46, width: 40, height: 40)
            name = NSTextField(wrappingLabelWithString: title)
            name.font = .systemFont(ofSize: 10)
            name.alignment = .center
            name.maximumNumberOfLines = 2
            name.lineBreakMode = .byTruncatingTail
            name.frame = NSRect(x: 2, y: 18, width: frame.width - 4, height: 28)
        }
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
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
            thumbnail?.alphaValue = 0.35
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

/// The name of a screen above its drawing. When the screens can be
/// rearranged, it can be dragged to move the screen next to another one.
private final class ScreenTitle: NSView {
    var onDrag: (CGSize) -> Void = { _ in }
    var onDrop: () -> Void = {}

    private let movable: Bool
    private var last: NSPoint?

    init(name: String, movable: Bool) {
        self.movable = movable
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: movable ? "⠿ " + name : name)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.autoresizingMask = [.width]
        addSubview(label)
        label.frame = bounds
        if movable { toolTip = "Drag to move this screen next to another one" }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var frame: NSRect {
        didSet { subviews.first?.frame = bounds }
    }

    override func resetCursorRects() {
        if movable { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard movable else { return }
        last = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last else { return }
        let point = event.locationInWindow
        // The screens area is flipped: y grows downwards.
        onDrag(CGSize(width: point.x - last.x, height: last.y - point.y))
        self.last = point
    }

    override func mouseUp(with event: NSEvent) {
        guard last != nil else { return }
        last = nil
        NSCursor.pop()
        onDrop()
    }
}

/// A view whose origin is at the top left, so that the list starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

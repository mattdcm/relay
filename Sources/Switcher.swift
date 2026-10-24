import AppKit

/// The floating window that shows open windows during ⌘⇥.
final class Switcher {
    private let panel: NSPanel
    private var items: [WindowItem] = []
    private var cells: [ItemView] = []
    private var selectable: [Int] = []   // indices reachable with ⇥ (recently used apps)
    private var selected: Int?
    /// Last captured previews, kept in memory (never on disk) for windows that
    /// cannot be captured right now: minimized, hidden app…
    private var previewCache: [CGWindowID: CGImage] = [:]

    var isVisible: Bool { panel.isVisible }
    /// Each screen (origin at the top left) and the zones of the current
    /// layout on it, numbered in this order: shown under the windows.
    var zoneScreens: () -> [(frame: CGRect, zones: [CGRect], name: String)] = { [] }
    private var map: ZoneMap?
    private var mapLabel: NSTextField?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// `recentApps`: the apps whose windows ⇥ cycles through. The others are
    /// dimmed and can only be picked with the mouse.
    func show(withPreviews previews: Bool, backwards: Bool, recentApps: ([WindowItem]) -> Set<pid_t>) {
        // Recent windows first, then the others (dimmed), each in stacking order.
        let all = WindowList.current()
        let recentPIDs = recentApps(all)
        let isRecent = { (item: WindowItem) in recentPIDs.contains(item.app.processIdentifier) }
        let recent = all.filter(isRecent)
        items = recent + all.filter { !isRecent($0) }
        guard !items.isEmpty else { return }
        selectable = Array(recent.indices)
        // The first press selects the previous window.
        selected = backwards ? selectable.last : (selectable.count > 1 ? selectable[1] : selectable.first)
        layout(previews: previews)
        panel.orderFrontRegardless()

        guard previews else { previewCache = [:]; return }
        // Forget closed windows, then show what we already have right away.
        let ids = Set(items.compactMap(\.windowID))
        previewCache = previewCache.filter { ids.contains($0.key) }
        for (index, item) in items.enumerated() {
            if let id = item.windowID, let image = previewCache[id] { cells[index].setPreview(image) }
        }
        // Then refresh the visible windows.
        let visible = items.filter(\.isOnScreen).compactMap(\.windowID)
        Previews.capture(visible, maxSide: ItemView.previewSize.width) { [weak self] id, image in
            guard let self else { return }
            self.previewCache[id] = image
            guard self.panel.isVisible,
                  let index = self.items.firstIndex(where: { $0.windowID == id }) else { return }
            self.cells[index].setPreview(image)
        }
    }

    func move(backwards: Bool) {
        guard !selectable.isEmpty else { return }
        let position = selected.flatMap { selectable.firstIndex(of: $0) } ?? 0
        let next = (position + (backwards ? -1 : 1) + selectable.count) % selectable.count
        select(selectable[next])
    }

    /// The window currently selected, if the switcher is open.
    var selectedItem: WindowItem? {
        guard let selected, items.indices.contains(selected) else { return nil }
        return items[selected]
    }

    /// Hides the switcher but keeps its selection (zone mode, arrows).
    func hidePanel() { panel.orderOut(nil) }

    /// Shows the switcher again after zone mode, to pick another window.
    func showPanel() {
        guard !items.isEmpty else { return }
        panel.orderFrontRegardless()
    }


    func commit() {
        guard !items.isEmpty else { return }
        panel.orderOut(nil)
        if let selected, items.indices.contains(selected) { WindowList.focus(items[selected]) }
        clear()
    }

    func cancel() {
        panel.orderOut(nil)
        clear()
    }

    // MARK: - Display

    private func clear() {
        items = []
        cells = []
        selectable = []
        selected = nil
        map = nil
        mapLabel = nil
        panel.contentView = nil
    }

    private func select(_ index: Int) {
        if let selected { cells[selected].isSelected = false }
        selected = index
        cells[index].isSelected = true
        showPlace()
    }

    /// Highlights on the map the zone the selected window is in, if any.
    private func showPlace() {
        guard let map else { return }
        if let selected, items.indices.contains(selected), items[selected].own == nil {
            map.windowFrame = WindowList.frame(of: items[selected].element)
        } else {
            map.windowFrame = nil
        }
        mapLabel?.stringValue = "Window position in monitor\n" + (map.screenName ?? "–")
    }

    private func layout(previews: Bool) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let cellSize = previews ? ItemView.previewCellSize : ItemView.iconCellSize
        let padding: CGFloat = 12
        let columns = max(1, min(items.count, Int((screen.visibleFrame.width * 0.9 - 2 * padding) / cellSize.width)))
        let rows = (items.count + columns - 1) / columns
        let tip = KeyTips()
        // Left: where the selected window is, on a map of the screens. Right: the keys.
        let map = ZoneMap(screens: zoneScreens(), height: 110, maxWidth: 420)
        self.map = map
        let label = NSTextField(labelWithString: "Window position in monitor\n")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.maximumNumberOfLines = 2
        label.frame.size = NSSize(width: 170, height: 34)
        mapLabel = label
        let mapWidth: CGFloat = map.frame.width > 0 ? label.frame.width + 12 + map.frame.width + 40 : 0
        let footer = NSSize(width: mapWidth + tip.frame.width, height: max(tip.frame.height, map.frame.height))
        let tipHeight: CGFloat = footer.height + 10
        let grid = NSSize(width: CGFloat(columns) * cellSize.width, height: CGFloat(rows) * cellSize.height)
        let size = NSSize(width: max(grid.width, footer.width) + 2 * padding,
                          height: grid.height + tipHeight + 2 * padding)
        // The grid is centered when the tip is wider.
        let left: CGFloat = (size.width - grid.width) / 2

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14

        cells = items.enumerated().map { index, item in
            let column = index % columns, row = index / columns
            let origin = NSPoint(x: left + CGFloat(column) * cellSize.width,
                                 y: size.height - padding - CGFloat(row + 1) * cellSize.height)
            let cell = ItemView(frame: NSRect(origin: origin, size: cellSize), item: item, previews: previews,
                                dimmed: !selectable.contains(index))
            cell.onClick = { [weak self] in
                self?.select(index)
                self?.commit()
            }
            background.addSubview(cell)
            return cell
        }
        if let selected { cells[selected].isSelected = true }
        let footerLeft: CGFloat = (size.width - footer.width) / 2
        if map.frame.width > 0 {
            label.frame.origin = NSPoint(x: footerLeft, y: padding + (footer.height - label.frame.height) / 2)
            background.addSubview(label)
            map.frame.origin = NSPoint(x: footerLeft + label.frame.width + 12, y: padding + (footer.height - map.frame.height) / 2)
            background.addSubview(map)
        }
        tip.frame.origin = NSPoint(x: footerLeft + mapWidth, y: padding + (footer.height - tip.frame.height) / 2)
        background.addSubview(tip)
        showPlace()

        panel.contentView = background
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2,
                              y: screen.visibleFrame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }
}

/// A cell of the switcher: preview (or icon) + title.
private final class ItemView: NSView {
    static let previewSize = NSSize(width: 200, height: 130)
    static let previewCellSize = NSSize(width: 220, height: 175)
    static let iconCellSize = NSSize(width: 130, height: 120)

    var onClick: () -> Void = {}
    var isSelected = false { didSet { layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : nil } }

    private let imageView = NSImageView()
    private let badge = NSImageView()

    init(frame: NSRect, item: WindowItem, previews: Bool, dimmed: Bool) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10

        let icon = item.app.icon ?? NSImage()
        let inset: CGFloat = 10
        let label = NSTextField(labelWithString: item.title)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: inset / 2, y: 6, width: frame.width - inset, height: 18)
        addSubview(label)

        let imageTop = frame.height - inset
        let imageSize = previews ? Self.previewSize : NSSize(width: 64, height: 64)
        imageView.frame = NSRect(x: (frame.width - imageSize.width) / 2, y: imageTop - imageSize.height,
                                 width: imageSize.width, height: imageSize.height)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = icon
        addSubview(imageView)

        if previews {
            // Small app icon in the corner of the preview.
            badge.frame = NSRect(x: imageView.frame.minX, y: imageView.frame.minY, width: 32, height: 32)
            badge.image = icon
            badge.isHidden = true
            addSubview(badge)
        }
        if dimmed { alphaValue = 0.35 } else if item.isMinimized { alphaValue = 0.6 }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPreview(_ image: CGImage) {
        imageView.image = NSImage(cgImage: image, size: .zero)
        badge.isHidden = false
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// Shown under the windows: the keys that place the selected window in a
/// zone, next to the keys that pick another window, drawn as keycaps.
private final class KeyTips: NSView {
    private struct Tip {
        let keys: [String]     // "arrows" is drawn as the four arrow keys
        let text: String
    }

    private let tips = [
        Tip(keys: ["⌘", "arrows"], text: "Place the selected\nwindow in a zone"),
        Tip(keys: ["⌘", "1", "2", "3"], text: "Or go straight to\nthe zone with that number"),
        Tip(keys: ["⌘", "⇥"], text: "Pick another\nwindow to place"),
    ]
    private let key: CGFloat = 26, space: CGFloat = 6, blockGap: CGFloat = 40
    private let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
    ]

    init() {
        super.init(frame: .zero)
        var width: CGFloat = 0
        for tip in tips { width += blockWidth(tip) }
        width += blockGap * CGFloat(tips.count - 1)
        setFrameSize(NSSize(width: width, height: 2 * key + space))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func keysWidth(_ tip: Tip) -> CGFloat {
        var width: CGFloat = 0
        for name in tip.keys { width += (name == "arrows" ? 3 * key + 2 * space : key) + space }
        return width
    }

    private func blockWidth(_ tip: Tip) -> CGFloat {
        keysWidth(tip) + 6 + (tip.text as NSString).size(withAttributes: textAttributes).width
    }

    private func drawKey(_ label: String, in rect: CGRect) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        shape.fill()
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        let middle: CGFloat = bounds.height / 2
        for tip in tips {
            for name in tip.keys {
                if name == "arrows" {
                    // ↑ on top, ← ↓ → below, as on the keyboard.
                    drawKey("↑", in: CGRect(x: x + key + space, y: 0, width: key, height: key))
                    for (index, arrow) in ["←", "↓", "→"].enumerated() {
                        drawKey(arrow, in: CGRect(x: x + CGFloat(index) * (key + space), y: key + space, width: key, height: key))
                    }
                    x += 3 * key + 3 * space
                } else {
                    drawKey(name, in: CGRect(x: x, y: middle - key / 2, width: key, height: key))
                    x += key + space
                }
            }
            let text = tip.text as NSString
            let size = text.size(withAttributes: textAttributes)
            text.draw(at: CGPoint(x: x + 6, y: middle - size.height / 2), withAttributes: textAttributes)
            x += 6 + size.width + blockGap
        }
    }
}

/// The screens, side by side as they are arranged, with the numbered zones
/// of the current layout. The zone the selected window is in is highlighted.
/// A small screen next to a big one keeps a readable size.
private final class ZoneMap: NSView {
    typealias Screen = (frame: CGRect, zones: [CGRect], name: String)

    /// Frame of the selected window (origin at the top left), or nil.
    var windowFrame: CGRect? { didSet { needsDisplay = true } }

    private let screens: [Screen]
    private var boxes: [CGRect] = []     // where each screen is drawn

    init(screens: [Screen], height: CGFloat, maxWidth: CGFloat) {
        let xs = screens.map(\.frame.midX), ys = screens.map(\.frame.midY)
        let horizontal = screens.count < 2 || (xs.max()! - xs.min()! >= ys.max()! - ys.min()!)
        self.screens = screens.sorted { horizontal ? $0.frame.midX < $1.frame.midX : $0.frame.midY < $1.frame.midY }
        super.init(frame: .zero)
        guard !screens.isEmpty else { return }
        let gap: CGFloat = 8
        let sizes: [CGSize] = self.screens.map(\.frame.size)
        let count = CGFloat(sizes.count)
        let minimum: CGFloat = height * 0.55
        // A big screen is at most 1.6 times as high (or wide) as the smallest one.
        func scales(_ scale: CGFloat) -> [CGFloat] {
            let side: [CGFloat] = sizes.map { max(horizontal ? $0.height : $0.width, 1) }
            let raised: [CGFloat] = side.map { max(scale, minimum / $0) }
            var smallest: CGFloat = .greatestFiniteMagnitude
            for (length, s) in zip(side, raised) { smallest = min(smallest, length * s) }
            return zip(side, raised).map { length, s in min(s, 1.6 * smallest / length) }
        }
        func total(_ scale: CGFloat) -> CGSize {
            var width: CGFloat = 0, tall: CGFloat = 0
            for (size, s) in zip(sizes, scales(scale)) {
                if horizontal { width += size.width * s; tall = max(tall, size.height * s) }
                else { width = max(width, size.width * s); tall += size.height * s }
            }
            return horizontal ? CGSize(width: width + gap * (count - 1), height: tall)
                              : CGSize(width: width, height: tall + gap * (count - 1))
        }
        var scale: CGFloat = height / max(sizes.map(\.height).max() ?? 1, 1)
        while scale > 0.0001, total(scale).width > maxWidth || total(scale).height > height { scale *= 0.97 }
        let used = total(scale)
        var cursor: CGFloat = 0
        for (size, s) in zip(sizes, scales(scale)) {
            let box: CGRect
            if horizontal {
                box = CGRect(x: cursor, y: used.height - size.height * s, width: size.width * s, height: size.height * s)
                cursor += size.width * s + gap
            } else {
                box = CGRect(x: (used.width - size.width * s) / 2, y: cursor, width: size.width * s, height: size.height * s)
                cursor += size.height * s + gap
            }
            boxes.append(box)
        }
        setFrameSize(NSSize(width: used.width.rounded(.up), height: used.height.rounded(.up)))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Name of the screen the selected window is on.
    var screenName: String? {
        guard let window = windowFrame else { return nil }
        let center = CGPoint(x: window.midX, y: window.midY)
        return screens.first { $0.frame.contains(center) }?.name
    }

    private func local(_ rect: CGRect, on index: Int) -> CGRect {
        let frame = screens[index].frame, box = boxes[index]
        return CGRect(x: box.minX + (rect.minX - frame.minX) / frame.width * box.width,
                      y: box.minY + (rect.minY - frame.minY) / frame.height * box.height,
                      width: rect.width / frame.width * box.width, height: rect.height / frame.height * box.height)
    }

    /// The zone the window fills best, if it fills it well enough.
    private var placed: CGRect? {
        guard let window = windowFrame, window.width > 0, window.height > 0 else { return nil }
        var best: (zone: CGRect, score: CGFloat)?
        for screen in screens {
            for zone in screen.zones {
                let common = zone.intersection(window)
                guard !common.isNull else { continue }
                let union: CGFloat = zone.width * zone.height + window.width * window.height - common.width * common.height
                let score: CGFloat = common.width * common.height / max(union, 1)
                if best == nil || score > best!.score { best = (zone, score) }
            }
        }
        guard let best, best.score > 0.6 else { return nil }
        return best.zone
    }

    override func draw(_ dirtyRect: NSRect) {
        let placed = self.placed
        for (index, screen) in screens.enumerated() {
            let frame = boxes[index].insetBy(dx: 1, dy: 1)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            let outline = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
            outline.fill()
            NSColor.labelColor.withAlphaComponent(0.5).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            for (number, zone) in screen.zones.enumerated() {
                let rect = local(zone, on: index).insetBy(dx: 2, dy: 2)
                let isPlaced = zone == placed
                (isPlaced ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.15)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: max(9, min(16, rect.height * 0.45)), weight: .bold),
                    .foregroundColor: isPlaced ? NSColor.white : NSColor.labelColor,
                ]
                let text = "\(number + 1)" as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }
    }
}

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

    func commit() {
        guard isVisible else { return }
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
        panel.contentView = nil
    }

    private func select(_ index: Int) {
        if let selected { cells[selected].isSelected = false }
        selected = index
        cells[index].isSelected = true
    }

    private func layout(previews: Bool) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let cellSize = previews ? ItemView.previewCellSize : ItemView.iconCellSize
        let padding: CGFloat = 12
        let columns = max(1, min(items.count, Int((screen.visibleFrame.width * 0.9 - 2 * padding) / cellSize.width)))
        let rows = (items.count + columns - 1) / columns
        let size = NSSize(width: CGFloat(columns) * cellSize.width + 2 * padding,
                          height: CGFloat(rows) * cellSize.height + 2 * padding)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14

        cells = items.enumerated().map { index, item in
            let column = index % columns, row = index / columns
            let origin = NSPoint(x: padding + CGFloat(column) * cellSize.width,
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

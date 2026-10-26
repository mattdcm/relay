import AppKit

/// "Large Screen Accessibility" window: the screens on the left, and on the
/// right every resolution macOS reports for the selected screen, including
/// those System Settings hides, with how big text and menus look in each.
/// A resolution is applied at once, for this session only, and a panel asks
/// to keep it: without an answer within 10 seconds, the previous setting comes
/// back, in case the screen shows nothing usable.
/// Only uses Apple's public display API: Relay cannot create resolutions
/// that the screen and the Mac do not offer.
final class DisplaySettings: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var current: DisplaySettings?

    private let window: NSWindow
    private let screenTable = NSTableView()
    private let modeTable = NSTableView()
    private let title = NSTextField(labelWithString: "")
    private var displays: [Display] = []
    private var modes: [CGDisplayMode] = []
    private var nativeWidth = 1
    private var confirmation: KeepPanel?

    static func open() {
        if current == nil { current = DisplaySettings() }
        NSApp.activate()
        current?.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 460),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Large Screen Accessibility"
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildInterface()
        window.center()
        displays = Displays.current()
        screenTable.reloadData()
        screenTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        loadModes()
    }

    func windowWillClose(_ notification: Notification) {
        if DisplaySettings.current === self { DisplaySettings.current = nil }
    }

    // MARK: - Interface

    private func buildInterface() {
        let content = window.contentView!

        let screensLabel = NSTextField(labelWithString: "Screens")
        screensLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        screensLabel.frame = NSRect(x: 20, y: 424, width: 220, height: 18)
        content.addSubview(screensLabel)
        content.addSubview(scrolled(screenTable, frame: NSRect(x: 20, y: 60, width: 220, height: 356)))

        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: 260, y: 424, width: 500, height: 18)
        content.addSubview(title)
        content.addSubview(scrolled(modeTable, frame: NSRect(x: 260, y: 60, width: 500, height: 356)))
        modeTable.doubleAction = #selector(applySelected)
        modeTable.target = self

        let hint = NSTextField(wrappingLabelWithString:
            "Smaller \"looks like\" sizes make text, menus and window titles bigger. The change is applied at once; "
            + "keep it within 10 seconds, or the previous setting comes back.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 12, width: 620, height: 32)
        content.addSubview(hint)

        let apply = NSButton(title: "Apply", target: self, action: #selector(applySelected))
        apply.keyEquivalent = "\r"
        apply.frame = NSRect(x: 670, y: 14, width: 90, height: 32)
        content.addSubview(apply)
    }

    private func scrolled(_ table: NSTableView, frame: NSRect) -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = frame.width - 20
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView(frame: frame)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    // MARK: - Modes

    private var selectedDisplay: Display? {
        let row = screenTable.selectedRow
        return displays.indices.contains(row) ? displays[row] : nil
    }

    /// Every mode of the screen, one per size and sharpness (the highest
    /// refresh rate), biggest first.
    private func loadModes() {
        guard let display = selectedDisplay else {
            modes = []
            modeTable.reloadData()
            return
        }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(display.number, options) as? [CGDisplayMode]) ?? []
        var best: [String: CGDisplayMode] = [:]
        for mode in all {
            let key = "\(mode.width)x\(mode.height)-\(mode.pixelWidth > mode.width)"
            if let existing = best[key], existing.refreshRate >= mode.refreshRate { continue }
            best[key] = mode
        }
        modes = best.values.sorted { a, b in
            a.width != b.width ? a.width > b.width : a.pixelWidth > b.pixelWidth
        }
        nativeWidth = all.map(\.pixelWidth).max() ?? 1
        title.stringValue = "Resolutions for \(display.name)"
        modeTable.reloadData()
        if let currentMode = CGDisplayCopyDisplayMode(display.number),
           let row = modes.firstIndex(where: { Self.same($0, currentMode) }) {
            modeTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            modeTable.scrollRowToVisible(row)
        }
    }

    private static func same(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.width == b.width && a.height == b.height && a.pixelWidth == b.pixelWidth
    }

    /// One line of the list: size, how big text looks, sharpness, and warnings.
    private func describe(_ mode: CGDisplayMode, on display: Display) -> String {
        var parts = ["Looks like \(mode.width) × \(mode.height)"]
        let scale = Int((Double(nativeWidth) / Double(max(mode.width, 1)) * 100).rounded())
        parts.append("text \(scale) %")
        parts.append(mode.pixelWidth > mode.width ? "sharp (HiDPI)" : "standard")
        if let native = modes.first, abs(Double(mode.width) / Double(mode.height) - Double(native.width) / Double(native.height)) > 0.05 {
            parts.append("other shape")
        }
        if !mode.isUsableForDesktopGUI() { parts.append("not recommended by macOS") }
        if let currentMode = CGDisplayCopyDisplayMode(display.number), Self.same(mode, currentMode) {
            parts.insert("✓", at: 0)
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === screenTable ? displays.count : modes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === screenTable {
            text = displays[row].name
        } else if let display = selectedDisplay {
            text = describe(modes[row], on: display)
        } else {
            text = ""
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === screenTable { loadModes() }
    }

    // MARK: - Applying

    @objc private func applySelected() {
        let row = modeTable.selectedRow
        guard confirmation == nil, let display = selectedDisplay, modes.indices.contains(row) else { return }
        let mode = modes[row]
        guard let previous = CGDisplayCopyDisplayMode(display.number), !Self.same(mode, previous) else { return }
        guard Self.set(mode, on: display.number, permanently: false) else {
            NSSound.beep()
            return
        }
        confirmation = KeepPanel(seconds: 10) { [weak self] keep in
            // Kept: saved for good. Otherwise: the previous resolution, set
            // explicitly (restoring "the saved configuration" is not reliable).
            _ = Self.set(keep ? mode : previous, on: display.number, permanently: true)
            self?.confirmation = nil
            self?.loadModes()
        }
    }

    private static func set(_ mode: CGDisplayMode, on number: CGDirectDisplayID, permanently: Bool) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, number, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, permanently ? .permanently : .forSession) == .success
    }
}

/// "Keep these display settings?" with a countdown. Without an answer, the
/// previous setting comes back. Shown on the main screen (with the menu bar).
private final class KeepPanel: NSObject {
    private let panel: NSPanel
    private let countdown = NSTextField(labelWithString: "")
    private var remaining: Int
    private var timer: Timer?
    private let done: (Bool) -> Void

    init(seconds: Int, done: @escaping (Bool) -> Void) {
        remaining = seconds
        self.done = done
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "Relay"
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = panel.contentView!

        let question = NSTextField(labelWithString: "Keep these display settings?")
        question.font = .systemFont(ofSize: 14, weight: .semibold)
        question.frame = NSRect(x: 20, y: 90, width: 320, height: 22)
        content.addSubview(question)
        countdown.frame = NSRect(x: 20, y: 64, width: 320, height: 18)
        countdown.textColor = .secondaryLabelColor
        content.addSubview(countdown)

        let revert = NSButton(title: "Revert", target: self, action: #selector(revertNow))
        revert.keyEquivalent = "\u{1b}"
        revert.frame = NSRect(x: 150, y: 14, width: 90, height: 32)
        content.addSubview(revert)
        let keep = NSButton(title: "Keep", target: self, action: #selector(keepNow))
        keep.keyEquivalent = "\r"
        keep.frame = NSRect(x: 250, y: 14, width: 90, height: 32)
        content.addSubview(keep)

        update()
        // Shown once macOS has redrawn the screens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if let screen = NSScreen.screens.first {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
            }
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func update() {
        countdown.stringValue = "The previous setting comes back in \(remaining) s."
    }

    private func tick() {
        remaining -= 1
        update()
        if remaining <= 0 { finish(keep: false) }
    }

    @objc private func keepNow() { finish(keep: true) }
    @objc private func revertNow() { finish(keep: false) }

    private func finish(keep: Bool) {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        done(keep)
    }
}

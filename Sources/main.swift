import AppKit
import ServiceManagement

/// Entry point: the menu-bar icon and its menu.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keepAwake = KeepAwake()
    private let switcher = Switcher()
    private let hotkey = Hotkey()
    private let activity = Activity()
    private let layouts = LayoutStore()
    private let snapper = Snapper()
    private let zoomHover = ZoomHover()
    private let updates = Updates()
    private var setup = Displays.setupKey()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    /// Previews are off by default: without them, no Screen Recording
    /// permission is requested.
    private var previewsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "previews") }
        set { UserDefaults.standard.set(newValue, forKey: "previews") }
    }

    /// ⇥ only cycles through apps used within this many minutes (0: no limit).
    private var recentMinutes: Int {
        get { UserDefaults.standard.object(forKey: "recentMinutes") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "recentMinutes") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        keepAwake.onChange = { [weak self] in self?.refresh() }
        updates.onChange = { [weak self] in self?.refresh() }
        updates.schedule()

        hotkey.onNext = { [weak self] backwards in
            guard let self else { return }
            if self.switcher.isVisible {
                self.switcher.move(backwards: backwards)
            } else {
                let interval = self.recentMinutes > 0 ? TimeInterval(self.recentMinutes * 60) : nil
                self.switcher.show(withPreviews: self.previewsEnabled && Previews.isAllowed, backwards: backwards) {
                    self.activity.recentApps(within: interval, windowOrder: $0.map(\.app.processIdentifier))
                }
            }
        }
        hotkey.onRelease = { [weak self] in self?.switcher.commit() }
        hotkey.onCancel = { [weak self] in self?.switcher.cancel() }
        hotkey.onLayout = { [weak self] index in
            guard let self else { return }
            let list = self.layouts.layouts(for: self.setup)
            if list.indices.contains(index) { self.apply(list[index]) }
        }
        snapper.currentLayout = { [weak self] in
            guard let self else { return nil }
            return self.layouts.lastApplied(for: self.setup)
        }
        zoomHover.currentLayout = { [weak self] in
            guard let self else { return nil }
            return self.layouts.lastApplied(for: self.setup) ?? self.layouts.layouts(for: self.setup).first
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }

        // Ask for the Accessibility permission if needed, then wait until it is granted.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(prompt) || !hotkey.start() || !snapper.start() {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self, AXIsProcessTrusted(), self.hotkey.start(), self.snapper.start() else { return }
                timer.invalidate()
                self.zoomHover.start()
                self.refresh()
            }
        } else {
            zoomHover.start()
        }
        refresh()
    }

    /// Updates the icon and rebuilds the menu.
    private func refresh() {
        let symbol = keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: "Relay")
        statusItem.button?.image = updates.available == nil ? icon : icon.map { withDot($0) }
        let menu = NSMenu()
        menu.delegate = self
        fill(menu)
        statusItem.menu = menu
    }

    /// Called by macOS just before opening the menu: it always reflects the
    /// current state of permissions.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
    }

    private func fill(_ menu: NSMenu) {
        if let update = updates.available {
            menu.addItem(info("Relay \(update.version) is available"))
            menu.addItem(item("Install Update…") { [weak self] in self?.updates.install() })
            menu.addItem(item("What's New…") { NSWorkspace.shared.open(update.page) })
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: "Keep Awake"))
        menu.addItem(item("Prevent Sleep", checked: keepAwake.isActive) { [weak self] in
            guard let self else { return }
            self.keepAwake.isActive ? self.keepAwake.deactivate() : self.keepAwake.activate(for: nil)
        })
        let durations = NSMenu()
        durations.addItem(item("Indefinitely", checked: keepAwake.isActive && keepAwake.endDate == nil) { [weak self] in
            self?.keepAwake.activate(for: nil)
        })
        for (title, minutes) in [("15 minutes", 15), ("1 hour", 60), ("2 hours", 120), ("5 hours", 300)] {
            durations.addItem(item(title) { [weak self] in self?.keepAwake.activate(for: TimeInterval(minutes * 60)) })
        }
        let durationItem = NSMenuItem(title: "For…", action: nil, keyEquivalent: "")
        durationItem.submenu = durations
        menu.addItem(durationItem)
        if let end = keepAwake.endDate {
            menu.addItem(info("Until \(end.formatted(date: .omitted, time: .shortened))"))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Window Switch"))
        if AXIsProcessTrusted() {
            menu.addItem(info("Switch windows: ⌘⇥"))
        } else {
            menu.addItem(item("⚠️ Allow Accessibility…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })
        }
        let recents = NSMenu()
        let choices = [("5 min", 5), ("10 min", 10), ("15 min", 15), ("20 min", 20), ("30 min", 30),
                       ("1 h", 60), ("2 h", 120), ("24 h", 1440), ("No limit", 0)]
        for (title, minutes) in choices {
            recents.addItem(item(title, checked: minutes == recentMinutes) { [weak self] in
                self?.recentMinutes = minutes
                self?.refresh()
            })
        }
        let current = choices.first { $0.1 == recentMinutes }?.0 ?? "\(recentMinutes) min"
        let recentItem = NSMenuItem(title: "Recent apps for ⌘⇥: \(current)", action: nil, keyEquivalent: "")
        recentItem.submenu = recents
        menu.addItem(recentItem)
        menu.addItem(item("Show Window Previews", checked: previewsEnabled) { [weak self] in
            guard let self else { return }
            self.previewsEnabled.toggle()
            if self.previewsEnabled && !Previews.isAllowed { Previews.requestPermission() }
            self.refresh()
        })
        if previewsEnabled && !Previews.isAllowed {
            menu.addItem(item("⚠️ Allow Screen Recording…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            })
        }
        if previewsEnabled {
            menu.addItem(info("If previews fail: untick, tick again, then relaunch"))
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Productive Windows"))
        fillLayouts(menu)

        menu.addItem(.separator())
        let login = SMAppService.mainApp
        menu.addItem(item("Open at Login", checked: login.status == .enabled) { [weak self] in
            _ = try? (login.status == .enabled ? login.unregister() : login.register())
            self?.refresh()
        })

        menu.addItem(item("Check for Updates Weekly", checked: updates.isEnabled) { [weak self] in
            self?.updates.isEnabled.toggle()
            self?.refresh()
        })
        menu.addItem(info("Relay \(Updates.currentVersion)"))
        let relaunchItem = item("Relaunch Relay") { [weak self] in self?.relaunch() }
        // Shown in the checkmark column, as the "on" state image.
        relaunchItem.onStateImage = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Relaunch")
        relaunchItem.state = .on
        menu.addItem(relaunchItem)

        menu.addItem(.separator())
        let support = item("Support Relay") {
            NSWorkspace.shared.open(URL(string: "https://revolut.me/matthi9uf")!)
        }
        // The € sign is shown in the checkmark column, as the "on" state image.
        support.onStateImage = NSImage(systemSymbolName: "eurosign", accessibilityDescription: "Euro")
        support.state = .on
        menu.addItem(support)
        menu.addItem(item("Quit Relay") { NSApp.terminate(nil) })
    }

    // MARK: - Layouts

    private func fillLayouts(_ menu: NSMenu) {
        let names = Displays.current().map(\.name).joined(separator: " + ")
        menu.addItem(info("Screens: \(names)"))
        let last = layouts.lastApplied(for: setup)?.id
        for (index, layout) in layouts.layouts(for: setup).enumerated() {
            let entry = NSMenuItem(title: layout.name, action: nil, keyEquivalent: "")
            entry.state = layout.id == last ? .on : .off
            entry.submenu = layoutMenu(layout, canApply: true)
            if index < 9 { entry.title += "    ⌃⌥\(index + 1)" }
            menu.addItem(entry)
        }
        menu.addItem(item("New Layout…") { [weak self] in
            guard let self else { return }
            let count = self.layouts.layouts(for: self.setup).count
            self.edit(self.layouts.makeLayout(named: "Layout \(count + 1)"))
        })
        menu.addItem(item("Auto-apply on screen change", checked: layouts.autoApply) { [weak self] in
            self?.layouts.autoApply.toggle()
        })
        menu.addItem(info("Hold ⇧ while dragging a window to snap it"))
        menu.addItem(item("Zones on Green Button Hover", checked: zoomHover.isEnabled) { [weak self] in
            self?.zoomHover.isEnabled.toggle()
        })
        let others = layouts.layouts(notFor: setup)
        if !others.isEmpty {
            let submenu = NSMenu()
            for layout in others {
                let screens = layout.screenNames.values.sorted().joined(separator: " + ")
                let entry = NSMenuItem(title: "\(layout.name)  (\(screens))", action: nil, keyEquivalent: "")
                entry.submenu = layoutMenu(layout, canApply: false)
                submenu.addItem(entry)
            }
            let entry = NSMenuItem(title: "Other Screen Setups", action: nil, keyEquivalent: "")
            entry.submenu = submenu
            menu.addItem(entry)
        }
    }

    private func layoutMenu(_ layout: Layout, canApply: Bool) -> NSMenu {
        let menu = NSMenu()
        if canApply { menu.addItem(item("Apply") { [weak self] in self?.apply(layout) }) }
        menu.addItem(item("Edit Zones…") { [weak self] in self?.edit(layout) })
        menu.addItem(item("Rename…") { [weak self] in
            guard let self, let name = self.ask("Rename Layout", default: layout.name) else { return }
            var renamed = layout
            renamed.name = name
            self.layouts.save(renamed)
        })
        menu.addItem(item("Duplicate") { [weak self] in
            var copy = layout
            copy.id = UUID()
            copy.name += " copy"
            copy.screens = layout.screens.mapValues(Zone.copy)
            self?.layouts.save(copy)
        })
        menu.addItem(item("Delete") { [weak self] in
            guard let self, self.confirm("Delete “\(layout.name)”?") else { return }
            self.layouts.delete(layout)
        })
        return menu
    }

    private func apply(_ layout: Layout) {
        Arranger.apply(layout)
        layouts.markApplied(layout)
    }

    private func edit(_ layout: Layout) {
        ZoneEditor.open(layout) { [weak self] edited in
            self?.layouts.save(edited)
            // Once the editor has closed, so that its window is out of the way.
            DispatchQueue.main.async { self?.apply(edited) }
        }
    }

    /// Screen plugged in or unplugged: reapply the last layout of the new setup,
    /// once macOS has placed the screens.
    private func screensChanged() {
        let newSetup = Displays.setupKey()
        guard newSetup != setup else { return }
        setup = newSetup
        guard layouts.autoApply, let layout = layouts.lastApplied(for: setup) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Arranger.apply(layout) }
    }

    private func ask(_ title: String, default value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func confirm(_ title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Quits and reopens Relay, so that macOS applies a newly granted permission.
    private func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
    }

    /// The menu-bar icon with a small dot in its corner: an update is available.
    private func withDot(_ icon: NSImage) -> NSImage {
        let image = NSImage(size: icon.size, flipped: false) { rect in
            // Drawn at display time, so the color follows the menu bar's appearance.
            icon.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            let diameter: CGFloat = 6
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter,
                                        width: diameter, height: diameter)).fill()
            return true
        }
        image.accessibilityDescription = "Relay, update available"
        return image
    }

    // MARK: - Small menu helpers

    private func item(_ title: String, checked: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
        let menuItem = ClosureMenuItem(title: title, action: action)
        menuItem.state = checked ? .on : .off
        return menuItem
    }

    private func info(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }
}

/// Menu item that runs a closure when chosen.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

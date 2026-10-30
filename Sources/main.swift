import AppKit
import ServiceManagement

/// Entry point: the menu-bar icon and its menu.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keepAwake = KeepAwake()
    private let closedLid = ClosedLid()
    private let switcher = Switcher()
    private let hotkey = Hotkey()
    private let activity = Activity()
    private let layouts = LayoutStore()
    private let snapper = Snapper()
    private let zoneResizer = ZoneResizer()
    private let zoomHover = ZoomHover()
    private let zoneMover = ZoneMover()
    private let updates = Updates()
    private var setup = Displays.setupKey()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    /// When the pointer goes to the chosen window after a switch.
    enum PointerRule: String, CaseIterable {
        case never, always, otherScreen, severalScreens, screen27, screen32, screen40

        var title: String {
            switch self {
            case .never: return "Never"
            case .always: return "Always"
            case .otherScreen: return "When the Window Is on Another Screen"
            case .severalScreens: return "When Several Screens Are Connected"
            case .screen27: return "When a Screen Is 27\" or Larger"
            case .screen32: return "When a Screen Is 32\" or Larger"
            case .screen40: return "When a Screen Is 40\" or Larger"
            }
        }

        /// Shown in the menu item that opens the choices.
        var shortTitle: String {
            switch self {
            case .never: return "Never"
            case .always: return "Always"
            case .otherScreen: return "Other Screen"
            case .severalScreens: return "Several Screens"
            case .screen27: return "27\" Screen"
            case .screen32: return "32\" Screen"
            case .screen40: return "40\" Screen"
            }
        }

        var minimumInches: Double? {
            switch self {
            case .screen27: return 27
            case .screen32: return 32
            case .screen40: return 40
            default: return nil
            }
        }
    }

    /// Never by default. Older versions only had on/off ("pointerFollows").
    private var pointerRule: PointerRule {
        get {
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: "pointerRule"), let rule = PointerRule(rawValue: raw) { return rule }
            return defaults.bool(forKey: "pointerFollows") ? .always : .never
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pointerRule") }
    }

    private func pointerShouldMove(to frame: CGRect) -> Bool {
        switch pointerRule {
        case .never: return false
        case .always: return true
        case .severalScreens: return NSScreen.screens.count > 1
        case .otherScreen:
            guard let pointer = CGEvent(source: nil)?.location else { return true }
            return Self.display(at: pointer) != Self.display(at: CGPoint(x: frame.midX, y: frame.midY))
        case .screen27, .screen32, .screen40:
            // Half an inch of margin: a 27" screen often reports 26.9".
            let minimum = pointerRule.minimumInches ?? 0
            return Self.screenDiagonals().contains { $0 + 0.5 >= minimum }
        }
    }

    /// The screen under a point (origin at the top left).
    private static func display(at point: CGPoint) -> CGDirectDisplayID? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }

    /// Diagonal of each connected screen in inches, from the physical size the
    /// screen reports (0 when it reports nothing, as some projectors do).
    private static func screenDiagonals() -> [Double] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            let size = CGDisplayScreenSize(number)
            return Double(hypot(size.width, size.height)) / 25.4
        }
    }

    /// Puts the pointer in the middle of the window horizontally, near its
    /// bottom (5% from it), where the next action usually is, once the window
    /// is in front.
    private func movePointer(to item: WindowItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let frame: CGRect
            if let own = item.own {
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                frame = CGRect(x: own.frame.minX, y: primaryHeight - own.frame.maxY, width: own.frame.width, height: own.frame.height)
            } else {
                frame = WindowList.frame(of: item.element)
            }
            guard frame.width > 0, frame.height > 0, self.pointerShouldMove(to: frame) else { return }
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.maxY - frame.height * 0.05))
        }
    }

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

    /// Sleep is never left turned off behind Relay.
    func applicationWillTerminate(_ notification: Notification) {
        closedLid.deactivate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        WindowList.startTracking()
        keepAwake.onChange = { [weak self] in
            guard let self else { return }
            // The lid option only goes with a time limit.
            if !self.keepAwake.isActive || self.keepAwake.endDate == nil { self.closedLid.deactivate() }
            self.refresh()
        }
        closedLid.onChange = { [weak self] in self?.refresh() }
        updates.onChange = { [weak self] in self?.refresh() }
        updates.schedule()

        hotkey.onNext = { [weak self] backwards in
            guard let self else { return }
            if self.zoneMover.isActive {
                // ⇥ after placing a window: keep it there and pick another one.
                self.zoneMover.commit()
                self.switcher.showPanel()
                self.switcher.move(backwards: backwards)
            } else if self.switcher.isVisible {
                self.switcher.move(backwards: backwards)
            } else {
                let interval = self.recentMinutes > 0 ? TimeInterval(self.recentMinutes * 60) : nil
                self.switcher.show(withPreviews: self.previewsEnabled && Previews.isAllowed, backwards: backwards) {
                    self.activity.recentApps(within: interval, windowOrder: $0.map(\.app.processIdentifier))
                }
            }
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            let chosen = self.switcher.selectedItem
            defer { if self.pointerRule != .never, let chosen { self.movePointer(to: chosen) } }
            if self.zoneMover.isActive {
                // The window is already in its zone and in front.
                self.zoneMover.commit()
                self.switcher.cancel()
            } else {
                self.switcher.commit()
            }
        }
        hotkey.onCancel = { [weak self] in
            self?.zoneMover.cancel()
            self?.switcher.cancel()
        }
        hotkey.onZone = { [weak self] direction in
            guard let self, self.startZoneMode() else { return }
            self.zoneMover.move(direction)
        }
        hotkey.onZoneNumber = { [weak self] digit in
            guard let self, self.startZoneMode() else { return }
            self.zoneMover.typed(digit)
        }
        hotkey.onLayout = { [weak self] index in
            guard let self else { return }
            let list = self.layouts.layouts(for: self.setup)
            if list.indices.contains(index) { self.apply(list[index]) }
        }
        snapper.currentLayout = { [weak self] in
            guard let self else { return nil }
            return self.layouts.lastApplied(for: self.setup)
        }
        snapper.onResizing = { [weak self] window, before in
            guard let self, let layout = self.layouts.lastApplied(for: self.setup) else { return }
            self.zoneResizer.update(window, from: before, layout: layout)
        }
        snapper.onResize = { [weak self] window, before, after in
            guard let self, let layout = self.layouts.lastApplied(for: self.setup) else { return }
            if let changed = self.zoneResizer.finish(window, from: before, to: after, layout: layout) {
                self.layouts.save(changed)
            }
        }
        snapper.onNoResize = { [weak self] in self?.zoneResizer.cancel() }
        switcher.zoneScreens = { [weak self] in
            guard let self else { return [] }
            let layout = self.layouts.lastApplied(for: self.setup) ?? self.layouts.layouts(for: self.setup).first
            return Displays.current().map { (frame: $0.frame, zones: ZoneMover.zones(on: $0, layout: layout), name: $0.name) }
        }
        hotkey.wantsDigits = { [weak self] in self?.zoomHover.isShowing ?? false }
        hotkey.onDigit = { [weak self] digit in self?.zoomHover.typed(digit) }
        zoomHover.currentLayout = { [weak self] in
            guard let self else { return nil }
            return self.layouts.lastApplied(for: self.setup) ?? self.layouts.layouts(for: self.setup).first
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
            // macOS can report a new screen before it is fully set up: check again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.screensChanged() }
        }

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
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        fill(menu)
        statusItem.menu = menu
    }

    private func updateIcon() {
        let symbol = keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: "Relay")
        statusItem.button?.image = updates.showsDot ? icon.map { withDot($0) } : icon
    }

    /// Called by macOS just before opening the menu: it always reflects the
    /// current state of permissions. Opening it also clears the update dot.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
        if updates.showsDot {
            updates.markSeen()
            updateIcon()
        }
    }

    private func fill(_ menu: NSMenu) {
        if let update = updates.available {
            // Optional: a single line, the update is never forced.
            menu.addItem(item("Install Version \(update.version) (Available)…") { [weak self] in self?.updates.install() })
            menu.addItem(.separator())
        }
        menu.addItem(header("Keep Awake", symbol: "cup.and.saucer"))
        var title = "Prevent Sleep"
        let battery = KeepAwake.battery()
        if keepAwake.isActive {
            var limits: [String] = []
            if let end = keepAwake.endDate {
                limits.append("\(Self.duration(max(0, Int(end.timeIntervalSinceNow / 60)))) left")
            }
            if battery != nil, let limit = keepAwake.batteryLimit { limits.append("until \(limit) % battery") }
            title += " (" + (limits.isEmpty ? "indefinitely" : limits.joined(separator: ", or ")) + ")"
        }
        let durations = NSMenu()
        durations.addItem(item("Indefinitely", checked: keepAwake.isActive && keepAwake.endDate == nil) { [weak self] in
            self?.keepAwake.activate(for: nil)
        })
        // The usual durations and the last two custom ones, shortest first.
        let presets: [Int] = [15, 60, 120, 300]
        for minutes in Set(presets + customDurations).sorted() {
            let custom = !presets.contains(minutes)
            durations.addItem(item(Self.duration(minutes) + (custom ? " (custom)" : "")) { [weak self] in
                self?.keepAwake.activate(for: TimeInterval(minutes * 60))
            })
        }
        durations.addItem(item("Custom Time…") { [weak self] in
            guard let self, let minutes = self.askDuration() else { return }
            self.customDurations = Array(([minutes] + self.customDurations.filter { $0 != minutes }).prefix(2))
            self.keepAwake.activate(for: TimeInterval(minutes * 60))
        })
        // Only on a Mac with a battery.
        if let battery {
            durations.addItem(.separator())
            durations.addItem(info("Or Until the Battery Reaches (now \(battery.level) %)"))
            durations.addItem(item("No Battery Limit", checked: keepAwake.batteryLimit == nil) { [weak self] in
                self?.keepAwake.batteryLimit = nil
            })
            for level in [50, 30, 20, 10] {
                durations.addItem(item("\(level) %", checked: keepAwake.batteryLimit == level) { [weak self] in
                    self?.keepAwake.batteryLimit = level
                })
            }
        }
        if keepAwake.isActive {
            durations.addItem(.separator())
            durations.addItem(item("Stop Preventing Sleep") { [weak self] in self?.keepAwake.deactivate() })
        }
        let preventItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        preventItem.state = keepAwake.isActive ? .on : .off
        preventItem.submenu = durations
        menu.addItem(preventItem)
        if let end = keepAwake.endDate {
            menu.addItem(info("Until \(end.formatted(date: .omitted, time: .shortened))"))
        }
        // Only with a time limit, never indefinitely.
        if keepAwake.isActive, let end = keepAwake.endDate {
            menu.addItem(item("Even With the Lid Closed", checked: closedLid.isActive) { [weak self] in
                guard let self else { return }
                if self.closedLid.isActive {
                    self.closedLid.deactivate()
                } else if self.confirmClosedLid() {
                    self.closedLid.activate(until: end)
                }
            })
        } else {
            menu.addItem(info("Even With the Lid Closed (choose a duration first)"))
        }
        menu.addItem(info("The Mac sleeps anyway if it gets too hot"))

        menu.addItem(.separator())
        menu.addItem(header("Window Switch", symbol: "command"))
        if AXIsProcessTrusted() {
            menu.addItem(info("Switch windows: ⌘⇥"))
            menu.addItem(info("Move it to a zone: ⌘⇥, then arrows (⌘ held)"))
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
        let pointerRules = NSMenu()
        for rule in PointerRule.allCases {
            if rule == .otherScreen || rule == .screen27 { pointerRules.addItem(.separator()) }
            pointerRules.addItem(item(rule.title, checked: rule == pointerRule) { [weak self] in
                self?.pointerRule = rule
            })
        }
        let sizes = Self.screenDiagonals().map { $0 > 0 ? "\(Int($0.rounded()))\"" : "size unknown" }
        pointerRules.addItem(.separator())
        pointerRules.addItem(info("Your screens: " + sizes.joined(separator: ", ")))
        let pointerItem = NSMenuItem(title: "Move Pointer to the Chosen Window: \(pointerRule.shortTitle)",
                                     action: nil, keyEquivalent: "")
        pointerItem.submenu = pointerRules
        menu.addItem(pointerItem)
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
        menu.addItem(header("Productive Windows", symbol: "square.split.2x2"))
        fillLayouts(menu)

        menu.addItem(.separator())
        menu.addItem(item("Large Screen Accessibility…") { DisplaySettings.open() })

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

        // The items of each section are indented under its title, up to the
        // next separator.
        var inSection = false
        for menuItem in menu.items {
            if menuItem.isSeparatorItem {
                inSection = false
            } else if menuItem.identifier == Self.headerID {
                inSection = true
            } else if inSection {
                menuItem.indentationLevel = 1
            }
        }
    }

    // MARK: - Layouts

    private func fillLayouts(_ menu: NSMenu) {
        // In case a screen change was missed, check the screens again.
        screensChanged()
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
        menu.addItem(item("Dragging a Window Suggests the Layout Zones", checked: snapper.isEnabled) { [weak self] in
            self?.snapper.isEnabled.toggle()
        })
        menu.addItem(item("Resizing a Window Resizes Its Zone", checked: ZoneResizer.isEnabled) {
            ZoneResizer.isEnabled.toggle()
        })
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
        ZoneEditor.open(layout, previews: previewsEnabled && Previews.isAllowed) { [weak self] edited in
            self?.layouts.save(edited)
            // Once the editor has closed, so that its window is out of the way.
            DispatchQueue.main.async { self?.apply(edited) }
        }
    }

    /// Zone mode of the switcher, with the window selected in it. Returns
    /// false if there is no window to move.
    private func startZoneMode() -> Bool {
        if zoneMover.isActive { return true }
        guard let item = switcher.selectedItem, item.own == nil else { return false }
        switcher.hidePanel()
        zoneMover.start(item, layout: layouts.lastApplied(for: setup) ?? layouts.layouts(for: setup).first)
        return true
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
        field.formatter = LayoutNameFormatter()
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = Layout.cleanName(field.stringValue)
        return name.isEmpty ? nil : name
    }

    /// The last two custom durations chosen, in minutes, most recent first.
    private var customDurations: [Int] {
        get { UserDefaults.standard.array(forKey: "customDurations") as? [Int] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "customDurations") }
    }

    /// "15 min", "1 hour", "2 hours", "1 h 30 min".
    private static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        if rest == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours) h \(rest) min"
    }

    /// Asks for a duration in hours and minutes. Returns minutes, or nil.
    private func askDuration() -> Int? {
        let alert = NSAlert()
        alert.messageText = "Prevent sleep for how long?"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        func field(_ x: CGFloat, _ value: String) -> NSTextField {
            let field = NSTextField(frame: NSRect(x: x, y: 0, width: 50, height: 24))
            let numbers = NumberFormatter()
            numbers.allowsFloats = false
            numbers.minimum = 0
            numbers.maximum = 999
            field.formatter = numbers
            field.stringValue = value
            box.addSubview(field)
            return field
        }
        func label(_ x: CGFloat, _ text: String) {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: x, y: 3, width: 70, height: 18)
            box.addSubview(label)
        }
        let hours = field(0, "1")
        label(56, "hours")
        let minutes = field(130, "30")
        label(186, "minutes")
        alert.accessoryView = box
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = hours
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let total = min(hours.integerValue, 999) * 60 + min(minutes.integerValue, 999)
        return total > 0 ? total : nil
    }

    /// Warning shown each time before keeping the Mac awake with its lid closed.
    private func confirmClosedLid() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keep the Mac awake with the lid closed?"
        alert.informativeText = """
            A closed laptop cools down less well. While this mode is on:

            • Leave the Mac on a hard, open surface: never in a bag, a sleeve or a closed drawer.
            • Do not use it in direct sunlight, in a hot car or during a heat wave.

            Relay puts the Mac to sleep when macOS reports that it is getting hot, but it cannot \
            detect every situation. You use this mode at your own risk: Relay is provided without \
            any warranty (GNU GPL v3).
            """
        // The safe choice is the default one.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Keep Awake")
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
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

    private static let headerID = NSUserInterfaceItemIdentifier("sectionHeader")

    /// Section title: bold, in the normal text colour, with an icon, so it
    /// stands out more than the small grey macOS section headers.
    private func header(_ title: String, symbol: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        menuItem.identifier = Self.headerID
        let font = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
        let icon = NSImageView(frame: NSRect(x: 14, y: 4, width: 18, height: 16))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: title)
        label.font = font
        label.textColor = .labelColor
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 38, y: (24 - label.frame.height) / 2))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.maxX + 14, height: 24))
        view.addSubview(icon)
        view.addSubview(label)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(title)
        menuItem.view = view
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

import AppKit

/// Intercepts ⌘⇥ (Command-Tab) at the keyboard level, instead of the
/// macOS app switcher.
/// Other keys pass through without being read or recorded: only the key code
/// and the state of the modifier keys are examined.
/// Requires the Accessibility permission.
final class Hotkey {
    var onNext: (_ backwards: Bool) -> Void = { _ in }  // ⌘⇥ or ⌘⇧⇥, arrows
    var onRelease: () -> Void = {}                       // ⌘ released: confirm
    var onCancel: () -> Void = {}                        // Esc: cancel
    var onLayout: (_ index: Int) -> Void = { _ in }      // ⌃⌥1 to ⌃⌥9: apply a layout

    /// Key to hold. Set to `.maskAlternate` to go back to ⌥⇥.
    static let modifier: CGEventFlags = .maskCommand

    private var tap: CFMachPort?
    private var active = false

    private enum Key {
        static let tab: Int64 = 48, escape: Int64 = 53, left: Int64 = 123, right: Int64 = 124
        static let digits: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // keys 1 to 9
    }

    /// Returns false if macOS refuses (Accessibility permission missing).
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let hotkey = Unmanaged<Hotkey>.fromOpaque(refcon!).takeUnretainedValue()
                return hotkey.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        return true
    }

    /// Returns true if the event must be blocked (must not reach the active app).
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // macOS disables the tap if it is too slow: turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let flags = event.flags
        if type == .flagsChanged {
            if active && !flags.contains(Self.modifier) {
                active = false
                onRelease()
            }
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let others: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        let modifierOnly = flags.contains(Self.modifier) && flags.intersection(others) == Self.modifier

        if key == Key.tab && modifierOnly {
            if type == .keyDown {
                active = true
                onNext(flags.contains(.maskShift))
            }
            return true
        }
        if type == .keyDown, flags.contains([.maskControl, .maskAlternate]), !flags.contains(.maskCommand),
           let index = Key.digits.firstIndex(of: key) {
            onLayout(index)
            return true
        }
        guard active else { return false }
        if type == .keyDown {
            switch key {
            case Key.escape: active = false; onCancel()
            case Key.left: onNext(true)
            case Key.right: onNext(false)
            default: return false
            }
        }
        return [Key.escape, Key.left, Key.right].contains(key)
    }
}

import Foundation
import IOKit.pwr_mgt
import IOKit.ps

/// Prevents the display and the Mac from sleeping while a power "assertion"
/// is active. This is the official macOS mechanism.
/// Check it with `pmset -g assertions`.
final class KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private var batteryTimer: Timer?
    private(set) var isActive = false
    private(set) var endDate: Date?
    var onChange: (() -> Void)?

    /// Stops when the Mac runs on battery and the charge falls to this level
    /// (in %). nil: no battery limit. Kept between launches.
    var batteryLimit: Int? {
        get { let value = UserDefaults.standard.integer(forKey: "batteryLimit"); return value > 0 ? value : nil }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "batteryLimit"); checkBattery() }
    }

    /// The battery charge in %, and whether the Mac runs on it. nil: no battery.
    /// Read from macOS' public power-source information: no permission needed.
    static func battery() -> (level: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return (current * 100 / max, onBattery)
        }
        return nil
    }

    /// `duration == nil`: no time limit.
    func activate(for duration: TimeInterval?) {
        release()
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Relay: sleep prevented" as CFString,
            &assertionID)
        if result == kIOReturnSuccess {
            isActive = true
            if let duration {
                endDate = Date().addingTimeInterval(duration)
                timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                    self?.deactivate()
                }
            }
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.checkBattery()
            }
        }
        onChange?()
    }

    func deactivate() {
        release()
        onChange?()
    }

    private func checkBattery() {
        guard isActive, let limit = batteryLimit, let battery = Self.battery(),
              battery.onBattery, battery.level <= limit else { return }
        deactivate()
    }

    private func release() {
        timer?.invalidate()
        timer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        endDate = nil
        if isActive {
            IOPMAssertionRelease(assertionID)
            isActive = false
        }
    }
}

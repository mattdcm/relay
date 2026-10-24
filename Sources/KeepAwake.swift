import Foundation
import IOKit.pwr_mgt

/// Prevents the display and the Mac from sleeping while a power "assertion"
/// is active. This is the official macOS mechanism.
/// Check it with `pmset -g assertions`.
final class KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private(set) var isActive = false
    private(set) var endDate: Date?
    var onChange: (() -> Void)?

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
        }
        onChange?()
    }

    func deactivate() {
        release()
        onChange?()
    }

    private func release() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        if isActive {
            IOPMAssertionRelease(assertionID)
            isActive = false
        }
    }
}

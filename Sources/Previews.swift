import ScreenCaptureKit

/// Window previews. This is the ONLY file that reads screen content.
/// It is only used when "Show Window Previews" is ticked in the menu.
/// Images stay in memory to be shown in the switcher:
/// nothing is written to disk or sent anywhere.
enum Previews {
    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Opens the macOS Screen Recording permission request.
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// Captures a thumbnail of each requested window, then calls `completion`
    /// on the main thread for each one.
    static func capture(_ ids: [CGWindowID], maxSide: CGFloat,
                        completion: @escaping (CGWindowID, CGImage) -> Void) {
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            else { return }
            for window in content.windows where ids.contains(window.windowID) {
                let scale = 2 * min(1, maxSide / max(window.frame.width, window.frame.height, 1))
                let config = SCStreamConfiguration()
                config.width = max(1, Int(window.frame.width * scale))
                config.height = max(1, Int(window.frame.height * scale))
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: window)
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    completion(window.windowID, image)
                }
            }
        }
    }
}

import AppKit

/// "Even With the Lid Closed": macOS always puts a laptop to sleep when its
/// lid closes (unless an external screen, a keyboard and power are
/// connected), whatever apps ask. Only the administrator setting
/// `pmset disablesleep` prevents it, so Relay asks for the administrator
/// password (macOS' own dialog) and starts a small script as administrator
/// that turns sleep off, then turns it back on as soon as:
///  - the chosen time is up,
///  - Relay asks for it (option unticked, keep awake stopped, Relay quits),
///  - Relay is no longer running.
/// If the Mac gets hot (macOS thermal state "serious" or worse), Relay asks
/// the script to turn sleep back on and put the Mac to sleep at once.
/// The script is fixed text, passed inline (never stored in a file another
/// program could change); it only receives numbers and the path of the file
/// Relay uses to talk to it, whose content it only compares with fixed words.
final class ClosedLid {
    private(set) var isActive = false
    var onChange: () -> Void = {}

    private var timer: Timer?
    private var thermalObserver: NSObjectProtocol?

    /// File Relay writes to talk to the script: "wake" or "sleep".
    private let control: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Relay/lid-control")

    /// Turns sleep off until `end`. Returns false if the password was not given.
    @discardableResult
    func activate(until end: Date) -> Bool {
        guard !isActive else { return true }
        let seconds = Int(end.timeIntervalSinceNow)
        guard seconds > 0 else { return false }
        try? FileManager.default.createDirectory(at: control.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: control)

        let command = "/bin/sh -c " + Self.quote(Self.script) + " relay-lid \(seconds) "
            + Self.quote(control.path) + " \(getpid()) >/dev/null 2>&1 &"
        let source = "do shell script \"" + command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\" with prompt \"" + Self.prompt + "\" with administrator privileges"
        var error: NSDictionary?
        NSApp.activate()
        guard let script = NSAppleScript(source: source) else { return false }
        _ = script.executeAndReturnError(&error)
        guard error == nil else { return false }   // password not given
        isActive = true
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.check() }
        onChange()
        return true
    }

    /// Turns sleep back on.
    func deactivate() {
        guard isActive else { return }
        send("wake")
        stop()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        isActive = false
        onChange()
    }

    private func send(_ word: String) {
        try? word.write(to: control, atomically: true, encoding: .utf8)
    }

    private func check() {
        guard isActive else { return }
        // Too hot: sleep now.
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            send("sleep")
            stop()
            return
        }
    }

    /// For the shell: between single quotes.
    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Text of macOS' password dialog, instead of its vague default.
    private static let prompt = "Relay needs your administrator password to keep the Mac awake with the lid closed. "
        + "It turns off sleep (pmset disablesleep) until the time you chose is up, then turns it back on."

    /// Run as administrator. $1: seconds, $2: control file, $3: Relay's process.
    private static let script = """
        end=$(( $(date +%s) + $1 )); ctl="$2"; pid="$3"
        pmset -a disablesleep 1
        while :; do
          sleep 3
          [ "$(date +%s)" -ge "$end" ] && break
          kill -0 "$pid" 2>/dev/null || break
          if [ -f "$ctl" ]; then
            word=$(head -c 8 "$ctl"); rm -f "$ctl"
            if [ "$word" = "sleep" ]; then pmset -a disablesleep 0; pmset sleepnow; exit 0; fi
            break
          fi
        done
        pmset -a disablesleep 0
        """
}

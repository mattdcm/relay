import AppKit

/// Checks once a week whether a new version of Relay is published on
/// GitHub. This is the ONLY file that uses the network.
/// A single read-only request: GitHub's public API returns the number of the
/// latest published version. Nothing is sent apart from the request itself
/// (GitHub sees the IP address, as for any web page), no cookie is kept,
/// and Relay itself downloads nothing: it shows a dot on its icon and menu
/// items to read about the new version or install it. Installing opens a
/// script in Terminal that downloads the source of that version from GitHub
/// and runs build.sh, so the user sees every step and types the keychain
/// password there.
/// Can be turned off in the menu ("Check for Updates Weekly").
final class Updates {
    /// The project's GitHub repository, as "owner/name".
    static let repository = "mattdcm/relay"

    var onChange: () -> Void = {}
    /// Latest published version, if it is newer than this one.
    private(set) var available: (version: String, tag: String, page: URL)?

    /// The menu-bar dot only announces a version until you next open the menu:
    /// installing it is up to you, and the dot does not come back for it.
    var showsDot: Bool { available.map { $0.version != seenVersion } ?? false }

    /// Called when the menu opens.
    func markSeen() {
        guard let available, available.version != seenVersion else { return }
        seenVersion = available.version
    }

    private var seenVersion: String? {
        get { UserDefaults.standard.string(forKey: "seenUpdate") }
        set { UserDefaults.standard.set(newValue, forKey: "seenUpdate") }
    }

    private let interval: TimeInterval = 7 * 24 * 3600
    private var timer: Timer?

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkUpdates"); schedule() }
    }

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks at launch whether the last check is more than a week old, then
    /// every hour (the Mac can stay on for weeks).
    func schedule() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    private func checkIfDue() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < interval { return }
        check()
    }

    func check() {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")
        else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Relay/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        // Ephemeral session: no cookie, no disk cache.
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { [weak self] data, response, _ in
            defer { session.finishTasksAndInvalidate() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let release = try? JSONDecoder().decode(Release.self, from: data)
            else { return }
            DispatchQueue.main.async { self?.handle(release) }
        }.resume()
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    private func handle(_ release: Release) {
        lastCheck = Date()
        let tag = release.tag_name
        // The tag ends up in the install script: only accept plain version numbers.
        guard tag.range(of: #"^v?[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#, options: .regularExpression) != nil else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // Never open a link that does not lead to the project's GitHub page.
        let page = release.html_url
        guard page.scheme == "https", page.host == "github.com",
              page.path.lowercased().hasPrefix("/\(Self.repository.lowercased())/")
        else { return }
        available = Self.isNewer(version, than: Self.currentVersion) ? (version, tag, page) : nil
        onChange()
    }

    /// Opens in Terminal a script that downloads the new version's source and
    /// builds it. build.sh then replaces and relaunches Relay.
    func install() {
        guard let update = available else { return }
        let folder = "$HOME/Library/Application Support/Relay/Source/\(update.tag)"
        let archive = "https://github.com/\(Self.repository)/archive/refs/tags/\(update.tag).tar.gz"
        let script = """
            #!/bin/sh
            # Opened by Relay's "Install Update" menu item.
            set -eu
            PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
            clear
            echo "Updating Relay to \(update.version)."
            echo "Downloading the source from github.com/\(Self.repository)…"
            DEST="\(folder)"
            rm -rf "$DEST"
            mkdir -p "$DEST"
            # Downloaded to a file first, so a failed download stops here.
            curl -fsSL -o "$DEST.tar.gz" "\(archive)"
            tar -xzf "$DEST.tar.gz" -C "$DEST" --strip-components 1
            rm -f "$DEST.tar.gz"
            echo "Source saved in $DEST"
            cd "$DEST"
            sh build.sh
            echo ""
            echo "Relay \(update.version) is installed. You can close this window."

            """
        // A new folder only Relay's user can open, and a file private from
        // the start: no other program can swap the script before it runs.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Relay Update \(UUID().uuidString)")
        let url = dir.appendingPathComponent("Relay Update.command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8),
                                                 attributes: [.posixPermissions: 0o700]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            NSWorkspace.shared.open(url)
        } catch {
            NSWorkspace.shared.open(update.page)
        }
    }

    /// Compares two version numbers such as "1.2.10" and "1.2.9".
    static func isNewer(_ version: String, than current: String) -> Bool {
        let parts = { (v: String) in v.split(separator: ".").map { Int($0) ?? 0 } }
        let (a, b) = (parts(version), parts(current))
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        return false
    }
}

import AppKit

/// A window placed in a zone: its app and, for one specific window, its title.
/// An empty title stands for every window of the app.
struct WindowRef: Codable, Equatable {
    var app: String                  // app identifier (e.g. com.apple.Safari)
    var title: String

    /// Readable name, for the editor.
    var label: String { title.isEmpty ? appName(app) : "\(appName(app)) – \(title)" }

    /// Window title (or app name) cut after 10 characters, for the zones.
    var shortLabel: String {
        let name = title.isEmpty ? appName(app) : title
        return name.count > 10 ? String(name.prefix(10)) + "..." : name
    }
}

/// A zone of the screen: a rectangle in fractions of the screen (0 to 1,
/// origin at the top left) and the windows placed in it.
/// The zones of a screen do not overlap and cover it entirely.
final class Zone: Codable {
    var rect: CGRect
    var windows: [WindowRef]

    init(rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), windows: [WindowRef] = []) {
        self.rect = rect
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey { case rect, windows, apps }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rect = try values.decode(CGRect.self, forKey: .rect)
        if let windows = try values.decodeIfPresent([WindowRef].self, forKey: .windows) {
            self.windows = windows
        } else {
            // Earlier unreleased builds stored whole apps.
            let apps = try values.decodeIfPresent([String].self, forKey: .apps) ?? []
            windows = apps.map { WindowRef(app: $0, title: "") }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(rect, forKey: .rect)
        try values.encode(windows, forKey: .windows)
    }

    /// The zone in real coordinates, inside the `screen` rectangle.
    func frame(in screen: CGRect) -> CGRect {
        CGRect(x: screen.minX + rect.minX * screen.width, y: screen.minY + rect.minY * screen.height,
               width: rect.width * screen.width, height: rect.height * screen.height)
    }

    /// Sorts zones in reading order: row by row from the top, and from left to
    /// right within a row.
    static func sorted(_ zones: [Zone]) -> [Zone] {
        zones.sorted { a, b in
            if abs(a.rect.minY - b.rect.minY) > 0.001 { return a.rect.minY < b.rect.minY }
            return a.rect.minX < b.rect.minX
        }
    }

    /// Deep copy, so that "Cancel" in the editor changes nothing.
    static func copy(_ zones: [Zone]) -> [Zone] { zones.map { Zone(rect: $0.rect, windows: $0.windows) } }
}

/// Old format (unreleased versions): a tree of zones cut in two.
/// Only read, to convert layouts that are already saved.
private final class TreeZone: Decodable {
    var apps: [String] = []
    var split: Split?

    struct Split: Decodable {
        var vertical: Bool
        var ratio: Double
        var first: TreeZone
        var second: TreeZone
    }

    func flatten(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [Zone] {
        guard let split else { return [Zone(rect: rect, windows: apps.map { WindowRef(app: $0, title: "") })] }
        let (first, second) = rect.divided(atDistance: (split.vertical ? rect.width : rect.height) * split.ratio,
                                           from: split.vertical ? .minXEdge : .minYEdge)
        return split.first.flatten(in: first) + split.second.flatten(in: second)
    }
}

/// A named layout, specific to a screen setup.
struct Layout: Codable {
    var id = UUID()
    var name: String
    var setup: String                    // screen setup (see Displays.setupKey)
    var screens: [String: [Zone]]        // zones of each screen, by screen identifier
    var screenNames: [String: String]    // for the editor, even when the screen is unplugged
    var screenSizes: [String: CGSize]

    init(name: String, setup: String, screens: [String: [Zone]],
         screenNames: [String: String], screenSizes: [String: CGSize]) {
        self.name = Layout.cleanName(name)
        self.setup = setup
        self.screens = screens
        self.screenNames = screenNames
        self.screenSizes = screenSizes
    }

    private enum CodingKeys: String, CodingKey { case id, name, setup, screens, screenNames, screenSizes }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        // The file can be edited by hand: the name is cleaned as when typed.
        name = Layout.cleanName(try values.decode(String.self, forKey: .name))
        setup = try values.decode(String.self, forKey: .setup)
        screenNames = try values.decode([String: String].self, forKey: .screenNames)
        screenSizes = try values.decode([String: CGSize].self, forKey: .screenSizes)
        if let zones = try? values.decode([String: [Zone]].self, forKey: .screens) {
            screens = zones.mapValues(Zone.sorted)
        } else {
            screens = try values.decode([String: TreeZone].self, forKey: .screens).mapValues { Zone.sorted($0.flatten()) }
        }
    }
}

extension Layout {
    static let maxNameLength = 30

    /// A layout name as stored and shown: plain text on one line, at most 30
    /// characters. Names are only ever shown as text and saved as JSON
    /// strings, never run or interpreted, so they cannot inject code.
    static func cleanName(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return String(text.prefix(maxNameLength))
    }
}

/// Text fields for layout names: refuses typing beyond 30 characters.
final class LayoutNameFormatter: Formatter {
    override func string(for object: Any?) -> String? { object as? String }

    override func getObjectValue(_ object: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        object?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partial: String, newEditingString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        partial.count <= Layout.maxNameLength && !partial.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
    }
}

/// A connected screen.
struct Display {
    let id: String       // stable identifier provided by macOS
    let name: String
    let number: CGDirectDisplayID   // changes from one session to the next
    let frame: CGRect    // usable area (without menu bar or Dock), origin at the top left
}

enum Displays {
    static func current() -> [Display] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
            else { return nil }
            let visible = screen.visibleFrame
            return Display(id: (CFUUIDCreateString(nil, uuid) as String?) ?? "", name: screen.localizedName, number: number,
                           frame: CGRect(x: visible.minX, y: primaryHeight - visible.maxY,
                                         width: visible.width, height: visible.height))
        }
    }

    /// Identifies a setup: the set of connected screens.
    static func setupKey(_ displays: [Display] = current()) -> String {
        displays.map(\.id).sorted().joined(separator: "+")
    }

    /// Places the screens next to each other in this order, from left to
    /// right (or top to bottom), as System Settings > Displays > Arrange does.
    /// Side by side, their bottoms are aligned; stacked, they are centered.
    /// Only done when the user moves a screen in the layout editor.
    /// Returns false when nothing changed.
    @discardableResult
    static func arrange(_ order: [String], horizontal: Bool) -> Bool {
        let displays = current()
        let numbers: [CGDirectDisplayID] = order.compactMap { id in displays.first { $0.id == id }?.number }
        guard numbers.count == displays.count, numbers.count > 1,
              let main = numbers.firstIndex(of: CGMainDisplayID())
        else { return false }
        let sizes: [CGSize] = numbers.map { CGDisplayBounds($0).size }
        let maxWidth: CGFloat = sizes.map(\.width).max() ?? 0
        let maxHeight: CGFloat = sizes.map(\.height).max() ?? 0
        var origins: [CGPoint] = []
        var cursor: CGFloat = 0
        for size in sizes {
            if horizontal {
                origins.append(CGPoint(x: cursor, y: maxHeight - size.height))
                cursor += size.width
            } else {
                origins.append(CGPoint(x: ((maxWidth - size.width) / 2).rounded(), y: cursor))
                cursor += size.height
            }
        }
        // The main screen (the one with the menu bar) stays at the origin.
        let shift: CGPoint = origins[main]
        let wanted: [CGPoint] = origins.map { CGPoint(x: $0.x - shift.x, y: $0.y - shift.y) }
        var unchanged = true
        for (number, origin) in zip(numbers, wanted) where CGDisplayBounds(number).origin != origin { unchanged = false }
        if unchanged { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for (number, origin) in zip(numbers, wanted) {
            CGConfigureDisplayOrigin(config, number, Int32(origin.x), Int32(origin.y))
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    /// Converts a "top-left origin" rectangle to AppKit coordinates.
    static func cocoaRect(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Readable name of an app from its identifier.
func appName(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

/// Saves layouts in a readable text file:
/// ~/Library/Application Support/Relay/layouts.json
final class LayoutStore {
    private struct Saved: Codable {
        var layouts: [Layout] = []
        var lastApplied: [String: UUID] = [:]   // last applied layout, per setup
        var autoApply = true
    }

    private var saved = Saved()
    private let url: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Relay")
        // The app used to be called "Relais": take over its folder if it exists.
        try? FileManager.default.moveItem(at: support.appendingPathComponent("Relais"), to: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("layouts.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
        }
    }

    var autoApply: Bool {
        get { saved.autoApply }
        set { saved.autoApply = newValue; write() }
    }

    func layouts(for setup: String) -> [Layout] { saved.layouts.filter { $0.setup == setup } }
    func layouts(notFor setup: String) -> [Layout] { saved.layouts.filter { $0.setup != setup } }

    func lastApplied(for setup: String) -> Layout? {
        saved.layouts.first { $0.id == saved.lastApplied[setup] }
    }

    func markApplied(_ layout: Layout) {
        saved.lastApplied[layout.setup] = layout.id
        write()
    }

    func save(_ layout: Layout) {
        if let index = saved.layouts.firstIndex(where: { $0.id == layout.id }) {
            saved.layouts[index] = layout
        } else {
            saved.layouts.append(layout)
        }
        write()
    }

    func delete(_ layout: Layout) {
        saved.layouts.removeAll { $0.id == layout.id }
        write()
    }

    /// New layout for the connected screens: a single zone per screen.
    func makeLayout(named name: String) -> Layout {
        let displays = Displays.current()
        return Layout(name: name, setup: Displays.setupKey(displays),
                      screens: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, [Zone()]) }),
                      screenNames: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.name) }),
                      screenSizes: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.frame.size) }))
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(saved).write(to: url, options: .atomic)
    }
}

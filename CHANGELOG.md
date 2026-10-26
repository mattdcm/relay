# Changelog

All notable changes to Relay are listed here. Versions follow [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`. Each version is published as a GitHub release tagged `vX.Y.Z`; Relay compares that tag with its own version to tell you an update is available.

## [Unreleased]

## [1.2.1] - 2026-10-26

### Fixed

- ⌘⇥ now lists windows in the order you used them. Before, after switching to an app with several windows, the next suggestion was that app's other window instead of the window you came from, because macOS raises all the windows of an app when it comes to the front.

## [1.2.0] - 2026-10-26

### Added

- "Large Screen Accessibility…" in the menu: a window with the screens on the left and, on the right, every resolution macOS reports for the selected screen (including those System Settings hides), with how big text looks in each (for example "text 133 %"). A resolution is applied at once; a panel asks "Keep these display settings?" and, without an answer within 10 seconds, the previous setting comes back. Uses only Apple's public display API, so it cannot create resolutions the screen and the Mac do not offer.

- In the layout editor, hovering the line between two zones shows a ⇄ button near its top (or left) end: a click swaps the windows of the two zones. The rest of the line can still be dragged to resize.

- Keep Awake: "Even With the Lid Closed", available with a time limit (not indefinitely). macOS only allows this through an administrator setting (`pmset disablesleep`), so Relay asks for the administrator password in macOS' own dialog, with a message explaining why, and starts a small script, passed inline, that turns sleep back on when the time is up, when the option is unticked, or when Relay quits. Opening and closing the lid again during that time keeps the mode on. If the Mac gets hot (macOS thermal state "serious" or worse), it goes to sleep at once. Ticking the option shows a warning (ventilation, heat, use at your own risk) and asks for confirmation each time.

- Keep Awake: a battery limit, on Macs with a battery. In the "Prevent Sleep" list, "Or Until the Battery Reaches" offers No Battery Limit, 50 %, 30 %, 20 % or 10 % (the current charge is shown). On battery power, Relay stops preventing sleep, and turns off "Even With the Lid Closed", as soon as the charge falls to that level, or when the time is up, whichever comes first. The choice is kept between launches. The charge is read from macOS' public power information, with no permission or administrator password.

### Changed

- "Prevent Sleep" and "For…" are now one menu item. It opens a list: Indefinitely, the usual durations, "Custom Time…" (hours and minutes) and, once on, "Stop Preventing Sleep". The last two custom times are remembered and appear in the list, in order between the usual durations. While on, the item shows the time left (for example "Prevent Sleep (1 h 23 min left)").
- "Move Pointer to the Chosen Window" puts the pointer in the middle of the window horizontally and 5% above its bottom edge, where the next action usually is, instead of its center.
- When dragging a window, the drop area in the middle of each zone (dashed outline) is now a quarter of the zone's area instead of half, so a window is fitted to a zone only when you really aim for it.
- Zones now have a minimum size in points (320 × 200) instead of 5 % of the screen, so they stay usable on a small screen such as a laptop's. This applies when splitting a zone, dragging a line in the layout editor, and resizing a window that sits in a zone. The minimum never goes above 45 % of the screen, and a zone that is already smaller can grow but not shrink.

## [1.1.0] - 2026-10-24

### Added

- Zone mode: during ⌘⇥, keep holding ⌘ and use the arrow keys to move the selected window from zone to zone (on any screen), live, with the zones shown on screen. Release ⌘ to keep it, Esc to put it back. Press ⇥ (still holding ⌘) to keep it and pick another window to place.
- The ⌘⇥ switcher shows, under the windows, the keys to place a window in a zone (⌘ and the four arrow keys) next to the keys to pick another window (⌘ ⇥), drawn as keycaps.
- Left of these keys, a map of all the screens shows the numbered zones of the current layout, with the name of the monitor the selected window is on ("Window position in monitor …"), and highlights the zone that window is in while you move through the list. A small screen keeps a readable size next to a big one.
- Option "Move Pointer to the Chosen Window" (off by default): after a switch, the pointer goes to the center of the chosen window.

### Changed

- The layout editor shows all the screens of the setup side by side, arranged as they are on the desk and at the same scale (a big monitor looks bigger than the laptop screen, while a small screen keeps a minimum size and a big one a maximum size, so that both stay easy to edit), each with its name. Windows can be dropped onto a zone of any screen directly (the screen menu is gone).
- In the layout editor, drag a screen by its name to the side of another one: on Save, macOS arranges the screens that way (as in System Settings > Displays > Arrange), then the windows are placed. Side by side, screens are aligned at the bottom; stacked, they are centered.
- With previews turned on, the editor's window list shows each window's thumbnail, with its icon and title on top. Windows not placed yet are listed first.
- In the layout editor, hovering a window name inside a zone shows a ✕ that takes the window out of that zone.
- "Delete Zone" in the layout editor: the zone with the previous number (or the nearest one that fits) grows over the deleted zone and takes its windows.
- With several screens, a ⇅ button at the top right of each screen in the editor swaps its zones and windows with another screen (a menu picks the screen when there are more than two).
- The layout editor window can be resized; the screens grow with it.
- App icon: a coffee cup.
- While the green-button strip is shown, typing a zone number moves the window there (with 10 zones or more, Relay waits a moment for a second digit).

### Changed

- Resizing a window that fills a zone resizes the zone: the lines it shares with neighbouring zones move, the windows in those zones follow live while the mouse moves, and the layout is saved when the button is released. Can be turned off in the menu ("Resizing a Window Resizes Its Zone").
- Dragging a window by its title bar shows the zones (no need to hold ⇧ anymore). Dropping it over the central half of a zone (dashed outline) fits it to the zone; dropping it anywhere else just moves it, as usual. Can be turned off in the menu ("Dragging a Window Suggests the Layout Zones").
- During ⌘⇥, the arrow keys now move the selected window from zone to zone; ⇥ and ⇧⇥ move through the list.
- During ⌘⇥, typing a zone number (⌘ still held) moves the selected window straight to that zone of its screen.
- Spotlight (⌘Space) also finds Relay with words such as coffee, awake, window, screen, monitor or zones.

### Security

- Layout names are limited to 30 characters of plain text on one line (control characters are removed, also when the layouts file is edited by hand). They are only shown as text and saved as JSON strings, never run or passed to a shell.

## [1.0.0] - 2026-10-24

First public version.

### Window switcher

- Hold ⌘ and press ⇥ to cycle through windows, release ⌘ to switch. Replaces the macOS app switcher.
- ⇧⇥ or ← go back, → goes forward, Esc cancels, a click picks a window.
- The first press selects the previous window.
- ⇥ only cycles through recently used apps (5 min to 24 h, or no limit, set in the menu). It always covers at least the current app and the previous one. Other windows are shown dimmed and can be picked with the mouse.
- Shows windows of the current Space, plus minimized windows and windows of hidden apps.
- Optional window previews (off by default, needs Screen Recording). Without them, the switcher shows the app icon and the window title.

### Keep awake

- Prevent display and system sleep indefinitely, or for 15 min, 1 h, 2 h or 5 h.
- Uses the official macOS power assertion. The menu-bar cup fills while active.

### Productive Windows

- Named layouts that split each screen into zones, with windows placed in each zone.
- Zone editor: split any zone left | right or top / bottom, drag lines to resize, merge zones, drag open windows from a list onto zones (one zone per window; placed windows stay listed, dimmed, with their zone number, and can be removed) (window names in zones are cut after 10 characters). Apps that are not open are launched when the layout is applied.
- Zones are numbered in reading order, the same in the editor and in the green-button strip.
- Saving a layout moves the windows into place right away.
- Multiple selection in the editor (⇧-click or ⌘-click): merge several zones at once, cut them with one common line, drag the line they share in one move.
- Applying a layout opens its apps if needed and moves their windows into their zones (windows are matched by app and title).
- Layouts belong to a screen setup. When a screen is plugged in or unplugged, Relay reapplies the last layout used with the new setup (can be turned off).
- ⌃⌥1 to ⌃⌥9 apply the layouts of the current setup.
- Hold ⇧ while dragging a window by its title bar to show the zones and drop it into one.
- Rest the pointer on a window's green button to show a strip titled "Your current Relay layout" with the layout's numbered zones, below Apple's menu (or to its right, or above the button, when space is short); a click moves the window into that zone (halves, thirds and full screen when no layout exists for the current screens). Apple's own green-button menu is left untouched (can be turned off).
- Layouts are saved in a readable file: `~/Library/Application Support/Relay/layouts.json`.

### General

- Menu-bar only (no Dock icon), English interface. The layout editor appears in the ⌘⇥ switcher like any other window.
- Open at Login option.
- "Support Relay" menu item (€ icon), which opens the developer's donation page in the browser.
- Weekly update check against this project's GitHub releases (can be turned off). When a new version is out, a red dot appears on the menu-bar icon, with "Install Update…" and "What's New…" in the menu. Installing opens a script in Terminal that downloads that version's source from GitHub and runs build.sh; Relay itself never downloads anything in the background.
- build.sh explains why it asks for a password, suggests a memorable one or a password manager, and reminds that typing is invisible in Terminal.
- Built from source with `sh build.sh`, using only Apple's command-line tools. No dependencies.

### Security

- **Hardened runtime.** Relay is signed with `--options runtime`, so macOS refuses to load injected code into it (`DYLD_INSERT_LIBRARIES`, unsigned libraries). Another app cannot run its own code inside Relay to borrow its permissions.
- **Signing key protected by a password.** The self-signed "Relais Local" key lives in a dedicated keychain (`relay-signing.keychain-db`), locked with its own password. It is unlocked only while `build.sh` signs, then locked again (and automatically after 5 minutes or on sleep). Other programs cannot sign themselves as Relay and silently inherit its Accessibility and Screen Recording permissions. Earlier unreleased builds kept the key in the login keychain, usable without a password; `build.sh` deletes that old key.
- **Certificate limited to code signing.** The certificate is not a trusted root (CA:false, code-signing usage only), so it cannot be used to impersonate websites or intercept traffic.
- **Minimal network use.** The update check is the only network code (`Sources/Updates.swift`): one read-only request to the GitHub API per week, ephemeral session (no cookies, no disk cache), no data sent, and only links to this project's github.com page are opened. The release tag is accepted only if it is a plain version number, since it is used in the install script.
- **No other entry points.** No URL scheme, XPC service, AppleScript dictionary or document types. Other apps cannot ask Relay to do anything.
- **Keyboard and mouse.** The ⌘⇥ interception only reads key codes and modifier keys and records nothing. The snap feature only listens to mouse clicks and drags. macOS disables both while you type a password.
- **Screen content.** Only `Sources/Previews.swift` reads the screen, only when previews are on. Thumbnails stay in memory and are never written to disk or sent anywhere.
- **No usage history.** When apps were last used is kept in memory only and forgotten when Relay quits.

[1.2.1]: https://github.com/mattdcm/relay/releases/tag/v1.2.1
[1.2.0]: https://github.com/mattdcm/relay/releases/tag/v1.2.0
[1.1.0]: https://github.com/mattdcm/relay/releases/tag/v1.1.0
[1.0.0]: https://github.com/mattdcm/relay/releases/tag/v1.0.0

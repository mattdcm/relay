# Relay

A small macOS menu-bar app that combines:

- **A window switcher**: hold ⌘ (Command) and press ⇥ (Tab) to cycle through windows, then release ⌘ to switch. It replaces the macOS app switcher. ⇧⇥ goes back, Esc cancels, and a click picks a window. Tab only cycles through recently used apps (the delay is set in the menu, from 5 min to 24 h, or no limit). Tab always covers at least the current app and the previous one. Other windows are still shown, dimmed, and can be picked with the mouse. While the switcher is open, keep holding ⌘ and press the arrow keys: the zones of the current layout appear on every screen and the selected window jumps from zone to zone in that direction, live. Release ⌘ to keep it there, or press Esc to put it back where it was.
- **Keep awake**: from the cup icon, prevent sleep, indefinitely or for 15 min, 1 h, 2 h or 5 h.
- **Productive windows**: named layouts that split each screen into zones and place windows in each zone. Applying a layout opens the apps if needed and moves their windows into place. Each layout belongs to a screen setup (which screens are connected); when you plug or unplug a screen, Relay reapplies the last layout used with the new setup. Drag a window by its title bar to see the zones: drop it over the central half of a zone (dashed outline) to fit it there, or anywhere else to just move it. You can also rest the pointer on a window's green button: a strip titled "Your current Relay layout" appears below Apple's menu (or to its right, or above the button, when space is short), and a click moves the window into that zone. Without a layout for the current screens, the strip offers halves, thirds and full screen. ⌃⌥1 to ⌃⌥9 apply the layouts of the current setup.

No ads, no account, no tracking. The only network access is a weekly update check against this project's GitHub releases, which you can turn off. About 1,700 lines of Swift, no dependencies.

See [CHANGELOG.md](CHANGELOG.md) for the features and security measures of each version.

## Build and install

You need macOS 14 (Sonoma) or later and Apple's command-line tools (full Xcode is not required):

```sh
xcode-select --install     # once, installs Apple's command-line tools (and git)
git clone https://github.com/mattdcm/relay.git
cd relay
sh build.sh
```

Without git, you can instead download the source archive of the latest release from the [Releases](https://github.com/mattdcm/relay/releases) page, unzip it, open Terminal in that folder and run `sh build.sh`.

`build.sh` compiles, signs, installs to /Applications and launches Relay. Use the same command for every update.

The first time, it explains why and asks you to choose a password for a small keychain that holds Relay's signing key (see below). Pick one you can remember, or save it in your password manager. After that, it asks for that password once each time you build or update. Nothing is displayed while you type a password in Terminal: type it and press Enter.

If you lose the password, delete `~/Library/Keychains/relay-signing.keychain-db` and run `sh build.sh` again: a new key is created, and macOS asks for Relay's permissions again.

## Updates

Once a week, Relay asks the GitHub API for the latest release of this project. When it is newer than the running version, a small red dot appears on the menu-bar cup, and the menu shows:

- **Install Update…** opens a script in Terminal that downloads the source of that version from GitHub (into `~/Library/Application Support/Relay/Source/`) and runs `sh build.sh`. You type your keychain password, and Relay is replaced and relaunched with your permissions and layouts intact.
- **What's New…** opens the release page.

Relay itself never downloads or installs anything in the background: everything happens in the Terminal window, in front of you. You can also update by hand: get the new source (`git pull` or the release archive) and run `sh build.sh`. Untick "Check for Updates Weekly" in the menu to turn the check off.

If you fork Relay, set your own repository in `Sources/Updates.swift` (the `repository` constant).

## Permissions

| Permission | Why | Required? |
|---|---|---|
| Accessibility | Intercept ⌘⇥, list windows and bring the right one to the front | Yes, for the switcher |
| Screen Recording | Show a thumbnail of each window | **No.** Only if you tick "Show Window Previews" (off by default). Without it, the switcher shows the app icon and the window title |

Sleep prevention needs no permission.

The bundle identifier (`local.relais`) and the certificate name keep the app's former name, Relais, so that existing permissions and settings carry over.

The first time it runs, `build.sh` creates a self-signed code-signing certificate named "Relais Local" in a dedicated keychain, `~/Library/Keychains/relay-signing.keychain-db`, protected by the password you choose. It never leaves your Mac and is only used to sign Relay. macOS ties permissions to that signature, so they stay valid after every rebuild. Because the keychain stays locked except while `build.sh` signs, no other program can sign itself as Relay and inherit its permissions. Relay is also signed with the hardened runtime, which stops other programs from injecting code into it.

If Relay does not detect a permission that is ticked in System Settings, quit Relay, then run:

```sh
tccutil reset Accessibility local.relais
tccutil reset ScreenCapture local.relais
open /Applications/Relay.app
```

## Audit

Each file does one thing:

| File | Role | Reads the screen? |
|---|---|---|
| `Sources/main.swift` | Menu-bar icon and menu | No |
| `Sources/KeepAwake.swift` | Sleep prevention (`IOPMAssertionCreateWithName`, the official macOS power assertion) | No |
| `Sources/Hotkey.swift` | Detects ⌘⇥. Only looks at the key code and modifier keys, records nothing | No |
| `Sources/Activity.swift` | Remembers, in memory only, when each app was last in front | No |
| `Sources/WindowList.swift` | Lists and activates windows (Accessibility API) | No |
| `Sources/Switcher.swift` | Draws the switcher | No |
| `Sources/Layouts.swift` | Zones, layouts, screen setups, and saving them to `~/Library/Application Support/Relay/layouts.json` | No |
| `Sources/Arranger.swift` | Applies a layout: opens apps and moves their windows (Accessibility API) | No |
| `Sources/ZoneEditor.swift` | The layout editor window | No |
| `Sources/ZoneMover.swift` | Arrows during ⌘⇥: moves the selected window from zone to zone (Accessibility API) | No |
| `Sources/Snapper.swift` | Drag a window by its title bar to snap it into a zone. Only watches mouse clicks and drags, never blocks them | No |
| `Sources/ZoneResizer.swift` | A window resized by hand in a zone moves the zone's lines and the neighbouring windows (Accessibility API) | No |
| `Sources/ZoomHover.swift` | Zone strip next to the green button. Reads the pointer position and, via Accessibility, which button is under it | No |
| `Sources/Updates.swift` | Weekly update check: one read-only request to the GitHub API. **The only network code** | No |
| `Sources/Previews.swift` | Thumbnails (ScreenCaptureKit), kept in memory while Relay runs, never written to disk | **Yes, and it is the only one**, when previews are on |

Code comments are in English.

Quick checks:

```sh
# Network code (expected: only Sources/Updates.swift):
grep -nE "URLSession|Network|NWConnection|socket|http" Sources/*.swift

# Hardened runtime (expected: flags=0x10000(runtime)):
codesign -dv /Applications/Relay.app 2>&1 | grep flags

# What reads the screen:
grep -n "ScreenCaptureKit\|SCScreenshot" Sources/*.swift

# Check sleep prevention while it is on:
pmset -g assertions | grep Relay
```

For extra assurance, an outbound firewall can limit Relay to `api.github.com`, or block it entirely (the update check then simply fails).

## Editing a layout

In the cup menu, choose **New Layout…** or, on an existing layout, **Edit Zones…**. Click a zone to select it. ⇧-click (or ⌘-click) adds or removes zones from the selection. Then:

- **Split Left | Right** or **Split Top / Bottom** cuts the selected zone in two. With several selected zones that form a rectangle, one common line crosses them all; otherwise each is cut in its middle. Only selected zones are cut, so a line does not have to cross the whole screen.
- Drag a line to resize the zones on each side. By default, only the part of the line next to the pointer moves (plus whatever zones it must take along so zones stay joined). If the zones along the line are selected, the line moves for all of them at once.
- **Merge** joins the selected zones into one, when together they form a rectangle.
- Zones are numbered in reading order: row by row from the top, left to right.
- To the right of the screen, the list shows every open window, in two columns. **Drag a window onto a zone** to place it there. Placed windows stay in the list, dimmed, with their zone number; drag one onto another zone to move it (a window belongs to one zone at most), or click its ✕ to remove it from its zone. Windows can also stay unplaced.
- Several windows in one zone are stacked, and ⌘⇥ switches between them. In each zone, window names are cut after 10 characters.
- **Remove Windows** empties the selected zones.

Windows are recognized by their app and title. If a title has changed since (a browser tab, for example), Relay uses another window of the same app. If the app is not open, applying the layout opens it.

With several screens, pick the screen at the top right. **Save** stores the layout and moves the windows into place right away.

## Known limitations

- An app counts as "used" while it is in front, that is, while it receives the keyboard and clicks. Scrolling a background window without clicking it does not count. Right after Relay starts, only the app in front counts as recent.
- The switcher shows the windows of the current Space, plus minimized windows and windows of hidden apps.
- The shortcut is fixed (⌘⇥). To go back to ⌥⇥, replace `.maskCommand` with `.maskAlternate` in `Hotkey.swift` (the `modifier` constant).
- Previews of minimized or hidden windows are the ones captured the last time they were visible while Relay was running. They are kept in memory only and are cleared when Relay quits.
- macOS 15 and later periodically asks you to confirm Screen Recording access when previews are on. This is by design.
- Shortcuts do not work while you are typing a password (a macOS protection).
- Some apps have a minimum window size or refuse to be resized, so they may not fill their zone exactly. Full-screen windows and other Spaces are not arranged.
- When a layout opens an app, Relay waits up to 10 seconds for its first window.

## Support

Relay is free. If it is useful to you, you can support its development at [revolut.me/matthi9uf](https://revolut.me/matthi9uf) (also available from the "Support Relay" menu item). This only opens the link in your browser; Relay sends nothing.

## License

Copyright (C) 2026 Matthias Da Cunha Martins.

Relay is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY. See [LICENSE](LICENSE) for the full text.

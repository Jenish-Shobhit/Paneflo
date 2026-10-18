# Paneflo

Every window. In its place.

Paneflo is a native macOS menu-bar app for finding, arranging and switching between individual windows. It has three modules that share one list of your windows: a ⌘Tab that lists windows instead of apps, keyboard tiling, and an organized Overview that keeps windows in slots you control. The Overview is Paneflo's own panel; it does not modify Apple's Mission Control or control native Spaces.

Requires macOS 26 or later on Apple silicon. Free and open source under the [MIT License](LICENSE). Current state and limits: [docs/status.md](docs/status.md).

## Features

- **Switcher.** Hold ⌘ and press Tab (Shift–Tab goes back). Arrow keys also choose while ⌘ is held. Release ⌘ to focus, Escape to cancel.
- **Tiling in the picker.** ⌘⌥ with the arrows: Left/Right for a half, Up to fill the display, Down to undo. Repeating a half moves the window to the next display.
- **Tiling anywhere.** ⌃⌥ with the arrows tiles the focused window, ⌃⌥Return fills its display, ⌃⌥Z undoes.
- **Tile pairs.** Two windows in the left and right (or top and bottom) halves of one display form a pair, marked ▮▮ on their cards. Opening either one from ⌘Tab or the Overview brings its partner forward too (Settings › Tile pairs, on by default). ⌘⌥Return in the picker or Overview always opens the selection with its partner; the Overview's right-click menu has Open pair and Ungroup. In the picker, after ⌘⌥← (or →) the hint asks for the other half: Tab to another window and press ⌘⌥→ (or ←) to place it beside the first on the same display and pair them.
- **Overview.** ⌃⌥Space opens every window in stable slots. Arrows move spatially, search keeps slots in place, Return focuses, Escape closes.
- **Gesture (optional, experimental).** Three-finger swipe up opens the Overview, down closes it.
- **Desktop entry.** A Desktop card at the end of the ⌘Tab loop and a Desktop tile in the Overview reveal the desktop by hiding other apps. Optional in Settings.
- **Previews (optional).** Cached snapshots labelled with their age, and one live preview for the selected window. Each card says Live, Snapshot, Loading, Unavailable or Paused.
- **Window actions while switching.** With ⌘ held, W closes the selected window, M minimizes it, H hides its app and Q quits its app; the picker stays open. Other keys pressed while switching never reach the app behind it. Finder is never quit.

Shortcuts, previews and the gesture are off until you enable them in Settings.

## Install

1. Download `Paneflo-<version>.zip` from [GitHub Releases](https://github.com/Jenish-Shobhit/Paneflo/releases/latest) or the [download page](https://jenish-shobhit.github.io/Paneflo/), unzip it, and move **Paneflo.app** to `/Applications`.
2. Paneflo is not notarized yet. On first open, go to **System Settings › Privacy & Security** and choose **Open Anyway**.
3. **Set up Paneflo** opens by itself while something it needs is missing. For each row, click **Grant…**, switch Paneflo on in the System Settings pane that opens, and come back; the row turns green on its own.
   - **Accessibility** (required): find, focus, move and resize other apps' windows.
   - **Input Monitoring** (required for ⌘Tab, the tiling shortcuts and the gesture).
   - **Screen Recording** (optional): window pictures in the switcher and Overview.
4. If a row says **Restart Paneflo to apply**, click **Restart Paneflo**. macOS often applies Input Monitoring and Screen Recording only after a relaunch. ⌘Tab starts working as soon as the required permissions are on; there is nothing else to turn on.
5. Still off after a restart, or System Settings shows Paneflo switched on but nothing changes? macOS can keep an entry for an older build of Paneflo. Click **Permissions stuck? Reset and grant again**: it clears Paneflo's own entries (no other app's) and walks you through granting them again.
6. For the gesture, turn off the three-finger **Mission Control** and **App Exposé** swipes in **System Settings › Trackpad › More Gestures** (or move them to four fingers). Paneflo does not change them. Then turn on the gesture in Settings.

Settings (menu bar › **Settings…**) shows permission status and groups Shortcuts, Gesture, Previews, Desktop, Updates and Menu bar. **Hide menu bar icon** removes the icon while Paneflo keeps running; open Paneflo again from Finder, Spotlight or Launchpad to get Settings back, where **Show menu bar icon** restores it. **Launch at login** is off by default.

## Updates

Choose **Check for Updates…** in the menu-bar menu. Paneflo also checks once a day unless you turn off **Check for Updates Automatically**, and never while the picker or Overview is showing. A download is verified (size, SHA-256, bundle ID, version, code signature, and the same signing certificate as the running copy) before it replaces the app. Releases are signed with the same certificate so permissions carry over.

## Privacy

Paneflo's only network use is the update check and download from GitHub (`UpdateNetwork.swift` is the only code using `URLSession`). There is no analytics or telemetry. Snapshots stay in memory and are never written to disk or sent anywhere. Slot order and settings are stored locally.

## Build from source

Requires Swift 6.2 or newer with the macOS SDK. No third-party packages.

```sh
./scripts/make-signing-identity.sh   # once: creates the self-signed "Paneflo Dev" certificate
./scripts/build.sh --install --run   # build, sign, replace /Applications/Paneflo.app, open it
./scripts/test.sh                    # Swift Testing suites in PanefloCore
```

`scripts/build.sh [--debug] [--install] [--run] [--zip]`: `--install` quits a running Paneflo and replaces `/Applications/Paneflo.app`; `--run` opens it; `--zip` writes `dist/Paneflo-<version>.zip` (release builds only). Without the "Paneflo Dev" identity the app is signed ad hoc and macOS asks for permissions again after every rebuild. Run the installed copy so permissions persist. `open build/Paneflo.app --args --diagnostics` prints title-free startup phases. In an executor that blocks SwiftPM's manifest sandbox, prefix a script with `PANEFLO_SPM_DISABLE_SANDBOX=1`.

Developer checks live in `Tools/` (own-process fixtures, native UI check, surface and tiling benches, capture-ownership check). They use synthetic windows and measure only Paneflo itself.

## Project

- [Product scope and acceptance criteria](docs/specs/000-product.md)
- [Native architecture and engineering criteria](docs/specs/001-engineering.md)
- [Implementation status and known limits](docs/status.md)
- [Changelog](CHANGELOG.md) and [contributor workflow](AGENTS.md)

Private development material lives under the gitignored `dev_acrtifacts/` and is not part of a checkout.

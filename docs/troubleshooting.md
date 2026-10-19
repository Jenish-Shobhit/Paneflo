# Troubleshooting

If yours isn't here, [open an issue](https://github.com/Jenish-Shobhit/Paneflo/issues/new/choose).

- [Paneflo can't be opened](#paneflo-cant-be-opened)
- [Permissions are on but nothing happens](#permissions-are-on-but-nothing-happens)
- [A shortcut does nothing](#a-shortcut-does-nothing)
- [The three-finger gesture opens Mission Control](#the-three-finger-gesture-opens-mission-control)
- [Cards show icons instead of pictures](#cards-show-icons-instead-of-pictures)
- [A window is missing](#a-window-is-missing)
- [An update didn't install](#an-update-didnt-install)
- [The menu bar icon is gone](#the-menu-bar-icon-is-gone)
- [Reset settings](#reset-settings)
- [Reporting a bug](#reporting-a-bug)

## Paneflo can't be opened

macOS says Paneflo could not be verified, because it is not notarized yet. Click **Done**, open **System Settings › Privacy & Security**, scroll to **Security** and choose **Open Anyway** next to Paneflo. This is needed once per download.

## Permissions are on but nothing happens

1. Open **Settings › Permissions**. A row that says **Restart Paneflo to apply** needs a restart; macOS often applies Input Monitoring and Screen Recording only after a relaunch.
2. Still off, or switched on in System Settings but Paneflo disagrees? macOS can keep an entry for an older build. Click **Permissions stuck? Reset and grant again…**. It clears only Paneflo's own entries (no other app's) and walks you through granting them again.
3. Copies you built yourself are signed ad hoc unless you created the "Paneflo Dev" certificate (`scripts/make-signing-identity.sh`), so macOS asks again after every rebuild. Use the signed identity and run the installed copy.

## A shortcut does nothing

- The menu status line should say ⌘Tab is ready. If it says **Shortcuts paused**, choose **Resume Shortcuts**.
- Another tool that also hooks ⌘Tab or ⌃⌥Space may take it first. Quit it or pause one of them.
- If ⌃⌥Space switches input sources, turn off "Select next source in Input menu" in System Settings › Keyboard › Keyboard Shortcuts › Input Sources.
- If macOS keeps turning off the shortcut tap, Paneflo retries on its own; turning shortcuts off and on retries at once.
- Tiling needs Accessibility. A full-screen window cannot be arranged; Paneflo says so in a short note.

## The three-finger gesture opens Mission Control

macOS still owns that swipe. In System Settings › Trackpad › More Gestures, turn off three-finger **Mission Control** and **App Exposé** (or set them to four fingers). Settings › Overview & Gesture shows whether a conflict remains and opens Trackpad Settings. The gesture uses an unsupported macOS interface, works with the built-in trackpad only, and a system update can break it.

## Cards show icons instead of pictures

Pictures need **Screen Recording** (Settings › Previews). Windows that are minimized, hidden, on another Space, protected, or whose preview is paused show a symbol and may show an older snapshot. Snapshots are kept in memory only, so they are empty after a restart until a window is seen again.

## A window is missing

Windows on other Spaces and full-screen windows are not reliably discovered. Use **Refresh Window List** in the menu. Some apps (utilities, protected windows) do not expose their windows to Accessibility.

## An update didn't install

Paneflo only installs a download whose size, SHA-256, bundle ID, version and signing certificate all match the running copy. A copy signed ad hoc cannot verify updates; download the new `.zip` from [Releases](https://github.com/Jenish-Shobhit/Paneflo/releases/latest) instead. The installer's log is `~/Library/Logs/Paneflo/Update.log`; attach it (after checking it for anything private) to an issue. Paneflo needs write access to the folder it is installed in.

## The menu bar icon is gone

You chose **Hide from Menu Bar**. Paneflo is still running and its shortcuts work. Open Paneflo from Spotlight, Launchpad or Applications; Settings opens on General, where **Show menu bar icon** turns the icon back on. If setup is needed, the icon returns on its own with a badge.

## Reset settings

Quit Paneflo, then in Terminal:

```sh
defaults delete dev.paneflo.Paneflo
```

Overview slot order lives in the same preferences; **Settings › Overview & Gesture › Reset Slot Order…** clears it without leaving the app. To forget permissions, use **Permissions stuck? Reset and grant again…**.

## Reporting a bug

Include your macOS version and Paneflo version (menu bar icon › About Paneflo), the steps, and what you expected. For startup or permission problems, launch with diagnostics and paste the output; it contains phase timings only, no window titles:

```sh
/Applications/Paneflo.app/Contents/MacOS/Paneflo --diagnostics
```

Do not paste real window titles or screenshots of private content.

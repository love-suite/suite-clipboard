# Clipboard: project brief

Clipboard (`local.suite.clipboard`, `LSUIElement`) is Windows' clipboard history (Win+V) for macOS, an
app of Love Suite. It starts at login (its own login item, when on), when it is turned on in Suite
Settings, or from Explorer's Edit menu; its settings are the Clipboard tab of Suite Settings, which reads
and writes them through the `ClipboardSettings` library. While it runs, Spotlight's own clipboard history is
off (`SpotlightGuard`, repository `suite-guard`), and Suite Guard puts it back should Clipboard vanish.

## Architecture

```
ClipboardSettings (library, no UI, the only product other repositories see)
    Clipboard's settings in its own defaults domain, the ignored apps, the history's default size
ClipboardCore     (library, no UI, unit-tested, used by Clipboard only)
    items, classification, de-duplication, limits, filters, storage, iCloud Drive backup, expiry,
    the hold-⌘V gesture
Clipboard         (Clipboard.app) pasteboard watcher, ⌘V event tap, floating panel, pasting;
                  Spotlight's history off while it runs (`SpotlightHistoryManager`, from `SpotlightGuard`)
```

`SuiteCore` (repository `suite-core`) brings what Clipboard shares with the other apps: `ClipboardMessage`,
the distributed notifications between Clipboard, Explorer and Suite Settings, and `ClipboardApp`
(its bundle id and whether it is on, as the other apps see it).

## What Clipboard does today

- Bundle id
  `local.suite.clipboard`, `LSUIElement`, no menu bar icon, no window but its panel): Windows' clipboard
  history (Win+V). It polls
  `NSPasteboard.general`'s change count and keeps text, rich text, links, pictures and files, newest
  first, in `~/Library/Application Support/Explorer/Clipboard` (the 50 latest by default, no pins:
  the user didn't want them). It never records what password managers mark (`org.nspasteboard.ConcealedType`,
  `TransientType` and the others) nor copies made in ignored apps (Keychain Access and Passwords by default). No
  shortcut of its own (the user asked for none): holding ⌘V opens a non-activating panel above and to
  the right of the text caret (else of the text field, at the mouse last), like ⌘Tab: a short ⌘V still pastes, ⌘ kept down and V pressed again goes
  down the list, letting go of ⌘ pastes (`PasteHoldGesture`, driven by an event tap in `HoldToPaste`).
  Explorer's Edit menu opens it too. In the panel: search, arrows, Enter or a click pastes by posting Cmd+V, Shift+Enter
  pastes plain text, Cmd+1 to Cmd+9 paste the nine latest copies in order (by key position, for
  AZERTY), Cmd+Delete or the × under the mouse deletes, the space bar (nothing typed) shows an
  item the list cuts short beside it (`PreviewWindow`; not for text the row shows in full), items drag out (`ClipDrag`: contents for apps, a file
  promise for folders, which Explorer's `FileDrop` accepts). The list shows the latest 20 (setting);
  "Show All" opens the whole history in a window (`HistoryWindow`, same controller in `.window`
  mode; Clipboard is in the Dock and ⌘Tab while it is open and tells Bar
  with `ClipboardMessage.dockPresenceDidChange`); the pin keeps the list open, above other windows by default. Items can expire (never by
  default); search also finds the text in pictures (`TextRecognizer`, Vision). Copies from
  another device (Universal Clipboard's `com.apple.is-remote-clipboard`, which doesn't say which device)
  are tagged "iCloud". The history can be backed up to iCloud Drive › Explorer › Clipboard › <Mac name>
  (`ClipboardBackup`, off by default, one backup per Mac; an empty history comes back from this Mac's,
  else from the latest another Mac made). The event tap, posting keys and finding the caret
  need Accessibility access; without it ⌘V is left alone, the item is only copied and the panel says
  how to allow it. Its settings are the Clipboard tab of Suite Settings (on/off, hold ⌘V, list
  size, pinned list on top, history size, expiry, iCloud Drive backup, open at login, Clear History, Accessibility, apps to ignore): Suite Settings writes Clipboard's
  defaults and both apps talk through distributed notifications (`ClipboardMessage`); Clipboard
  reports what only it can know (Accessibility, its `SMAppService` login item) in its defaults. Explorer's Edit menu has "Clipboard History", which starts it with `--show` or reopens it;
  Clipboard's Settings item (its gear button) posts `ClipboardMessage.showSettings`, which Explorer answers
  by opening Suite Settings on the Clipboard tab; with Explorer not running, Clipboard starts it with
  `--clipboard-settings`.
- Spotlight's clipboard history (macOS 26, `com.apple.Spotlight`'s `PasteboardHistoryEnabled`): at launch
  Clipboard turns it off (`SpotlightHistoryManager.turnOff()`), keeping Spotlight's own setting in its
  defaults as `SpotlightHistoryBefore` ("on", "off" or "none"), and calls `GuardAgent.update()`; quitting
  (except when it reopens itself for an update) or launched while turned off, it puts it back and calls
  `GuardAgent.update()` again. Should it vanish, Suite Guard puts it back after 15 seconds. Suite Settings'
  agent covers "Results from Clipboard" in System Settings › Spotlight while Clipboard runs.

## Building and running

- `swift build` and `swift test` for development.
- `scripts/make-app.sh` builds `build/Clipboard.app` (release), signs it with the "Suite Local Signing"
  certificate from the login keychain, so macOS permissions survive rebuilds (ad-hoc signing, the
  fallback, re-asks every build), and installs it as `~/Applications/Clipboard.app`, the only copy Launch
  Services knows. It records the branch and commit in the Info.plist (`SuiteBuildBranch`,
  `SuiteBuildCommit`) and refuses to replace an installed copy built from another branch, or from an unknown
  one, unless `--force`: another session may be testing it. `INSTALL_DIR=` builds without installing. A
  running copy is relaunched from the new one.
- Never ask the user to open `build/Clipboard.app` from a worktree.
- UI can't be checked by unit tests and screenshots of the user's screen are not available: check UI by
  rendering views offscreen (`cacheDisplay`) from a scratch package that compiles the sources.
- Releases: change `VERSION` (only `Z` is this repository's own), commit, push, then `scripts/publish.sh`
  pushes the tag; `.github/workflows/release.yml` builds, signs the app with "Suite Release Signing",
  signs `update.json` with the update key (both from the repository's `release` environment secrets),
  publishes the release and updates the cask in `love-suite/homebrew-tap`. The feed is
  `https://github.com/love-suite/suite-clipboard/releases/latest/download/update.json`
  (the GitHub repository it is built from). A change of `AA.Y` comes from the suite repository through
  `.github/workflows/sync-version.yml`. Until `Support/release-certificate.cer` and
  `Support/update-public-key.txt` exist, nothing can be released.

## The suite

This repository is part of Love Suite, one repository per app under `github.com/love-suite`:
`suite-core` (the shared library), `suite-files` (the file layer of the apps handling files),
`suite-guard`, `suite-desktop` (the desktop), `suite-explorer`, `suite-bar` (the Dock), `suite-viewer`,
`suite-clipboard`, `suite-settings` (the settings), `suite-awake` (keeping the Mac awake), `suite-launcher`, `suite-bindings`,
`suite-ai-organizer`; `homebrew-tap` (the tap `love-suite/tap`, one cask per app) and `suite` (the
front page, the suite's version, the scripts that act on every repository). Locally they sit side by side
in `~/GitHub/paul-amour/suite/`.

## Conventions (the same in every repository of the suite)

- The user writes in French and expects answers in French; everything in the code stays in English: code,
  comments, tests, docs, commit messages. Do not add co-author trailers.
- No "…" in menu items, buttons or messages: the user wants none, anywhere.
- Behaviour follows Windows unless Apple's design is asked for.
- Swift Package Manager, `swift-tools-version:5.9`, macOS 13+. Tests use Swift Testing (`import Testing`).
- Toolchain: swiftly, Swift 6.4.2 (`.swift-version`, git-ignored). If `swift test` complains about a
  missing toolchain: `swiftly use 6.4.2`.
- AppKit for windows that need fine control; SwiftUI is allowed for small panels (settings, pickers).
- No private APIs and no system modifications (SIP stays on).
- Git: one worktree per feature under `.worktrees/` (git-ignored), one branch per change
  (`feat/<feature>`, `fix/<area>/<what>`), merged into `main` one by one; `main` stays stable.
- Versions are `AA.Y`, then `AA.Y.Z` for a fix (`VERSION`, tag `vVERSION`: 27.1, then 27.1.1; SwiftPM reads
  `v27.1` as 27.1.0): `AA` is the latest macOS in production (27), `AA.Y` is the same in every repository of
  the suite so the apps work together, `Z` is this repository's own. A change of `AA.Y` is made in `suite`
  and reaches every repository. While a version is being prepared, `VERSION` doesn't move (27.1 now):
  development builds are `VERSION-dev.N`, N the commits since `VERSION` was set, merges aside, from 1 (`make-app.sh`),
  and a change another repository needs gets a development tag, `vVERSION-dev.N`, which releases nothing.
  Dependencies on other repositories of the suite (`suite-core`, `suite-files`, `suite-guard`, settings
  libraries) use
  `.upToNextMinor(from: "27.1.0-dev.1")` (the latest development tag, then the release);
  `Package.resolved` is committed. Tags are never moved once pushed. The build number (`CFBundleVersion`,
  which the updater compares) stays the number of commits.
- Changing two repositories at once: `swift package edit <Package> --path ../<repository>` points at the
  neighbour's working copy until its tag exists, `swift package unedit` goes back. Never committed.
- What two apps need lives in `suite-core` (file code in `suite-files`); an app's own code never goes into another app's repository, and
  an app exposes only its settings, as `<App>Settings`, for Suite Settings.
- Do not run commands that delete user data. Trash instead of delete.
- No code converting saved settings at launch. Before the first release nothing needs converting (the
  developer's own settings don't count): rename freely. Between released versions, a change to saved
  settings is a `SettingsMigration` (suite-core) for the version that brought it, given to the app's
  `SuiteUpdater`, which runs it once after the update.

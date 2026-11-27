# Development

[← Back to the README](../README.md)

---

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/pego/lanes.git
cd lanes
./install.sh
```

The installer builds the app into `~/Applications` and links `lanes` onto
your PATH. Without a Swift toolchain, it builds the dialog-based AppleScript
picker instead. After that:

- `lanes gui` rebuilds and reinstalls the app;
- `lanes chooser` builds the AppleScript picker.

## The layout

```
bin/lanes             the whole engine: profiles, clones, launchers, watchdog, CLI
app/Lanes.swift       the app's model: profiles, usage, alerts, link routing, scenes
app/Provider.swift    the apps a profile can run, and what Lanes needs to know about each
app/ClaudeProvider.swift  Claude Desktop: its app, processes, and usage from claude.ai
app/ChatGPTProvider.swift ChatGPT: its app, and usage from chatgpt.com or its session logs
app/Usage.swift       usage as Lanes keeps it, whatever the provider
app/Window.swift      the window: lanes, drawers, history chart, new-profile sheet
app/MenuBar.swift     the menu bar glyph and panel
app/Settings.swift    settings
app/Components.swift  shared views: meters, lane markings, tinted icons
app/Changelog.swift   What's New: parses the bundled CHANGELOG.md
app/Shared.swift      compiled into both app and widget: colors, limits, usage snapshot, meter
app/Widget.swift      the WidgetKit extension
scripts/              release build, tests, releases, changelog, website, screenshots, the app icon
CHANGELOG.md          release notes for GitHub, the website and What's New
```

The app is a front end. Creating, launching, recoloring and removing a
profile all shell out to the copy of `lanes` inside the app bundle. The CLI,
the launchers and the app therefore share one implementation, and the
script is the place to change behavior.

A profile runs one provider's app: Claude or ChatGPT. A profile folder
names a provider other than Claude in a `.lanes-provider` file (missing
means `claude`; `lanes add --provider` writes it), and `bin/lanes` keeps
each provider's values in `provider_value` and `provider_launch_env`, the
app in `Provider.swift`. Usage is a list of limits, each with its own
window; usage.json and usage.tsv keep their two column pairs, filled from
a profile's first two limits, and record those limits' windows for any
provider but Claude (usage.tsv: in its last three columns, for every row).

ChatGPT ignores `--user-data-dir` for its own data: its clones start with
`CODEX_ELECTRON_USER_DATA_PATH` (Electron's data) and `CODEX_HOME` (sign-in,
sessions) pointing into the profile folder, `--user-data-dir` only so `ps`
shows the profile, and `CODEX_SPARKLE_ENABLED=false`, so a clone never
updates itself and follows the installed app instead. Its usage comes from
chatgpt.com's `wham/usage` with the token in the profile's
`codex-home/auth.json`, which Lanes reads but never refreshes; the fallback
is the newest `rate_limits` in `codex-home/sessions/`.

Lanes builds with plain `swiftc`, with no Xcode project. `lanes gui` and the
release build compile every file in `app/` except `Widget.swift` into the
app, and `Widget.swift` with `Shared.swift` into the extension. The app
targets macOS 13 and the widget macOS 14.

## Release and tests

```sh
scripts/build.sh     # build/Lanes.app, build/Lanes.zip and build/Lanes.dmg
scripts/test.sh      # builds, checks the bundle, runs a quarantined copy's
                     # first-launch setup, the curl installer and
                     # `lanes update`, all in a throwaway HOME
```

The tests never touch your real `~/Applications`, profiles or watchdog.

### Releasing

1. Bump `LANES_VERSION` at the top of `bin/lanes`.
2. Add the version's entry at the top of `CHANGELOG.md`: a
   `## <version> — <title>` heading, the date as `_YYYY-MM-DD_`, then
   paragraphs and `- ` bullets (inline Markdown only).
3. Commit both on `main`, then run `scripts/release.sh`.

The script refuses a version without a changelog entry or one that's already
released. It runs `scripts/test.sh`, shows the notes and asks before it
pushes `main` and creates the release. `scripts/release.sh --notes` prints
the notes without doing anything else.

`CHANGELOG.md` is the one place release notes are written.
`scripts/changelog.py` turns it into the GitHub release notes (with the
install instructions around them) and the website's `changelog.html`. The
build copies it into the app, where **Settings → What's New** shows it. The
first launch after an update also posts a "Lanes updated" notification and
puts a What's New strip in the menu bar panel.

A release is a GitHub release tagged `v<version>` with **both** `Lanes.zip`
and `Lanes.dmg` attached. The curl installer (`site/install`, served at
lanes.pego.tech/install) and the updater (`lanes update`, which the app runs)
download `Lanes.zip`; the website's download button links `Lanes.dmg`. The
updater finds the latest version from where `releases/latest` redirects, so
publishing the release is all it takes.

The version lives in one place, `LANES_VERSION` at the top of `bin/lanes`.
The app's `Info.plist` is written from it.

## Website

```sh
scripts/site.sh serve           # builds _site/ and serves it on localhost:8000
```

`site/` holds the landing page and the changelog template; `scripts/site.sh`
adds the images from `docs/images` and fills the changelog from
`CHANGELOG.md`. The Pages workflow runs the same script on every push to
`main` that touches them.

## Screenshots

```sh
scripts/snapshots.sh            # renders into docs/images
```

The README's screenshots are rendered, not captured. `scripts/snapshots.swift`
compiles the app's views with sample profiles (Default, Work, Studio,
Personal) and draws the window, the panel, the new-profile sheet and the
menu bar icon, each in light and dark mode. It never reads real
profiles or calls the network, and the pictures never show anyone's real
account. Run it after any visual change.

## The app icon

```sh
swift scripts/make-icon.swift app/AppIcon.icns
```

It draws two lanes with Clawd's eyes in the profile colors, and
holds up in a single color.

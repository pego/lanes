#!/bin/zsh
# Release checks: runs the unit tests (scripts/unit-tests.sh), builds the
# app (skip with --no-build), verifies the bundle,
# then installs the zip the way a download arrives (quarantined) into a
# throwaway HOME and runs the app's first-launch setup there. The real
# ~/Applications, profiles and watchdog are never touched; Claude.app is only
# read for its icon.
set -uo pipefail
cd "${0:A:h:h}"

fails=0
check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    print -- "ok   $name"
  else
    print -- "FAIL $name"
    fails=$((fails + 1))
  fi
}

APP="build/Lanes.app"
HELPER_REL="Contents/Resources/Lanes Helper.app/Contents/MacOS/Lanes Helper"
version=$(zsh bin/lanes version)

check "lanes parses" zsh -n bin/lanes
check "unit tests pass" scripts/unit-tests.sh

# ---- `lanes claude` and the status line, with a stand-in claude -------------

cli_home=${$(mktemp -d):A}
mkdir -p "$cli_home/Library/Application Support/Lanes/profiles/Work" "$cli_home/bin"
print -r -- '#!/bin/sh
echo "${CLAUDE_CONFIG_DIR-unset} $*"' > "$cli_home/bin/claude"
chmod +x "$cli_home/bin/claude"
printf '# updated %s\nDefault\torange\t0\t92\t\t10\t\t\t\t\t\t\nWork\tblue\t0\t20\t\t30\t\t\t\t\t\t\n' \
  "$(date +%s)" > "$cli_home/Library/Application Support/Lanes/usage.tsv"
lanes_cli() { HOME="$cli_home" PATH="$cli_home/bin:/usr/bin:/bin" NO_COLOR=1 zsh bin/lanes "$@" 2>/dev/null }
cli_says() { [[ "$(lanes_cli "${@:2}")" == "$1" ]] }
work_cfg="$cli_home/Library/Application Support/Lanes/profiles/Work/claude-config"
check "claude: runs on the profile's config" cli_says "$work_cfg -p hi" claude work -- -p hi
check "claude: passes args without --" cli_says "$work_cfg --version" claude work --version
check "claude: default clears CLAUDE_CONFIG_DIR" sh -c 'CLAUDE_CONFIG_DIR=/x HOME="$1" PATH="$1/bin:/usr/bin:/bin" zsh bin/lanes claude default 2>/dev/null | grep -qx "unset "' _ "$cli_home"
check "claude: --best picks the roomiest" cli_says "$work_cfg " claude --best
check "claude: unknown profile fails" sh -c '! HOME="$1" PATH="$1/bin:/usr/bin:/bin" zsh bin/lanes claude ghost' _ "$cli_home"
# .lanes-provider: "claude" (or none) is today's behavior; a provider this
# Lanes doesn't know is never launched (as Claude or otherwise).
profiles_dir="$cli_home/Library/Application Support/Lanes/profiles"
print claude > "$profiles_dir/Work/.lanes-provider"
check "provider: an explicit claude changes nothing" cli_says "$work_cfg -p hi" claude work -- -p hi
rm "$profiles_dir/Work/.lanes-provider"
mkdir -p "$profiles_dir/Odd"
print future-app > "$profiles_dir/Odd/.lanes-provider"
check "provider: an unknown one isn't launched" sh -c '! HOME="$1" PATH="/usr/bin:/bin" zsh bin/lanes launch odd 2>"$1/err" && grep -q "runs .future-app., which this version of Lanes can.t launch" "$1/err"' _ "$cli_home"
check "provider: its profile still lists" sh -c 'HOME="$1" zsh bin/lanes list | grep -q "^  Odd	"' _ "$cli_home"
rm -rf "$profiles_dir/Odd" "$cli_home/err"
# A ChatGPT profile: never Claude Code's, never "most room" for Claude.
mkdir -p "$profiles_dir/Gpt"
print chatgpt > "$profiles_dir/Gpt/.lanes-provider"
check "provider: lanes claude refuses a ChatGPT profile" sh -c '! HOME="$1" PATH="$1/bin:/usr/bin:/bin" zsh bin/lanes claude gpt 2>"$1/err" && grep -q "runs ChatGPT, not Claude" "$1/err"' _ "$cli_home"
printf 'Gpt\tteal\t0\t1\t\t1\t\t\t\t\t\t\tchatgpt\t18000\t604800\n' >> "$cli_home/Library/Application Support/Lanes/usage.tsv"
check "provider: --best stays on Claude profiles" cli_says "$work_cfg " claude --best
check "provider: ChatGPT clones get their own data and no self-update" sh -c 'out=$(zsh -c "source <(sed -n \"/^provider_launch_env()/,/^}/p\" bin/lanes); provider_launch_env chatgpt /p/Gpt; provider_launch_env claude /p/Work"); [ "$out" = "$(printf "CODEX_ELECTRON_USER_DATA_PATH=/p/Gpt\nCODEX_SPARKLE_ENABLED=false")" ]'
rm -rf "$profiles_dir/Gpt" "$cli_home/err"
# Other windows than Claude's are labeled by their window, in the status
# line, run-out notes and history; Claude's output stays as it was.
usage_tsv="$cli_home/Library/Application Support/Lanes/usage.tsv"
cp "$usage_tsv" "$cli_home/usage.tsv.saved"
far=$(( $(date +%s) + 10 * 86400 ))
printf 'Free\tpink\t0\t40\t\t\t\t\t%s\t\t\t\tchatgpt\t2592000\t\nPlus\tteal\t0\t18\t\t33\t\t\t\t\t\t\tchatgpt\t18000\t604800\n' "$far" >> "$usage_tsv"
check "statusline: a 30-day limit is labeled 30d" sh -c '[ "$(HOME="$1" NO_COLOR=1 zsh bin/lanes usage --statusline free)" = "Free · 30d 40% · out ~$(date -r "$2" "+%b %d %H:%M")" ]' _ "$cli_home" "$far"
check "statusline: Plus reads like Claude's" cli_says "Plus · 5h 18% · week 33%" usage --statusline plus
check "usage: a run-out over a week away shows its date" sh -c 'HOME="$1" NO_COLOR=1 zsh bin/lanes usage 2>&1 | grep -q "30-day limit is used up around $(date -r "$2" "+%b %d %H:%M")"' _ "$cli_home" "$far"
cp "$cli_home/usage.tsv.saved" "$usage_tsv"
hist="$cli_home/Library/Application Support/Lanes/usage-history.json"
now=$(date +%s)
print -r -- "{\"Work\":[{\"t\":$now,\"h\":12.5,\"w\":3}]}" > "$hist"
check "history: Claude's columns unchanged" sh -c '[ "$(HOME="$1" zsh bin/lanes history | head -1)" = "profile,time,five_hour,weekly" ] && HOME="$1" zsh bin/lanes history | grep -q "^Work,.*,12.5,3$"' _ "$cli_home"
print -r -- "{\"Work\":[{\"t\":$now,\"h\":12.5,\"w\":3}],\"Free\":[{\"t\":$now,\"h\":40,\"hw\":2592000}]}" > "$hist"
check "history: other windows are named" sh -c 'out=$(HOME="$1" zsh bin/lanes history); [ "$(printf "%s\n" "$out" | head -1)" = "profile,time,limit1,window1,limit2,window2" ] && printf "%s\n" "$out" | grep -q "^Free,.*,40,30d,,$" && printf "%s\n" "$out" | grep -q "^Work,.*,12.5,5h,3,7d$"' _ "$cli_home"
rm -f "$hist" "$cli_home/usage.tsv.saved"
check "statusline: profile from CLAUDE_CONFIG_DIR" sh -c '[ "$(CLAUDE_CONFIG_DIR="$2" HOME="$1" NO_COLOR=1 zsh bin/lanes usage --statusline)" = "Work · 5h 20% · week 30%" ]' _ "$cli_home" "$work_cfg"
check "statusline: Default without it" cli_says "Default · 5h 92% · week 10%" usage --statusline
check "statusline: red at 90%" sh -c 'HOME="$1" zsh bin/lanes usage --statusline default | grep -q "$(printf "\033\\[31m92%%")"' _ "$cli_home"

# `lanes statusline` edits settings.json: adds, keeps the rest, leaves others alone.
mkdir -p "$cli_home/Library/Application Support/Lanes/profiles/Own/claude-config" "$work_cfg"
print -r -- '{"model":"opus"}' > "$work_cfg/settings.json"
print -r -- '{"statusLine":{"type":"command","command":"mine.sh"}}' > "$cli_home/Library/Application Support/Lanes/profiles/Own/claude-config/settings.json"
sl_state() { lanes_cli statusline --tsv | awk -F'\t' -v p="$1" '$1 == p { print $2 }' }
check "statusline: starts off" test "$(sl_state Work)" = off
check "statusline on: succeeds" lanes_cli statusline on
check "statusline on: adds it" test "$(sl_state Work)" = on
check "statusline on: keeps other settings" grep -q '"model": "opus"' "$work_cfg/settings.json"
check "statusline on: keeps a backup" grep -q '"model":"opus"' "$work_cfg/settings.json.lanes-backup"
check "statusline on: leaves a custom one alone" test "$(sl_state Own)" = other
check "statusline off: removes it" sh -c 'HOME="$1" zsh bin/lanes statusline off work >/dev/null && ! grep -q statusLine "$2/settings.json"' _ "$cli_home" "$work_cfg"
check "whats-new: prints this version" sh -c 'zsh bin/lanes whats-new | head -1 | grep -qF "Lanes $1:"' _ "$version"
check "whats-new: hides try comments" sh -c '! zsh bin/lanes whats-new | grep -q "<!--"'
rm -rf "$cli_home"
if [[ "${1:-}" != "--no-build" ]]; then
  scripts/build.sh >/dev/null 2>&1 || { print -- "FAIL build"; exit 1 }
fi

universal() { [[ "$(lipo -archs "$1")" == *arm64* && "$(lipo -archs "$1")" == *x86_64* ]] }
check "app binary is universal" universal "$APP/Contents/MacOS/Lanes"
check "helper binary is universal" universal "$APP/$HELPER_REL"
WIDGET="$APP/Contents/PlugIns/LanesWidget.appex"
check "widget binary is universal" universal "$WIDGET/Contents/MacOS/LanesWidget"
check "widget is a WidgetKit extension" test "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$WIDGET/Contents/Info.plist")" = com.apple.widgetkit-extension
check "widget enters at NSExtensionMain" sh -c '"$1" 2>&1 | grep -q "XPC Service cannot be run directly"' _ "$WIDGET/Contents/MacOS/LanesWidget"
check "widget is sandboxed" sh -c 'codesign -d --entitlements - "$1" 2>/dev/null | grep -q com.apple.security.app-sandbox' _ "$WIDGET"
check "signature verifies" codesign --verify --deep --strict "$APP"
check "Info.plist version is $version" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$version"
check "bundled lanes is bin/lanes" cmp bin/lanes "$APP/Contents/Resources/lanes"
check "app has its icon" cmp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
check "app bundles the changelog" cmp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"
check "changelog has an entry for $version" python3 scripts/changelog.py title "$version"
check "website changelog builds" sh -c 'python3 scripts/changelog.py html site/changelog.html "$(mktemp)"'

# ---- first launch of a downloaded copy, in a sandbox HOME -------------------

sandbox=${$(mktemp -d):A}
label="io.github.pego.lanes.test-$$"
trap 'launchctl bootout "gui/$(id -u)/$label" 2>/dev/null; rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/Applications" "$sandbox/Library/Application Support/Lanes/profiles/Test" "$sandbox/Applications/Claude Test.app"
cp build/Lanes.zip "$sandbox/"
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" "$sandbox/Lanes.zip"
ditto -x -k "$sandbox/Lanes.zip" "$sandbox/Applications"
installed="$sandbox/Applications/Lanes.app"
cached="$sandbox/Library/Caches/Lanes/Lanes Helper.app"
launcher="$sandbox/Applications/Claude Test.app"

quarantined() { xattr -p com.apple.quarantine "$1" }
not_quarantined() { ! xattr -rl "$1" | grep -q com.apple.quarantine }
# Exit 3 = no app with that pid; a quarantined helper is SIGKILLed instead.
helper_runs() { "$1" focus 999999; [[ $? == 3 ]] }
setup() { HOME="$sandbox" LANES_WATCH_LABEL="$label" zsh "$installed/Contents/Resources/lanes" setup "$@" }

check "download is quarantined" quarantined "$installed/$HELPER_REL"
check "setup succeeds" setup --if-needed
check "setup records version and location" grep -qxF "$version $installed/Contents/Resources/lanes" "$sandbox/Library/Caches/Lanes/setup"
check "cached helper is not quarantined" not_quarantined "$cached"
check "cached helper runs" helper_runs "$cached/Contents/MacOS/Lanes Helper"
check "launcher rebuilt as an applet" test -x "$launcher/Contents/MacOS/applet"
check "launcher bundles this lanes" cmp bin/lanes "$launcher/Contents/Resources/lanes"
check "launcher lanes is not quarantined" not_quarantined "$launcher/Contents/Resources/lanes"
check "launcher signature verifies" codesign --verify "$launcher"
check "watchdog points at the app's lanes" grep -qF "$installed/Contents/Resources/lanes" "$sandbox/Library/LaunchAgents/$label.plist"
check "launcher has a Lanes bundle id" test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$launcher/Contents/Info.plist")" = io.github.pego.lanes.profile.test
check "setup leaves the app's signature intact" codesign --verify --deep --strict "$installed"
doctor() { HOME="$sandbox" LANES_WATCH_LABEL="$label" zsh "$installed/Contents/Resources/lanes" doctor "$@" }
# doctor exits 1 when a check fails, and grep -q quitting early SIGPIPEs it;
# the report is what's tested here.
doctor_says() { { doctor --tsv || true } | grep -q "^$1	$2	" }
check "doctor: launcher in place" doctor_says ok "launcher:Test"
check "doctor: setup is current" doctor_says ok setup
check "doctor: TSV rows have five fields" sh -c 'HOME="$1" LANES_WATCH_LABEL="$2" zsh "$3" doctor --tsv | awk -F"\t" "NF != 5 { bad = 1 } END { exit bad }"' _ "$sandbox" "$label" "$installed/Contents/Resources/lanes"
mkdir -p "$sandbox/Library/Application Support/Lanes/profiles/Orphan"
check "doctor: a missing launcher fails" sh -c '! HOME="$1" LANES_WATCH_LABEL="$2" zsh "$3" doctor >/dev/null 2>&1' _ "$sandbox" "$label" "$installed/Contents/Resources/lanes"
check "doctor: flags it with a fix" doctor_says fail "launcher:Orphan"
rmdir "$sandbox/Library/Application Support/Lanes/profiles/Orphan"
# A ChatGPT profile, where ChatGPT is installed (its app is only read).
if [[ -d /Applications/ChatGPT.app ]]; then
  lanes_sb() { HOME="$sandbox" LANES_WATCH_LABEL="$label" LANES_FROM_CHOOSER=1 zsh "$installed/Contents/Resources/lanes" "$@" }
  gpt_dir="$sandbox/Library/Application Support/Lanes/profiles/Gpt"
  check "chatgpt: add --provider succeeds" lanes_sb add gpt --provider chatgpt --color blue
  check "chatgpt: it records its provider" grep -qx chatgpt "$gpt_dir/.lanes-provider"
  check "chatgpt: launcher is named after ChatGPT" test -x "$sandbox/Applications/ChatGPT Gpt.app/Contents/MacOS/applet"
  check "chatgpt: launcher signature verifies" codesign --verify "$sandbox/Applications/ChatGPT Gpt.app"
  check "chatgpt: a profile's app can't change" sh -c '! HOME="$1" LANES_FROM_CHOOSER=1 zsh "$2" add gpt --provider claude' _ "$sandbox" "$installed/Contents/Resources/lanes"
  check "chatgpt: a Claude profile writes no provider file" test ! -e "$sandbox/Library/Application Support/Lanes/profiles/Test/.lanes-provider"
  check "chatgpt: doctor checks ChatGPT is installed" doctor_says ok chatgpt
  check "chatgpt: doctor finds its launcher" doctor_says ok "launcher:Gpt"
  check "chatgpt: statusline leaves it out" sh -c '! HOME="$1" zsh "$2" statusline --tsv | grep -q "^Gpt"' _ "$sandbox" "$installed/Contents/Resources/lanes"
  lanes_sb remove gpt --delete-data >/dev/null 2>&1
fi
touch -t 200001010000 "$launcher"
setup --if-needed >/dev/null 2>&1
check "setup --if-needed skips when current" test "$(stat -f %Sm -t %Y "$launcher")" = 2000

# ---- the DMG, the curl installer and `lanes update` -------------------------

check "dmg verifies" hdiutil verify -quiet build/Lanes.dmg
check "installer parses" sh -n site/install
# A bare PATH so the installer's CLI symlink never lands in a real bin dir.
fresh="$sandbox/Fresh"
check "curl installer installs" env HOME="$sandbox" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANES_RELEASE_ZIP=build/Lanes.zip LANES_INSTALL_DIR="$fresh" LANES_NO_OPEN=1 sh site/install
check "installed app is this build" cmp bin/lanes "$fresh/Lanes.app/Contents/Resources/lanes"
check "installed app is not quarantined" not_quarantined "$fresh/Lanes.app"
check "installed app's signature verifies" codesign --verify --deep --strict "$fresh/Lanes.app"

update() { HOME="$sandbox" LANES_WATCH_LABEL="$label" LANES_LATEST="$version" LANES_RELEASE_ZIP=build/Lanes.zip zsh "$installed/Contents/Resources/lanes" update "$@" }
update_says() { update --check | grep -qF "$1" }
check "update --check: up to date" update_says "up to date"
check "update: nothing to do when current" update
# Pretend the installed copy is old, then update it to this build.
sed -i '' 's/^LANES_VERSION=.*/LANES_VERSION="0.0.1"/' "$installed/Contents/Resources/lanes"
check "update --check: sees the new version" update_says "$version is available"
check "update installs" update
check "updated app is this build" cmp bin/lanes "$installed/Contents/Resources/lanes"
check "updated app's signature verifies" codesign --verify --deep --strict "$installed"
check "updated app is not quarantined" not_quarantined "$installed"
check "update re-ran setup" grep -qxF "$version $installed/Contents/Resources/lanes" "$sandbox/Library/Caches/Lanes/setup"

# The app runs `lanes update` as its own child, and must still be quit: macOS
# pkill skips its ancestors unless told otherwise. A script stands in for the
# app's binary (its command line holds the same path) and outlives the update
# unless the update kills it.
parent="$sandbox/Parent/Lanes.app"
mkdir -p "$sandbox/Parent"
ditto -x -k build/Lanes.zip "$sandbox/Parent"
sed -i '' 's/^LANES_VERSION=.*/LANES_VERSION="0.0.1"/' "$parent/Contents/Resources/lanes"
cat > "$parent/Contents/MacOS/Lanes" <<EOF
#!/bin/zsh
HOME=${(q)sandbox} LANES_WATCH_LABEL=${(q)label} LANES_LATEST=${(q)version} LANES_RELEASE_ZIP=${(q)PWD}/build/Lanes.zip \\
  LANES_NO_OPEN=1 zsh ${(q)parent}/Contents/Resources/lanes update --relaunch >/dev/null 2>&1 &
wait
sleep 60
EOF
chmod +x "$parent/Contents/MacOS/Lanes"
"$parent/Contents/MacOS/Lanes" &
fake=$!
for i in {1..150}; do kill -0 $fake 2>/dev/null || break; sleep 0.2; done
check "update quits the app that runs it" sh -c '! kill -0 "$1" 2>/dev/null' _ $fake
kill $fake 2>/dev/null
# Let the orphaned update (and its setup) finish before the sandbox goes.
for i in {1..300}; do pgrep -f "$parent/Contents/Resources/lanes" >/dev/null || break; sleep 0.2; done
check "update still replaces it" cmp bin/lanes "$parent/Contents/Resources/lanes"

(( fails == 0 )) && print -- "all passed" || { print -- "$fails failed"; exit 1 }

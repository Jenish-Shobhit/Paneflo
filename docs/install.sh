#!/bin/bash
# Installs Paneflo, or updates it, from its latest GitHub release. Paste into Terminal:
#
#   curl -fsSL https://jenish-shobhit.github.io/Paneflo/install.sh | bash
#
# A file curl downloads isn't quarantined, so Paneflo opens without the "Not Opened" dialog and the Open Anyway
# step that a browser download gets while Paneflo isn't notarized. This script does the checking instead: the zip
# must match the size and SHA-256 GitHub lists for it, the app inside must be Paneflo at that version, and it must
# be signed with Paneflo's own certificate (the one every release and the in-app updater use), or nothing is
# installed. Because the certificate matches, permissions you already granted carry over.
#
# PANEFLO_APP (default /Applications/Paneflo.app) and PANEFLO_NO_OPEN=1 are for testing.
set -euo pipefail

REPO="Jenish-Shobhit/Paneflo"
APP="${PANEFLO_APP:-/Applications/Paneflo.app}"
APP="${APP%/}"
BUNDLE_ID="dev.paneflo.Paneflo"
REQUIREMENT='identifier "dev.paneflo.Paneflo" and certificate leaf = H"3782ecbdc36cecaf6a7719f361076427f2a09c30"'

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The executables of every running process. Read in full first: grep -q in a pipe would cut ps off, and pipefail
# would then report a match as a failure.
processes() { ps -axo comm=; }
# True while the copy at $APP is running.
running() { local p; p=$(processes); grep -Fxq "$APP/Contents/MacOS/Paneflo" <<<"$p"; }
# True while any Paneflo is running, wherever it is.
any_running() { local p; p=$(processes); grep -Eq '/Contents/MacOS/Paneflo$' <<<"$p"; }

# Everything runs inside main, so a download cut short partway through runs nothing.
main() {
  [[ "$(uname -s)" == Darwin ]] || die "Paneflo is a macOS app."
  [[ "$(uname -m)" == arm64 ]] || die "Paneflo needs a Mac with Apple silicon."
  local macos
  macos=$(sw_vers -productVersion)
  (( ${macos%%.*} >= 26 )) || die "Paneflo needs macOS 26 or later; this Mac has $macos."

  say "Finding the latest release"
  local json
  json=$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest") \
    || die "couldn't reach GitHub. Check your connection and try again."
  field() { plutil -extract "$1" raw -o - - <<<"$json" 2>/dev/null; }

  local version zip_name
  version=$(field tag_name) || die "GitHub's answer has no release in it."
  version=${version#v}
  [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "the latest release's tag ($version) isn't a version."
  zip_name="Paneflo-$version.zip"

  local url="" size="" digest="" name i=0
  while name=$(field "assets.$i.name"); do
    if [[ "$name" == "$zip_name" ]]; then
      [[ "$(field "assets.$i.state")" == uploaded ]] || die "Paneflo $version is still being uploaded. Try again in a minute."
      url=$(field "assets.$i.browser_download_url")
      size=$(field "assets.$i.size")
      digest=$(field "assets.$i.digest" || true)
      break
    fi
    i=$((i + 1))
  done
  [[ "$url" == https://github.com/* ]] || die "the latest release has no $zip_name."
  [[ "$size" =~ ^[0-9]+$ ]] || die "GitHub doesn't list the size of $zip_name."

  local installed=""
  [[ -d "$APP" ]] && installed=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)
  if [[ "$installed" == "$version" ]] && codesign --verify --deep --strict -R="$REQUIREMENT" "$APP" 2>/dev/null; then
    say "Paneflo $version is already installed and up to date"
    [[ "${PANEFLO_NO_OPEN:-}" == 1 ]] || open "$APP"
    exit 0
  fi

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  say "Downloading Paneflo $version"
  curl -fL --progress-bar -o "$tmp/$zip_name" "$url" || die "the download failed. Try again."
  [[ "$(stat -f %z "$tmp/$zip_name")" == "$size" ]] || die "the download isn't the size GitHub lists. Nothing was installed."
  if [[ "$digest" == sha256:* ]]; then
    local sum
    sum=$(shasum -a 256 "$tmp/$zip_name" | cut -d ' ' -f 1)
    [[ "sha256:$sum" == "$digest" ]] || die "the download's checksum doesn't match GitHub's. Nothing was installed."
  fi

  say "Checking it"
  ditto -x -k "$tmp/$zip_name" "$tmp/unzipped" || die "the zip couldn't be opened. Nothing was installed."
  local new="$tmp/unzipped/Paneflo.app"
  [[ -d "$new" ]] || die "the zip has no Paneflo.app. Nothing was installed."
  [[ "$(defaults read "$new/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)" == "$BUNDLE_ID" ]] \
    || die "the zip's app isn't Paneflo. Nothing was installed."
  [[ "$(defaults read "$new/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)" == "$version" ]] \
    || die "the zip's app isn't version $version. Nothing was installed."
  codesign --verify --deep --strict -R="$REQUIREMENT" "$new" 2>/dev/null \
    || die "the app isn't signed with Paneflo's certificate. Nothing was installed."

  # You quit Paneflo yourself: asking it to quit with an Apple event would raise an Automation prompt.
  if running; then
    say "Quit Paneflo from its menu bar icon (Quit Paneflo). Waiting…"
    echo "    If you hid the icon, open Paneflo again and turn on Show menu bar icon in Settings › General."
    local _
    for _ in $(seq 1 240); do running || break; sleep 0.5; done
    running && die "Paneflo is still running. Quit it, then run this again. Nothing was installed."
  fi

  if [[ -d "$APP" ]]; then
    mkdir -p "$HOME/.Trash"
    local old="$HOME/.Trash/Paneflo ${installed:-old}.app"
    [[ -e "$old" ]] && old="$HOME/.Trash/Paneflo ${installed:-old} $(date +%H.%M.%S).app"
    mv "$APP" "$old" || die "couldn't move the old Paneflo to the Trash. Nothing was installed."
  fi
  ditto "$new" "$APP" || die "couldn't copy Paneflo into $(dirname "$APP")."
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

  if [[ -n "$installed" ]]; then
    say "Updated Paneflo $installed to $version"
  else
    say "Installed Paneflo $version in $(dirname "$APP")"
  fi
  [[ "${PANEFLO_NO_OPEN:-}" == 1 ]] && return 0
  if any_running; then
    say "Another copy of Paneflo is running. Quit it, then open $APP"
    return 0
  fi
  open "$APP"
}

main "$@"

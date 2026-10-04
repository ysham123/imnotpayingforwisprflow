#!/bin/bash
# Local Dictation installer. Uses only tools included with macOS.
# This template is rendered with immutable release hashes by make-release.py.
set -euo pipefail
release_tag='@TAG@'
base_url='https://github.com/ysham123/imnotpayingforwisprflow/releases/download/'"$release_tag"
app_name='Local Dictation.app'
expected_bundle='dev.yosef.localdictation'
expected_version='@VERSION@'
destination="$HOME/Applications"
assets_dir=''
replace=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --destination) [ "$#" -ge 2 ] || exit 2; destination="$2"; shift 2 ;;
    --assets-dir) [ "$#" -ge 2 ] || exit 2; assets_dir="$2"; shift 2 ;;
    --replace) replace=1; shift ;;
    --help) printf '%s\n' 'Usage: bash install.sh [--destination DIR] [--replace] [--assets-dir DIR]' 'Defaults to ~/Applications. --assets-dir uses already-downloaded release parts.'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'This release requires macOS.'
if [ "$(uname -m)" != arm64 ] && [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" != 1 ]; then
  fail 'This release requires an Apple Silicon Mac (M1 or newer).'
fi
mac_version=$(/usr/bin/sw_vers -productVersion)
[ "${mac_version%%.*}" -ge 14 ] || fail 'This release requires macOS 14 or newer.'
[ "$EUID" -ne 0 ] || fail 'Run this installer as your normal user, without sudo.'
mkdir -p "$destination"
destination="$(cd "$destination" && pwd -P)"
target="$destination/$app_name"
[ ! -L "$target" ] || fail 'The target app is a symlink; choose its real installation folder.'
[ ! -e "$target" ] || [ "$replace" -eq 1 ] || fail 'An app is already installed here. Quit it, then rerun with --replace to update it.'
if [ "$destination" = "$HOME/Applications" ] && [ -d "/Applications/$app_name" ] && [ ! -e "$target" ]; then
  fail 'An existing app is in /Applications. To update that copy, quit it and add --destination /Applications --replace.'
fi
running() { /bin/ps -axo comm= | /usr/bin/grep -F -x "$target/Contents/MacOS/LocalDictation" >/dev/null; }
if running; then fail 'Quit Local Dictation before installing an update.'; fi
available_kb=$(/bin/df -Pk "$destination" | /usr/bin/awk 'NR==2 {print $4}')
[ "$available_kb" -ge 10485760 ] || fail 'Keep at least 10 GB free for download and installation.'
lock="$destination/.localdictation-install.lock"
mkdir "$lock" 2>/dev/null || fail 'Another installer may be running. If it was interrupted, remove the empty .localdictation-install.lock folder and retry.'
stage=''
installed=0
keep_stage=0
move_exact() {
  [ ! -e "$2" ] && [ ! -L "$2" ] || return 1
  /usr/bin/perl -e 'rename($ARGV[0], $ARGV[1]) or die "Cannot move application: $!\n";' "$1" "$2"
}
clean_finder_metadata() {
  # Synced folders can add these non-code attributes during extraction or move.
  # Remove only metadata that codesign forbids; preserve quarantine attributes.
  /usr/bin/xattr -dr com.apple.FinderInfo "$1" 2>/dev/null || true
  /usr/bin/xattr -dr com.apple.ResourceFork "$1" 2>/dev/null || true
}
cleanup() {
  status=$?
  trap - EXIT
  set +e
  if [ "$status" -ne 0 ] && [ -n "$stage" ] && [ -e "$stage/previous.app" ]; then
    if [ "$installed" -eq 1 ]; then move_exact "$target" "$stage/failed.app" || keep_stage=1; fi
    if [ "$keep_stage" -eq 0 ]; then move_exact "$stage/previous.app" "$target" || keep_stage=1; fi
    if [ "$keep_stage" -eq 1 ]; then printf 'Previous app preserved for recovery at: %s/previous.app\n' "$stage" >&2; fi
  elif [ "$status" -ne 0 ] && [ "$installed" -eq 1 ]; then
    if ! move_exact "$target" "$stage/failed.app"; then
      keep_stage=1
      printf 'Installation verification failed. Remove or inspect this app before retrying: %s\n' "$target" >&2
    fi
  fi
  if [ -n "$stage" ] && [ "$keep_stage" -eq 0 ]; then rm -rf "$stage"; fi
  rmdir "$lock" 2>/dev/null
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage=$(mktemp -d "$destination/.localdictation-stage.XXXXXX")
if [ -n "$assets_dir" ]; then
  assets_dir="$(cd "$assets_dir" && pwd -P)"
else
  assets_dir="$HOME/Library/Caches/LocalDictation/Installer/$release_tag"
  mkdir -p "$assets_dir"
fi
printf '\nLocal Dictation %s\nAbout 3.4 GB will be downloaded. Models are included.\n\n' "$expected_version"
part_paths=()
while read -r filename expected_hash expected_bytes; do
  [ -n "$filename" ] || continue
  part="$assets_dir/$filename"
  valid=0
  if [ -f "$part" ]; then
    actual=$(/usr/bin/shasum -a 256 "$part" | /usr/bin/awk '{print $1}')
    [ "$actual" != "$expected_hash" ] || valid=1
  fi
  if [ "$valid" -eq 0 ]; then
    # Downloads live only in this version's cache; a complete but corrupt file
    # is replaced. Smaller partial files can resume after network interruption.
    if [ "$assets_dir" != "$HOME/Library/Caches/LocalDictation/Installer/$release_tag" ]; then
      fail "Missing or invalid local release part: $filename"
    fi
    if [ -f "$part" ] && [ "$(/usr/bin/stat -f %z "$part")" -ge "$expected_bytes" ]; then rm "$part"; fi
    printf 'Downloading %s\n' "$filename"
    /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 30 --continue-at - --output "$part" "$base_url/$filename"
    actual=$(/usr/bin/shasum -a 256 "$part" | /usr/bin/awk '{print $1}')
    [ "$actual" = "$expected_hash" ] || fail "Checksum mismatch for $filename. The app has not been changed. Remove that cached part and retry."
  fi
  printf 'Verified %s\n' "$filename"
  part_paths+=("$part")
done <<'PARTS'
@PARTS@
PARTS
printf '\nExtracting and verifying the app…\n'
/bin/cat "${part_paths[@]}" | /usr/bin/tar -xpf - -C "$stage"
prepared="$stage/$app_name"
[ -d "$prepared" ] && [ ! -L "$prepared" ] || fail 'Release archive does not contain the expected app.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$prepared/Contents/Info.plist")" = "$expected_bundle" ] || fail 'Unexpected bundle identifier.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$prepared/Contents/Info.plist")" = "$expected_version" ] || fail 'Unexpected app version.'
clean_finder_metadata "$prepared"
/usr/bin/codesign --verify --deep --strict "$prepared"
if running; then fail 'Local Dictation opened during installation. Quit it and retry.'; fi
if [ -e "$target" ]; then move_exact "$target" "$stage/previous.app"; fi
move_exact "$prepared" "$target"
installed=1
clean_finder_metadata "$target"
/usr/bin/codesign --verify --deep --strict "$target"
if [ "$assets_dir" = "$HOME/Library/Caches/LocalDictation/Installer/$release_tag" ]; then
  for part in "${part_paths[@]}"; do rm "$part"; done
  rmdir "$assets_dir" 2>/dev/null || true
fi
printf '\nInstalled: %s\n\n' "$target"
printf '%s\n' 'Next: open Local Dictation.app, then use Setup in its microphone menu.' 'Grant Local Dictation Microphone, Accessibility, and Input Monitoring.' 'Keep Fn / Globe or choose your own shortcut in Setup > Dictation shortcut.' 'For Fn: set the Globe key action to Do Nothing and disable competing Fn shortcuts.' 'Click a text box, double-tap Fn, speak, then tap Fn once. Custom shortcuts use one press to start and stop.' '' 'This community build is ad-hoc signed, not notarized by Apple.' 'If macOS blocks opening it, review System Settings > Privacy & Security > Open Anyway.' 'The installer does not change Gatekeeper, permissions, or your keyboard settings.'

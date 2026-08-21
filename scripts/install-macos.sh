#!/bin/bash
#
# Plaza - one-line macOS installer.
#
#   curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-macos.sh | bash
#
# Downloads the latest release, verifies its SHA-256, installs Plaza.app to
# /Applications (or ~/Applications), clears the download-quarantine flag so it
# opens without a Gatekeeper detour, and launches it. Plaza is ad-hoc signed and
# not notarized on purpose: it signs notes with your key, so the trust anchor is
# a build you can reproduce rather than an Apple signature you cannot inspect.
# Read this script, and build from source
# (https://github.com/zig-nostr/plaza#install) if you would rather.
#
set -euo pipefail

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# All work happens inside main(), invoked on the very last line, so bash runs
# nothing until it has read and parsed the whole script. A truncated
# `curl | bash` (a connection dropped mid-stream) then does nothing at all
# rather than executing half an installer.
main() {
  local repo="zig-nostr/plaza"
  local app="Plaza.app"

  # --- platform checks -----------------------------------------------------
  [ "$(uname -s)" = "Darwin" ] || die "Plaza is a macOS app; this installer is macOS-only."
  [ "$(uname -m)" = "arm64" ] || die "Plaza ships for Apple Silicon (arm64) only. On an Intel Mac, build from source: https://github.com/$repo#install"

  local tool
  for tool in curl shasum ditto xattr; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
  done

  # --- find the latest release asset ---------------------------------------
  say "Finding the latest Plaza release..."
  local api="https://api.github.com/repos/$repo/releases/latest"

  # The status is read separately from the body, rather than leaning on
  # `curl -f`, because -f collapses every HTTP answer into one exit code and the
  # script would then report a working API as unreachable. "No release published
  # yet" is a 404, and it is the state the very first reader of the one-line
  # install command is in; telling them their network is broken sends them
  # debugging the wrong thing.
  local resp status json
  resp="$(curl -sSL -w '\n%{http_code}' "$api")" || die "could not reach GitHub. Check your connection and try again."
  status="$(printf '%s' "$resp" | tail -1)"
  json="$(printf '%s' "$resp" | sed '$d')"
  case "$status" in
    200) ;;
    404) die "there is no published release yet. Build from source instead: https://github.com/$repo#install" ;;
    403 | 429) die "GitHub rate-limited this request. Wait a few minutes, or download it from https://github.com/$repo/releases" ;;
    *) die "GitHub answered HTTP $status. Try https://github.com/$repo/releases" ;;
  esac

  # Each `|| true` matters. Under `set -e` with `pipefail`, a grep that matches
  # nothing returns 1, the pipeline inherits it, and the assignment aborts the
  # whole script on the spot with no message at all. The explicit check below,
  # which exists to explain precisely that case, would never be reached: the
  # reader would see the "Finding the latest release" line and then silence.
  local tag url digest
  tag="$(printf '%s' "$json" | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  url="$(printf '%s' "$json" | grep -o '"browser_download_url":[[:space:]]*"[^"]*macos\.zip"' | head -1 | sed -E 's/.*"(https[^"]+)".*/\1/' || true)"
  digest="$(printf '%s' "$json" | grep -o 'sha256:[0-9a-f]\{64\}' | head -1 | cut -d: -f2 || true)"

  [ -n "$url" ] || die "release ${tag:-unknown} has no macOS build attached. Try https://github.com/$repo/releases"
  say "Latest release: ${tag:-unknown}"

  # --- download + verify ---------------------------------------------------
  local zip
  # tmp is intentionally global (not local): the EXIT trap runs after main()
  # returns, where a local would be out of scope. ${tmp:-} keeps set -u happy.
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT
  zip="$tmp/plaza-macos.zip"

  say "Downloading $(basename "$url")..."
  curl -fSL --progress-bar -o "$zip" "$url" || die "download failed."

  if [ -n "$digest" ]; then
    local got
    got="$(shasum -a 256 "$zip" | awk '{print $1}')"
    [ "$got" = "$digest" ] || die "checksum mismatch (expected $digest, got $got). Aborting."
    say "SHA-256 verified."
  else
    say "No published checksum for this release; skipping verification."
  fi

  # --- unpack --------------------------------------------------------------
  say "Unpacking..."
  ditto -x -k "$zip" "$tmp/unpack" || die "could not unzip the download."
  local src="$tmp/unpack/$app"
  [ -d "$src" ] || die "the download did not contain $app."

  # --- choose an install location we can actually write to -----------------
  local dest
  if [ -w "/Applications" ]; then
    dest="/Applications"
  else
    dest="$HOME/Applications"
    mkdir -p "$dest"
  fi

  # --- install (replace any existing copy) ---------------------------------
  #
  # Only the BUNDLE is replaced. Nothing here touches ~/.plaza, which holds the
  # reader's key, their session and their local store: an upgrade that quietly
  # took the key with it would be the worst bug this project could ship.
  if [ -e "$dest/$app" ]; then
    say "Replacing the existing ${app} in ${dest}..."
    # ${var:?} guards against ever expanding to "/" if a variable were empty.
    rm -rf "${dest:?}/${app:?}" || die "could not remove the existing $dest/$app (is it running?)."
  fi
  ditto "$src" "$dest/$app" || die "could not install to $dest."

  # --- clear quarantine so it opens without a Gatekeeper detour -------------
  #
  # An ad-hoc signed app downloaded from the internet is refused by Gatekeeper
  # with "is damaged", and on current macOS the right-click-Open bypass does not
  # clear that verdict. Removing the quarantine attribute is the only reliable
  # way to give it a clean first launch, and doing it here is why this installer
  # exists rather than a "download the zip" paragraph in the README.
  xattr -dr com.apple.quarantine "$dest/$app" 2>/dev/null || true

  say "Installed $app to $dest."
  say "Opening Plaza..."
  open "$dest/$app" || say "Open it from $dest/$app whenever you're ready."
}

main "$@"

#!/bin/bash
#
# Plaza - one-line Linux installer.
#
#   curl -fsSL https://raw.githubusercontent.com/zig-nostr/plaza/main/scripts/install-linux.sh | bash
#
# Downloads the latest release for this architecture, verifies its SHA-256,
# installs into ~/.local (no root, nothing outside your home), registers the
# desktop entry so `plaza://` links open Plaza, and launches it.
#
# Plaza needs GTK 4 at runtime and nothing else: the toolkit's Linux host links
# gtk4 and libdl, and the WebKit layer is compiled out because Plaza draws on a
# canvas rather than in a browser.
#
# Read this script, and build from source
# (https://github.com/zig-nostr/plaza#install) if you would rather.
#
set -euo pipefail

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mnote:\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# All work happens inside main(), invoked on the very last line, so bash runs
# nothing until the whole script has been read. A truncated `curl | bash` (a
# connection dropped mid-stream) then does nothing at all rather than half of
# an install.
main() {
  local repo="zig-nostr/plaza"

  for tool in curl sha256sum tar; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required and is not on PATH."
  done

  # GTK 4 is the one runtime dependency, and finding out it is missing when the
  # window fails to open is worse than being told now. Checked by loader rather
  # than by package name, because the package is called libgtk-4-1 on Debian and
  # Ubuntu, gtk4 on Fedora and Arch, and something else again elsewhere.
  if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -p 2>/dev/null | grep -q "libgtk-4\.so" || die "GTK 4 is missing. Install it first: apt install libgtk-4-1, dnf install gtk4, or pacman -S gtk4."
  fi

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64 | aarch64) ;;
    *) die "no build for $arch. Plaza publishes x86_64 and aarch64; build from source for anything else." ;;
  esac

  say "Looking up the latest release..."
  local api resp code json tag url
  api="https://api.github.com/repos/$repo/releases/latest"
  # Not `curl -f`: -f collapses every HTTP answer into one exit code, so a rate
  # limit and a network failure become the same unhelpful message. The status
  # comes back on its own line instead.
  resp="$(curl -sSL -w '\n%{http_code}' "$api")" || die "could not reach GitHub. Check your connection and try again."
  code="$(printf '%s' "$resp" | tail -1)"
  json="$(printf '%s' "$resp" | sed '$d')"
  case "$code" in
    200) ;;
    403) die "GitHub rate-limited this machine. Wait a few minutes, or download the release by hand." ;;
    404) die "no published release found for $repo." ;;
    *) die "GitHub answered $code." ;;
  esac

  tag="$(printf '%s' "$json" | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  [ -n "$tag" ] || die "could not read the release tag."
  local asset="plaza-${tag#v}-linux-$arch.tar.gz"
  url="https://github.com/$repo/releases/download/$tag/$asset"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  say "Downloading $asset..."
  curl -fSL --progress-bar -o "$tmp/$asset" "$url" || die "download failed. There may be no $arch build for $tag."

  # The digest is published beside the tarball rather than read out of the API
  # body, so a release whose notes were edited cannot change what this compares
  # against.
  if curl -fsSL -o "$tmp/$asset.sha256" "$url.sha256" 2>/dev/null; then
    local want got
    want="$(awk '{print $1}' "$tmp/$asset.sha256")"
    got="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
    [ "$want" = "$got" ] || die "the download does not match its published SHA-256. Not installing it."
    say "SHA-256 verified."
  else
    warn "no published SHA-256 for this release, so the download could not be verified."
  fi

  say "Unpacking..."
  tar -C "$tmp" -xzf "$tmp/$asset"
  local src
  src="$(find "$tmp" -maxdepth 1 -type d -name 'plaza-*-linux-*' | head -1)"
  [ -n "$src" ] || die "the archive did not contain what was expected."
  for required in plaza signer notary; do
    [ -x "$src/bin/$required" ] || die "$required is missing from the archive."
  done

  # ~/.local, so nothing needs root and nothing lands outside the home
  # directory. This is where the XDG spec puts a single user's own programs, and
  # it is what makes uninstalling "delete three paths".
  local prefix="$HOME/.local"
  say "Installing into $prefix..."
  mkdir -p "$prefix/bin" "$prefix/share/applications" "$prefix/share/icons/hicolor"

  # Plaza finds `signer` and `notary` as SIBLINGS of its own executable, so all
  # three go in one directory or the keyholder is silently missing.
  install -m 0755 "$src/bin/plaza" "$src/bin/signer" "$src/bin/notary" "$prefix/bin/"

  # The icons ship as app-icon.png, which is what the toolkit's packager names
  # every app's icon. Installed under that name they would collide with every
  # other app built the same way, so they are renamed on the way in and the
  # desktop entry is pointed at the new name below.
  local size_dir
  while IFS= read -r size_dir; do
    local size
    size="$(basename "$(dirname "$size_dir")")"
    mkdir -p "$prefix/share/icons/hicolor/$size/apps"
    install -m 0644 "$size_dir/app-icon.png" "$prefix/share/icons/hicolor/$size/apps/plaza.png"
  done < <(find "$src/share/icons/hicolor" -type d -name apps 2>/dev/null)

  # Exec must be absolute. The entry ships with a bare executable name, which
  # only resolves if ~/.local/bin is on PATH, and the desktop environment that
  # launches a link handler does not necessarily have the PATH a shell does.
  sed -e "s|^Exec=.*plaza|Exec=$prefix/bin/plaza|" \
      -e "s|^Icon=app-icon$|Icon=plaza|" \
      "$src/share/applications/plaza.desktop" > "$prefix/share/applications/plaza.desktop"
  chmod 0644 "$prefix/share/applications/plaza.desktop"

  grep -q "x-scheme-handler/plaza" "$prefix/share/applications/plaza.desktop" ||
    warn "the desktop entry does not claim plaza:// links, so links will not open Plaza."

  # Best effort: a desktop environment that indexes on its own will find these
  # anyway, and a machine with neither tool is not broken.
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$prefix/share/applications" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    gtk-update-icon-cache -f -t "$prefix/share/icons/hicolor" 2>/dev/null || true
  command -v xdg-mime >/dev/null 2>&1 &&
    xdg-mime default plaza.desktop x-scheme-handler/plaza 2>/dev/null || true

  case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) warn "$prefix/bin is not on your PATH. Add it to run 'plaza' from a terminal; the desktop entry works either way." ;;
  esac

  say "Installed Plaza $tag."
  say "Starting it..."
  "$prefix/bin/plaza" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

main "$@"

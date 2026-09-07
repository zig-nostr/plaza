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
# It does need a RECENT distribution, though. The toolkit's Linux host declares a
# GTK floor of 4.10 (its own source: "This host's GTK floor is 4.10"), and the
# release binaries are built on Ubuntu 24.04, so they want glibc 2.38 or newer.
# Both land on the same generation: Ubuntu 23.10+, Debian 13+, Fedora 39+.
# Ubuntu 22.04 and Debian 12 cannot run this, and are checked for below rather
# than left to fail with a loader error after a successful-looking install.
#
# Read this script, and build from source
# (https://github.com/zig-nostr/plaza#install) if you would rather.
#
set -euo pipefail

# Script scope, not `main`'s. The EXIT trap runs after `main` returns, and a
# `local` is gone by then: under `set -u` the cleanup then dies on its own
# variable, which is a confusing failure at the end of a successful install.
workdir=""
# `return 0` on purpose. Without it the trap's last command is the failed
# `[ -n "$workdir" ]` of a run that never made a temp directory, and bash exits
# with THAT: `--help` reported failure, and so would any early exit that had not
# reached the download yet.
cleanup() {
  [ -n "$workdir" ] && rm -rf "$workdir"
  return 0
}
trap cleanup EXIT

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mnote:\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# Whether GTK 4 is on this machine: `present`, `missing`, or `unknown`.
#
# `ldconfig` is the reliable answer and it lives in /usr/sbin, which Debian does
# NOT put on a normal user's PATH. Gating the whole check on
# `command -v ldconfig` therefore skipped it entirely on one of the three
# distributions this script names as supported: a Debian user without GTK 4 got
# a verified download, a cheerful "Installed Plaza", and an app that dies on
# `libgtk-4.so.1` with the launch output thrown away. So it is looked for by
# absolute path too, and if there is no ldconfig at all the library directories
# are searched directly.
#
# `grep -c ... || true`, NOT `grep -q`. Under `set -o pipefail` a matching
# `grep -q` exits at once, `ldconfig` dies of SIGPIPE, and the pipeline reports
# THAT rather than the match, so the guard fires on a machine that HAS GTK. It
# fires on one that does not either, because grep exits 1 there, which makes it
# a check that can never pass. `grep -c` drains its input instead.
gtkStatus() {
  local ldc hits d
  for ldc in ldconfig /usr/sbin/ldconfig /sbin/ldconfig; do
    command -v "$ldc" >/dev/null 2>&1 || [ -x "$ldc" ] || continue
    hits="$("$ldc" -p 2>/dev/null | grep -c 'libgtk-4\.so' || true)"
    if [ "$hits" = "0" ]; then printf 'missing\n'; else printf 'present\n'; fi
    return
  done
  for d in /usr/lib /usr/lib64 /lib /lib64 /usr/local/lib /usr/lib/*-linux-gnu*; do
    [ -d "$d" ] || continue
    if compgen -G "$d/libgtk-4.so*" >/dev/null 2>&1; then printf 'present\n'; return; fi
  done
  # No ldconfig and nothing in the usual places. Refusing here would turn an
  # unusual layout into a refused install, so this reports that it cannot tell
  # and the caller warns rather than dies.
  printf 'unknown\n'
}

# All work happens inside main(), invoked on the very last line, so bash runs
# nothing until the whole script has been read. A truncated `curl | bash` (a
# connection dropped mid-stream) then does nothing at all rather than half of
# an install.
main() {
  local repo="zig-nostr/plaza"
  # A tarball already on disk, instead of the latest published release. For
  # installing without a network, and for trying a build before it is a release,
  # which is how this script was first tested at all.
  local archive=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --archive) archive="${2:?--archive needs a path}"; shift 2 ;;
      -h | --help)
        printf 'usage: install-linux.sh [--archive <file>]\n\n'
        printf '  --archive <file>  install this tarball instead of the latest release\n'
        exit 0
        ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  # Only what the chosen path actually uses. `curl` belongs to the download,
  # and demanding it for `--archive` refuses an offline install for a tool that
  # install would never call.
  for tool in sha256sum tar; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required and is not on PATH."
  done

  # The distribution floor, checked BEFORE downloading 20 MB and writing files.
  # Without this an Ubuntu 22.04 user gets a clean install, a cheerful
  # "Installed Plaza", and then `version GLIBC_2.38 not found` the first time
  # they open it, which reads as a broken app rather than an old system.
  #
  # glibc is the proxy for both floors. The real constraints are glibc 2.38 (the
  # binaries are built on Ubuntu 24.04) and GTK 4.10 (the toolkit's own declared
  # floor), and every distribution that has one has the other, so one check
  # answers both and needs no -dev package to run.
  local glibc
  glibc="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true)"
  if [ -n "$glibc" ]; then
    local major minor
    major="${glibc%%.*}"
    minor="${glibc##*.}"
    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 38 ]; }; then
      die "this build needs glibc 2.38 or newer and GTK 4.10 or newer; you have glibc $glibc.
       That means Ubuntu 23.10+, Debian 13+, or Fedora 39+. Ubuntu 22.04 and
       Debian 12 are too old for it. Building from source on your own system
       works if its GTK is 4.10 or newer: https://github.com/zig-nostr/plaza#building-on-linux"
    fi
  fi

  # GTK 4 itself, AFTER the floor above. The order matters: an Ubuntu 22.04 user
  # has GTK 4.6, so a GTK-presence check passes and then tells them nothing,
  # while the floor tells them the true reason their machine cannot run this.
  # Checked by loader rather than by package name, because the package is called
  # libgtk-4-1 on Debian and Ubuntu, gtk4 on Fedora and Arch, and something else
  # again elsewhere.
  case "$(gtkStatus)" in
    missing) die "GTK 4 is missing. Install it first: apt install libgtk-4-1, dnf install gtk4, or pacman -S gtk4." ;;
    unknown) warn "could not tell whether GTK 4 is installed on this system. If Plaza does not open, that is the first thing to check." ;;
  esac

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64 | aarch64) ;;
    *) die "no build for $arch. Plaza publishes x86_64 and aarch64; build from source for anything else." ;;
  esac

  local tmp
  tmp="$(mktemp -d)"
  workdir="$tmp"

  local tag asset
  if [ -n "$archive" ]; then
    [ -f "$archive" ] || die "$archive does not exist."
    asset="$(basename "$archive")"
    tag="local"
    say "Installing from $archive"
    cp "$archive" "$tmp/$asset"
    installFrom "$tmp" "$asset" "$tag"
    return
  fi

  command -v curl >/dev/null 2>&1 || die "curl is required to download a release (or pass --archive <file>)."

  say "Looking up the latest release..."
  local api resp code json url
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
  asset="plaza-${tag#v}-linux-$arch.tar.gz"
  url="https://github.com/$repo/releases/download/$tag/$asset"

  say "Downloading $asset..."
  curl -fSL --progress-bar -o "$tmp/$asset" "$url" || die "download failed. There may be no $arch build for $tag."

  # The digest is published beside the tarball rather than read out of the API
  # body, so a release whose notes were edited cannot change what this compares
  # against.
  # Required, not best-effort. It used to warn and install anyway when the
  # sidecar could not be fetched, which is a verification step that any
  # transient failure switches off, and a checksum you skip on a bad day is not
  # a checksum. Every published release has one.
  curl -fsSL --retry 2 --retry-all-errors -o "$tmp/$asset.sha256" "$url.sha256" 2>/dev/null ||
    die "could not fetch the published SHA-256 for $asset, so the download cannot be verified. Not installing it.
       Try again, or download the tarball and its .sha256 by hand and pass --archive."
  local want got
  want="$(awk '{print $1}' "$tmp/$asset.sha256")"
  # An empty expected digest compares equal to an empty computed one, and the
  # whole check then reports success over nothing at all. Both sides are
  # required to exist before either is trusted.
  [ -n "$want" ] || die "the published SHA-256 for $asset is empty. Not installing it."
  got="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
  [ -n "$got" ] || die "could not compute the SHA-256 of the download. Not installing it."
  [ "$want" = "$got" ] || die "the download does not match its published SHA-256. Not installing it."
  say "SHA-256 verified."

  installFrom "$tmp" "$asset" "$tag"
}

# Unpacks an archive and installs it. Shared by the download path and by
# `--archive`, so a local install and a released one are the same install.
installFrom() {
  local tmp="$1" asset="$2" tag="$3"
  say "Unpacking..."
  tar -C "$tmp" -xzf "$tmp/$asset" 2>/dev/null ||
    die "the archive could not be unpacked. The download may be incomplete, or the file passed to --archive may not be a Plaza tarball."
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
  # The packager writes the executable QUOTED (`Exec="plaza" %U`), so the
  # replacement has to swallow the quotes rather than the name alone: matching
  # `.*plaza` leaves the closing quote stranded and the entry is then malformed.
  # The result is quoted too, because a home directory may contain a space.
  sed -E -e "s|^Exec=\"?[^\" ]*\"?|Exec=\"$prefix/bin/plaza\"|" \
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

  if [ "$tag" = "local" ]; then
    say "Installed Plaza from $asset."
  else
    say "Installed Plaza $tag."
  fi

  # Started with its output kept, briefly. It used to go to /dev/null, so a
  # first run that died on a missing library was indistinguishable from a
  # working install: the script said "Starting it...", nothing appeared, and
  # there was nothing anywhere to say why. If it is still alive a moment later
  # the log is dropped and it is left to run.
  say "Starting it..."
  local log pid
  log="$tmp/first-run.log"
  "$prefix/bin/plaza" >"$log" 2>&1 &
  pid=$!
  disown 2>/dev/null || true
  sleep 2
  kill -0 "$pid" 2>/dev/null && return
  warn "Plaza exited immediately. It is installed at $prefix/bin/plaza. This is what it said:"
  sed 's/^/       /' "$log" >&2 || true
}

main "$@"

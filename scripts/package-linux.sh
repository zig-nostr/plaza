#!/bin/bash
#
# Builds Plaza for Linux: a ReleaseFast binary, its two Notary helpers, and the
# desktop entry that makes `plaza://` links work, in one tarball.
#
#   scripts/package-linux.sh --notary <path> [--output dist]
#
# RUN THIS ON LINUX. Not a preference: the toolkit's Linux host links gtk4, and
# a Mac has no Linux copy of it, so a cross build from macOS gets every Zig
# module compiled and then dies at the link. Building in the VM or a container
# is the whole of the difference.
#
# There is no signing here and nothing to notarise. A Linux tarball is bytes in
# a directory, and the trust anchor is the same as it is on macOS: a build you
# can reproduce from source.
set -euo pipefail

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
outdir="$root/dist"
notary_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) outdir="${2:?--output needs a path}"; shift 2 ;;
    --notary) notary_dir="${2:?--notary needs a path}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(uname -s)" = "Linux" ] || die "packaging for Linux needs Linux (the gtk4 link does not cross)."
command -v native >/dev/null 2>&1 || die "the Native SDK CLI is not on PATH (npm install -g @native-sdk/cli)."
pkg-config --exists gtk4 2>/dev/null || die "gtk4 development files are missing (apt install libgtk-4-dev)."

[ -n "${notary_dir:-}" ] || die "pass --notary <path to a notary checkout>"
[ -d "$notary_dir" ] || die "--notary '$notary_dir' is not a directory"

cd "$root"
version="$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' app.zon | head -1)"
[ -n "$version" ] || die "could not read the version from app.zon"
arch="$(uname -m)"
stage="$outdir/plaza-$version-linux-$arch"

# Cleared first, for the same reason the macOS script clears it: `native package`
# does not build, it carries whatever is already sitting in zig-out/bin. On a
# developer's machine that is routinely the last thing they were debugging, and
# the specific hazard is `-Dautomation=true`, which embeds a server that drives
# the UI through the real input path in an app holding the reader's key.
say "Clearing zig-out so nothing stale or instrumented can be picked up..."
rm -rf zig-out "$stage" "$outdir/plaza-$version-linux-$arch.tar.gz"

say "Building (ReleaseFast, no automation)..."
native build .

# Belt and braces, and `grep -c ... || true` rather than `grep -q` on purpose:
# under `set -o pipefail` a matching `grep -q` exits early, `strings` dies of
# SIGPIPE, and the pipeline reports that failure instead of the match, so the
# check passes an instrumented binary straight through. `grep -c` drains its
# input and exits 1 on zero matches, which the `|| true` absorbs.
hits="$(strings zig-out/bin/plaza | grep -c "native-sdk-automation" || true)"
[ "$hits" = "0" ] || die "the built binary carries the automation server ($hits marker(s)). Refusing to package it."

# Plaza is three processes: the app, `signer` (the keyholder daemon that holds
# the secret) and `notary` (the window where a key is brought and unlocked).
# Both helpers are Notary's rather than Plaza's own, and both are resolved as
# SIBLINGS of argv[0], so all three land in the same directory here exactly as
# they share Contents/MacOS in the bundle.
say "Building Notary's daemon and window..."
(cd "$notary_dir/daemon" && zig build -Doptimize=ReleaseFast)
(cd "$notary_dir/gui" && rm -rf zig-out && native build .)

say "Packaging..."
native package --target linux --output "$stage"

say "Injecting sibling binaries beside Plaza..."
for bin in zig-out/bin/*; do
  name="$(basename "$bin")"
  # The app itself is already in place, put there by the packager.
  if [ "$name" = "plaza" ]; then continue; fi
  say "  + $name"
  cp "$bin" "$stage/bin/$name"
done
say "  + signer (Notary's daemon)"
cp "$notary_dir/daemon/zig-out/bin/signer" "$stage/bin/signer"
say "  + notary (the key window)"
cp "$notary_dir/gui/zig-out/bin/notary" "$stage/bin/notary"
chmod +x "$stage/bin/"*

# The same two assertions the macOS script makes, and for the same reasons. The
# app degrades SILENTLY when a sibling is missing (`resolveHelper` gives up
# quietly), so a release is the wrong place to find that out; and deriving the
# copy list from build.zig means anything else installed there rides along,
# which is how `seed-feed` shipped in two macOS releases.
for required in plaza signer notary; do
  [ -x "$stage/bin/$required" ] || die "$required is missing from the package."
done
for bin in "$stage/bin/"*; do
  case "$(basename "$bin")" in
    plaza | signer | notary) ;;
    *) die "$(basename "$bin") is in the package and is not a binary Plaza runs. If it belongs, name it here; if it does not, stop installing it in build.zig." ;;
  esac
done

# What the packager wrote, checked rather than assumed: the desktop entry is
# what makes a `plaza://` link reach the app at all, and it is generated from
# app.zon rather than written here.
desktop="$stage/share/applications/plaza.desktop"
[ -f "$desktop" ] || die "the packager wrote no desktop entry, so plaza:// links would go nowhere."
grep -q "x-scheme-handler/plaza" "$desktop" || die "the desktop entry does not claim plaza:// links."
grep -qE "%[uU]" "$desktop" || die "the desktop entry has no %u or %U, so a link would never reach argv."

say "Compressing..."
tar -C "$outdir" -czf "$outdir/plaza-$version-linux-$arch.tar.gz" "plaza-$version-linux-$arch"
( cd "$outdir" && sha256sum "plaza-$version-linux-$arch.tar.gz" > "plaza-$version-linux-$arch.tar.gz.sha256" )

say "Built $outdir/plaza-$version-linux-$arch.tar.gz"
say "Carries: $(cd "$stage/bin" && echo *)"

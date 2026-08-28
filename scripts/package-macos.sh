#!/bin/bash
#
# Builds Plaza.app for macOS: a ReleaseFast binary in an ad-hoc signed bundle.
#
#   scripts/package-macos.sh --notary <path> [--output dist/Plaza.app]
#
# `--notary` is a checkout of the notary repo. Plaza ships Notary's daemon and
# its window rather than a signer of its own, so the keyholder is built and
# audited once instead of twice.
#
# Ad-hoc signed, NOT notarized, on purpose. Plaza holds a signing key, so the
# trust anchor is a build anyone can reproduce from source rather than an Apple
# signature nobody can check. The installer clears the download-quarantine flag
# so that choice costs the reader nothing.
#
set -euo pipefail

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/dist/Plaza.app"
notary_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out="${2:?--output needs a path}"; shift 2 ;;
    --notary) notary_dir="${2:?--notary needs a path}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "packaging a .app needs macOS."
command -v native >/dev/null 2>&1 || die "the Native SDK CLI is not on PATH (npm install -g @native-sdk/cli)."

cd "$root"

# The binary is built HERE, from a cleared zig-out, and that is the whole point
# of this script existing rather than a bare `native package` in the workflow.
#
# `native package` does not build. It picks up whatever is already sitting in
# zig-out/bin and signs it, reporting "using zig-out/bin/plaza" as it goes. On a
# developer's machine that is routinely the last thing they were debugging, and
# for this app the specific hazard is `native build -Dautomation=true`: that
# binary embeds an automation server that drives the UI through the real input
# path, in an app holding the reader's key. Packaging one and shipping it is a
# single forgotten flag away, and the artifact looks perfectly normal.
say "Clearing zig-out so nothing stale or instrumented can be picked up..."
rm -rf zig-out "$out"

say "Building (ReleaseFast, no automation)..."
native build .

# Belt and braces: assert the property rather than trusting the clean build,
# because this is the one mistake that must never reach a release.
#
# `grep -c ... || true`, NOT `grep -q`. Under `set -o pipefail`, `grep -q` exits
# the moment it matches, `strings` then dies of SIGPIPE, and the pipeline's
# status is that failure rather than grep's success. The `if` takes the else
# branch and the check reports clean on exactly the input it exists to catch. I
# wrote it that way first and it passed an instrumented binary straight through.
# `grep -c` drains its input, so nothing gets a broken pipe; it exits 1 on zero
# matches, which is what the `|| true` absorbs.
hits="$(strings zig-out/bin/plaza | grep -c "native-sdk-automation" || true)"
[ "$hits" = "0" ] || die "the built binary carries the automation server ($hits marker(s)). Refusing to package it."

# Plaza is three processes, not one: the app, `signer` (the keyholder daemon
# that holds the secret) and `Notary` (the window where a key is brought and
# unlocked). Both are NOTARY's, not Plaza's own: one keyholder, built and
# audited once, rather than a second implementation of the most dangerous code
# in the project. Both are resolved as SIBLINGS of argv[0], so both sit in
# Contents/MacOS, and `native package` carries exactly one executable.
#
# They are built from a checkout of the notary repo rather than by this build,
# which is what --notary points at. The app degrades SILENTLY when a sibling is
# missing (`resolveHelper` formats the path with an access check and gives up),
# so the by-name assertion below is what keeps a release from being where that
# is discovered. A bundle with no keyholder in it has shipped once already.
[ -n "${notary_dir:-}" ] || die "pass --notary <path to a notary checkout>"
[ -d "$notary_dir" ] || die "--notary '$notary_dir' is not a directory"

say "Building Notary's daemon and window..."
(cd "$notary_dir/daemon" && zig build -Doptimize=ReleaseFast)
(cd "$notary_dir/gui" && rm -rf zig-out && native build .)

# Packaged UNSIGNED on purpose. A signature covers the bundle's contents, so
# copying binaries in afterwards invalidates it. Inject first, then sign
# inside-out: every nested executable before the bundle that contains them.
say "Packaging (unsigned, so the helpers can be injected)..."
native package --target macos --signing none --output "$out"

say "Injecting sibling binaries beside Plaza..."
for bin in zig-out/bin/*; do
  name="$(basename "$bin")"
  # The app itself is already in place, put there by the packager.
  if [ "$name" = "plaza" ]; then continue; fi
  say "  + $name"
  cp "$bin" "$out/Contents/MacOS/$name"
done
say "  + signer (Notary's daemon)"
cp "$notary_dir/daemon/zig-out/bin/signer" "$out/Contents/MacOS/signer"
say "  + notary (the key window)"
cp "$notary_dir/gui/zig-out/bin/notary" "$out/Contents/MacOS/notary"

say "Signing inside-out..."
for bin in "$out/Contents/MacOS/"*; do
  if [ "$(basename "$bin")" = "plaza" ]; then continue; fi
  codesign --force --sign - --timestamp=none "$bin"
done
codesign --force --sign - --timestamp=none "$out"

codesign --verify --deep --strict "$out" || die "the bundle failed signature verification."

# Assert what a working bundle needs, by name. The loop above is what keeps this
# list from going stale, but the app degrades SILENTLY when a sibling is missing,
# so the release is the wrong place to find out.
for required in plaza signer notary; do
  [ -x "$out/Contents/MacOS/$required" ] || die "$required is missing from the bundle."
done

# And the other direction, which cost two releases before anybody looked.
#
# Deriving the copy list from build.zig is what stops a helper going missing. It
# also means every new install step ships to everybody who downloads Plaza, and
# `seed-feed`, which exists to fabricate a feed for the frame budget, rode along
# in v0.3.0 and v0.4.0. One check catches an omission, the other catches an
# accident; the loop above still does the actual work.
for bin in "$out/Contents/MacOS/"*; do
  case "$(basename "$bin")" in
    plaza | signer | notary) ;;
    *) die "$(basename "$bin") is in the bundle and is not a binary Plaza runs. If it belongs, name it here; if it does not, stop installing it in build.zig." ;;
  esac
done
say "Built $out"
say "Carries: $(cd "$out/Contents/MacOS" && echo *)"

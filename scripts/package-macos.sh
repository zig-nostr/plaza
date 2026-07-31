#!/bin/bash
#
# Builds Plaza.app for macOS: a ReleaseFast binary in an ad-hoc signed bundle.
#
#   scripts/package-macos.sh [--output dist/Plaza.app]
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
[ "${1:-}" = "--output" ] && { out="${2:?--output needs a path}"; }

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

# Plaza is three processes, not one: the app, `plaza-signer` (the isolated
# keyholder daemon that actually holds the secret), and `signet-window` (the key
# ceremony, in its own window). Both helpers are resolved as SIBLINGS of argv[0],
# so both have to sit in Contents/MacOS, and `native package` carries exactly one
# executable.
#
# The list is derived rather than typed out. My first version of this script
# hand-copied the ceremony window, because that was the missing binary I happened
# to be looking at, and shipped a bundle with no keyholder daemon at all:
# `resolveHelper` formats the sibling path with no access check and no fallback,
# so the app would have spawned a file that was not there, silently, and "Create
# your identity" would have dead-ended in a released build. Whatever build.zig
# installs belongs beside the app, so ask build.zig instead of remembering.
say "Building the ceremony window..."
(cd signet-window && rm -rf zig-out && native build .)

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
say "  + signet-window"
cp signet-window/zig-out/bin/signet-window "$out/Contents/MacOS/signet-window"

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
for required in plaza plaza-signer signet-window; do
  [ -x "$out/Contents/MacOS/$required" ] || die "$required is missing from the bundle."
done
say "Built $out"
say "Carries: $(cd "$out/Contents/MacOS" && echo *)"

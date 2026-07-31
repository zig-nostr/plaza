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

# The key ceremony runs in its own process and its own window, so the bundle has
# to carry that binary too. `resolveSignetWindow` looks for it as a SIBLING in
# Contents/MacOS and falls back to the in-process path when it is missing, which
# means a bundle without it does not fail, it just quietly stops showing the
# ceremony. Nothing would have caught that but looking.
say "Building the ceremony window..."
(cd signet-window && rm -rf zig-out && native build .)

# Packaged UNSIGNED on purpose. A signature covers the bundle's contents, so
# copying a binary in afterwards invalidates it. Inject first, then sign
# inside-out: the nested executable before the bundle that contains it.
say "Packaging (unsigned, so the window can be injected)..."
native package --target macos --signing none --output "$out"

say "Injecting the ceremony window beside Plaza..."
cp signet-window/zig-out/bin/signet-window "$out/Contents/MacOS/signet-window"

say "Signing inside-out..."
codesign --force --sign - --timestamp=none "$out/Contents/MacOS/signet-window"
codesign --force --sign - --timestamp=none "$out"

codesign --verify --deep --strict "$out" || die "the bundle failed signature verification."
[ -x "$out/Contents/MacOS/signet-window" ] || die "the ceremony window is missing from the bundle."
say "Built $out"

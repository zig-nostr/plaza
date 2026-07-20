#!/usr/bin/env bash
# Measures Plaza's frame cost while the feed is scrolled hard, and fails if any
# stage drifts past its budget.
#
# The feed is a windowed list: it builds only the rows near the viewport, so
# these numbers should stay flat no matter how long the feed grows. That is the
# claim this script exists to keep honest.
#
# Run it against the build that ships (ReleaseFast). A Debug build is roughly
# thirty times slower per rebuild and will fail every budget here, which is
# correct: nobody runs Debug.
#
#   scripts/frame-budget.sh
#
# Budgets are per stage, in microseconds, at the 90th percentile. A 120 Hz frame
# is 8333 us; the sum of these leaves most of it unspent.
set -euo pipefail

REBUILD_P90_BUDGET=${REBUILD_P90_BUDGET:-400}
LAYOUT_P90_BUDGET=${LAYOUT_P90_BUDGET:-1500}
PATCH_P90_BUDGET=${PATCH_P90_BUDGET:-200}
# The plan stage grows with the number of registered images the app draws
# (upstream reprocesses them every frame); this bound catches the app suddenly
# registering far more than it means to.
PLAN_P90_BUDGET=${PLAN_P90_BUDGET:-3000}

cd "$(dirname "$0")/.."
SNAPSHOT=".zig-cache/native-sdk-automation/snapshot.txt"

echo "building (ReleaseFast, automation on)..."
zig build -Doptimize=ReleaseFast -Dautomation=true

./zig-out/bin/plaza >/tmp/plaza-frame-budget.log 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT

native automate wait --timeout 120 >/dev/null
# Let the feed fill from the relays before measuring it.
sleep 20
native automate snapshot >/dev/null

LIST=$(grep -oE 'main-canvas#[0-9]+ role=(group|list)[^|]*scroll=\[offset=' "$SNAPSHOT" \
  | grep -oE '#[0-9]+' | tr -d '#' | head -1)
if [ -z "$LIST" ]; then
  echo "no scrollable feed found: is the app signed in with notes loaded?" >&2
  exit 1
fi

echo "scrolling..."
native automate profile on >/dev/null
for _ in $(seq 1 16); do native automate widget-wheel main-canvas "$LIST" 420 >/dev/null 2>&1; done
for _ in $(seq 1 16); do native automate widget-wheel main-canvas "$LIST" -420 >/dev/null 2>&1; done
sleep 1
native automate snapshot >/dev/null

stat() { grep -oE "$1=[0-9]+" "$SNAPSHOT" | head -1 | cut -d= -f2; }

REBUILD=$(stat rebuild_p90_us)
LAYOUT=$(stat layout_p90_us)
PATCH=$(stat patch_p90_us)
PLAN=$(stat plan_p90_us)
PRESENT=$(stat present_p90_us)
NODES=$(grep -oE 'widget_nodes=[0-9]+/[0-9]+' "$SNAPSHOT" | head -1)
FALLBACK=$(stat present_fallback_frames)

echo
echo "  rebuild p90   ${REBUILD}us  (budget ${REBUILD_P90_BUDGET})"
echo "  layout  p90   ${LAYOUT}us  (budget ${LAYOUT_P90_BUDGET})"
echo "  patch   p90   ${PATCH}us  (budget ${PATCH_P90_BUDGET})"
echo "  plan    p90   ${PLAN}us  (budget ${PLAN_P90_BUDGET})"
echo "  present p90   ${PRESENT}us  (informational: scales with window pixels, not app work)"
echo "  mounted nodes ${NODES}"
echo "  gpu fallback frames ${FALLBACK}"
echo

FAILED=0
check() { # name value budget
  if [ "$2" -gt "$3" ]; then echo "OVER BUDGET: $1 ${2}us > ${3}us" >&2; FAILED=1; fi
}
check "rebuild p90" "$REBUILD" "$REBUILD_P90_BUDGET"
check "layout p90" "$LAYOUT" "$LAYOUT_P90_BUDGET"
check "patch p90" "$PATCH" "$PATCH_P90_BUDGET"
check "plan p90" "$PLAN" "$PLAN_P90_BUDGET"
# A silent fall back to CPU pixels would make every number above meaningless.
if [ "${FALLBACK:-0}" -gt 0 ]; then
  echo "OVER BUDGET: the GPU path fell back to CPU pixels ${FALLBACK} times" >&2
  FAILED=1
fi

[ "$FAILED" -eq 0 ] && echo "within budget" || exit 1

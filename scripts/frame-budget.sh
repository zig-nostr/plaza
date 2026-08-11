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

# These are DRIFT ALARMS, and the number that matters about each one is its
# headroom over what the app actually costs, not how small it looks.
#
# The first pair were set when a note card was an avatar, a name and a line of
# text. It now carries a verified handle, images, quoted notes, link previews and
# a context menu, and both were straddling their old limits: 315us to 435us
# against 400, and 1700us to 1750us against 1500, best-of-three on a working
# machine with a real account signed in. A budget that the healthy app trips
# every third run teaches people to rerun it until it passes, which is worse
# than having none.
#
# So they are set from measurement with roughly 40 percent headroom over the
# worst honest reading. That is still a tight gate: the regression these exist to
# catch, the feed asking the database who you follow once per card, measures
# 24423us against a rebuild budget of 700.
#
# LAYOUT, raised 2400 -> 3400, and this one is not drift. It is a real cost that
# arrived in one commit, and the number is being moved with the cause written
# down rather than quietly.
#
# Bisected on one machine, one account, one afternoon, best-of-three per run:
#
#   #137, where 2400 was set   1424us  1574us  1646us
#   #138, the next commit      2784us
#   today                      2315us  2389us  2404us
#
# #138 is "Nothing paints past the edge of the window": a display name and a
# NIP-05 handle are strangers' strings, and before it a long one ran hundreds of
# pixels past the window. The fix is a definite `width` on the text leaf itself,
# because that is the only place the SDK will ellipsize from. Two of those sit in
# every feed row, so a screenful pays it eight to sixteen times per frame, and
# fitting bounded single-line text is what costs the extra millisecond.
#
# It is not being reverted and it should not be. The bug it fixed was reported by
# a reader, took a long time to find, and comes back the moment the width comes
# off. Nor can it be made conditional here: a bound is only skippable when the
# string provably fits, and a display name long enough to be worth bounding is
# most display names.
#
# So the budget records what the app costs and the cost is logged as a debt
# against the SDK's text fitting, not hidden inside a number that reads as
# healthy. The gate is still worth having at 3400: it caught this, and nothing
# else did, for fifty-three commits.
REBUILD_P90_BUDGET=${REBUILD_P90_BUDGET:-700}
LAYOUT_P90_BUDGET=${LAYOUT_P90_BUDGET:-3400}
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

stat() { grep -oE "$1=[0-9]+" "$SNAPSHOT" | head -1 | cut -d= -f2; }

# Measured several times, and the BEST round is the one reported.
#
# Not an average, and not one round. These numbers measure this app's share of a
# frame, but the stopwatch runs on a whole machine, so anything else busy on it
# is added to the reading and nothing is ever subtracted. The error is one-sided,
# which makes the minimum the closest estimate of the real cost available here.
#
# Worth spelling out, because the alternative wasted an afternoon: one round put
# the same commit at 322us, 365us, 471us and 787us on four runs while a video
# call was going. Read as four different measurements they look exactly like a
# regression bisecting to a rename, and the bisect duly "found" one. A budget
# that a busy laptop trips on its own is not a budget, it is a coin flip that
# people learn to ignore.
ROUNDS=${FRAME_BUDGET_ROUNDS:-3}
REBUILD=""; LAYOUT=""; PATCH=""; PLAN=""; PRESENT=""; FALLBACK=0
best() { # current candidate -> the smaller, or the candidate if there is no current
  if [ -z "$1" ] || [ "$2" -lt "$1" ]; then echo "$2"; else echo "$1"; fi
}

for round in $(seq 1 "$ROUNDS"); do
  echo "scrolling (round $round of $ROUNDS)..."
  # Turning the profile on starts a fresh sample window, so each round is
  # measured on its own rather than blended into the ones before it.
  native automate profile on >/dev/null
  for _ in $(seq 1 16); do native automate widget-wheel main-canvas "$LIST" 420 >/dev/null 2>&1; done
  for _ in $(seq 1 16); do native automate widget-wheel main-canvas "$LIST" -420 >/dev/null 2>&1; done
  sleep 1
  native automate snapshot >/dev/null

  REBUILD=$(best "$REBUILD" "$(stat rebuild_p90_us)")
  LAYOUT=$(best "$LAYOUT" "$(stat layout_p90_us)")
  PATCH=$(best "$PATCH" "$(stat patch_p90_us)")
  PLAN=$(best "$PLAN" "$(stat plan_p90_us)")
  PRESENT=$(best "$PRESENT" "$(stat present_p90_us)")
  # The one number taken at its WORST across rounds. A single frame that fell
  # back to CPU pixels is a failure whichever round it happened in, and taking
  # the best would be a way of not noticing.
  rounds_fallback=$(stat present_fallback_frames)
  # `|| true`, because a false test is a nonzero line and `set -e` would end the
  # run here on every healthy round.
  [ "${rounds_fallback:-0}" -gt "$FALLBACK" ] && FALLBACK="$rounds_fallback" || true
done

NODES=$(grep -oE 'widget_nodes=[0-9]+/[0-9]+' "$SNAPSHOT" | head -1)

echo
echo "  best of ${ROUNDS} rounds:"
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

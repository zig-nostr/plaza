#!/usr/bin/env bash
# Measures Plaza's frame cost while the feed is scrolled hard, and fails if any
# stage drifts past its budget.
#
# The feed is a windowed list: it builds only the rows near the viewport, so
# these numbers should stay flat no matter how long the feed grows. That is the
# claim this script exists to keep honest.
#
# Run it against the build that ships (ReleaseFast, the default here). A Debug
# build is roughly thirty times slower per rebuild and will fail every budget,
# which is correct: nobody runs Debug. `OPTIMIZE=ReleaseSafe` measures the whole
# app with safety checks on, which is how the cost of doing that was priced:
# rebuild 290us to 852us, layout 1377us to 2650us, three budgets blown. The
# `nostr` library is built ReleaseSafe either way, see `libraryOptimize` in
# build.zig, and that part costs nothing measurable here, which is the point of
# splitting them.
#
#   scripts/frame-budget.sh
#
# Budgets are per stage, in microseconds, at the 90th percentile. A 120 Hz frame
# is 8333 us; the sum of these leaves most of it unspent.
set -euo pipefail

# Set from measurement against the FIXED corpus this harness seeds, with about
# forty percent over the worst honest reading. They are only comparable to other
# runs of this harness: the corpus carries no images and no link previews, on
# purpose, so these numbers are lower than a real feed's and are not meant to
# describe one.
#
# Four consecutive runs on unchanged code, best-of-three rounds each, on battery
# with Low Power Mode off:
#
#   mounted nodes  462   462   462   462     (identical, which is the point)
#   layout  p90   1388  1526  1594  1495     spread 1.15x
#   rebuild p90    290   378   351   396
#   plan    p90    936    ...
#
# Before the corpus was pinned the same readings spanned 2.4x and the node count
# ranged 296 to 521, because the feed was whatever the relays had sent. That gate
# could only catch order-of-magnitude regressions, and it produced two wrong
# conclusions in one afternoon: a real 35% layout regression read as noise, then
# a 300us saving read as confirmed. Neither was knowable from it.
#
# The remaining 1.15x is the machine, not the app. Compare readings only against
# others taken in the same power state; the script prints it.
#
# The regression these exist to catch, the feed asking the database who you
# follow once per card, measures 24423us against a rebuild budget of 600.
REBUILD_P90_BUDGET=${REBUILD_P90_BUDGET:-600}
LAYOUT_P90_BUDGET=${LAYOUT_P90_BUDGET:-2200}
PATCH_P90_BUDGET=${PATCH_P90_BUDGET:-150}
PLAN_P90_BUDGET=${PLAN_P90_BUDGET:-1400}

cd "$(dirname "$0")/.."
SNAPSHOT=".zig-cache/native-sdk-automation/snapshot.txt"

OPTIMIZE="${OPTIMIZE:-ReleaseFast}"
echo "building ($OPTIMIZE, automation on)..."
zig build "-Doptimize=$OPTIMIZE" -Dautomation=true
# Asked for by name, because a plain `zig build` no longer installs it: the
# packager ships whatever build.zig installs, and a tool that fabricates a feed
# has no business inside a signed app bundle. Built Debug, since it runs once
# before a measurement and is not measured itself.
zig build seed-feed

# A FIXED FEED, and its own $HOME.
#
# This used to run against the real account and whatever the relays happened to
# send, so two runs of one binary laid out different numbers of image rows,
# quote cards and link previews. The layout reading swung 2.4x on unchanged
# code: twenty-two readings in one afternoon spanned 1424us to 3376us, and
# dividing by the mounted node count did not stabilise them (3.45 to 7.54us per
# node). A gate that noisy can only catch order-of-magnitude regressions, and it
# produced two wrong conclusions in a day, in both directions.
#
# So the app gets a $HOME of its own. Everything it keeps hangs off $HOME/.plaza
# (the store, the identity, the session, the relay list), so one variable
# isolates all of it, and the seeder leaves an EMPTY relay list, which is a
# reader who removed every relay: the pool parks and nothing is dialled. No feed
# arrives mid-measurement because no feed can arrive.
#
# It also stops the harness measuring, and depending on, whoever is signed in.
BENCH_HOME="${FRAME_BUDGET_HOME:-/tmp/plaza-frame-budget-home}"
rm -rf "$BENCH_HOME"
mkdir -p "$BENCH_HOME"
./zig-out/bin/seed-feed "$BENCH_HOME/.plaza" >/dev/null

# What the machine was doing, recorded rather than assumed. Apple Silicon on
# battery is not the same machine as on mains, and Low Power Mode is a third.
# None of this was being checked while twenty-two readings were compared to each
# other, which is its own answer to where some of that 2.4x came from.
POWER="$(pmset -g batt 2>/dev/null | head -1 | sed -e "s/Now drawing from //" -e "s/'//g")"
LOWPOWER="$(pmset -g 2>/dev/null | awk '/lowpowermode/ {print $2}')"
echo "measuring on: ${POWER:-unknown} power, low power mode ${LOWPOWER:-unknown}"
echo "compare readings only against others taken in the same state."

HOME="$BENCH_HOME" ./zig-out/bin/plaza >/tmp/plaza-frame-budget.log 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT

native automate wait --timeout 120 >/dev/null
# The feed comes from the store, so it is up as soon as the app is. This is only
# for the first frames to settle.
sleep 3
native automate snapshot >/dev/null

LIST=$(grep -oE 'main-canvas#[0-9]+ role=(group|list)[^|]*scroll=\[offset=' "$SNAPSHOT" \
  | grep -oE '#[0-9]+' | tr -d '#' | head -1)
if [ -z "$LIST" ]; then
  echo "no scrollable feed found: did seed-feed populate $BENCH_HOME/.plaza?" >&2
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

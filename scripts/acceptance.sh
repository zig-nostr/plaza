#!/usr/bin/env bash
#
# Journeys a reader actually takes, driven against a real build.
#
#   scripts/acceptance.sh              # every journey
#   scripts/acceptance.sh follows      # one journey by name
#
# The unit suite proves the pieces. This proves the assembled thing: that the
# bundle launches the way a person launches it, that a cold app fills a feed
# from the public internet, and above all that a real contact list comes out the
# other side of a session intact.
#
# That last one is why this file exists. Every other check here has a cheaper
# equivalent somewhere; "did editing one follow destroy the other 299" has none,
# because the damage happens on relays, in someone else's database, and no
# amount of local testing can see it. So the follows journey publishes to a real
# relay and reads the result back with an independent tool.
#
# NOT part of CI, on purpose. It publishes signed events to public relays and it
# needs a key, neither of which belongs in a pull request check. Run it by hand
# before tagging a release.
#
# What it needs:
#
#   PLAZA_ACCEPTANCE_KEY    a THROWAWAY account's secret key, hex or nsec, whose
#                           contact list on relays already has a few hundred
#                           people in it. Nothing else will do: a list of nine
#                           cannot tell a healthy splice apart from a wipe.
#   PLAZA_ACCEPTANCE_RELAY  one relay to publish to and read back from.
#                           Default wss://nos.lol. One, not several: reading
#                           back from a relay the write may not have reached
#                           turns a real failure into a coin flip.
#
# Never point it at an account you care about. It signs and publishes under that
# key, and while the follows journey restores what it changed, a crash halfway
# leaves the list one person short until it is run again.
#
set -euo pipefail

RELAY="${PLAZA_ACCEPTANCE_RELAY:-wss://nos.lol}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/plaza-acceptance.$$"
SNAP="$ROOT/.zig-cache/native-sdk-automation/snapshot.txt"
APP_PID=""

PASSED=0
FAILED=0
SKIPPED=0

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
pass() { printf '\033[1;32m  ok\033[0m %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }
skip() { printf '\033[1;33mskip\033[0m %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# macOS has no `timeout`, and every command here talks to the network. Without a
# bound, one unresponsive relay hangs the run forever instead of failing it. An
# early version of this file used `timeout` anyway: it is not installed, the
# shell said so on stderr, stderr was going to /dev/null, and the check reported
# an empty result as "no events found" rather than as the missing tool it was.
#
# The command runs directly rather than under `sh -c`, so the kill lands on the
# process that is hanging. Wrapped in a shell, the kill takes the wrapper and
# leaves the real one behind, still connected to the file the caller is about to
# read.
bounded() { # seconds command...
  local secs="$1"; shift
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  # By build path, so this can never reach an installed Plaza. The ceremony
  # window and the keyholder daemon are children, and a killed parent does not
  # take them with it.
  pkill -f "$ROOT/zig-out/bin/plaza" 2>/dev/null || true
  pkill -f "notary/gui/zig-out/bin/notary" 2>/dev/null || true
}
trap cleanup EXIT

# Launches the automation build against a home of our own. The isolated HOME is
# not tidiness: Plaza keeps the reader's key, session and store under $HOME, and
# a journey that signs out would sign THEM out.
launch() { # home-dir [KEY=VALUE ...]
  local home="$1"; shift
  # Anything still running from THIS build path is a leak from an earlier run,
  # and leaving it costs more than a stray process: every app started in this
  # directory publishes to the same automation snapshot, so two of them take
  # turns describing the screen. A journey then reads one app's feed, presses a
  # button in the other, and reports whatever the last writer happened to say.
  # Six of them accumulated before I understood that was what I was looking at:
  # a Follow button flapping between states nobody was pressing.
  pkill -f "$ROOT/zig-out/bin/plaza" 2>/dev/null || true
  sleep 1
  rm -rf "$ROOT/.zig-cache/native-sdk-automation"
  # `exec`, so the subshell BECOMES the app and $! is the app's own pid. Without
  # it, $! is the subshell, every kill takes the wrapper, and the app is orphaned
  # to init still holding its window and still writing that shared snapshot.
  # That is exactly how the six above happened.
  #
  # Started by absolute path though the working directory is the same, because
  # the pattern above matches a COMMAND LINE. Launched as ./zig-out/bin/plaza it
  # reads as a relative path and no absolute pattern will ever match it, so the
  # cleanup that exists to prevent all this would have quietly matched nothing.
  # Extra environment goes to Plaza AND to the keyholder it starts, because a
  # spawned child inherits it. That is how a journey gets a signed-in machine:
  # Plaza holds no key to seed any more, so the key is seeded into the daemon.
  (cd "$ROOT" && exec env HOME="$home" "$@" "$ROOT/zig-out/bin/plaza") >"$WORK/app.log" 2>&1 &
  APP_PID=$!
  (cd "$ROOT" && native automate wait --timeout 90 >/dev/null 2>&1) \
    || die "the app never published a snapshot. See $WORK/app.log"
}

stop_app() {
  # Braced and silenced together: the shell announces a killed job on its own
  # stderr when it reaps one, which reads like an error in the middle of a
  # passing run.
  if [ -n "$APP_PID" ]; then
    { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; } 2>/dev/null
  fi
  APP_PID=""
  # The keyholder daemon is a child, and killing the app does not take it with
  # it. Left behind it holds its port, and the next journey's app finds it
  # occupied.
  pkill -f "$ROOT/zig-out/bin/plaza" 2>/dev/null || true
  sleep 2
}

snap() { (cd "$ROOT" && native automate snapshot >/dev/null 2>&1) || true; }

# The widget id of the first node with this exact accessibility name. Ids move
# every rebuild, so nothing here may hardcode one.
wid() { # role name
  grep -oE "main-canvas#[0-9]+ role=$1 name=\"$2\"" "$SNAP" \
    | head -1 | grep -oE '#[0-9]+' | tr -d '#'
}

# Snapshots FIRST, always. Widget ids are per rebuild, and the snapshot on disk
# is only as fresh as the last command that asked for one. Reusing a stale one
# after a minute of talking to a relay is how a press landed on an id the app no
# longer had, reported as "could not press Follow" on a button plainly there.
click() { # role name
  local id
  snap
  id="$(wid "$1" "$2")"
  [ -n "$id" ] || return 1
  (cd "$ROOT" && native automate widget-click main-canvas "$id" >/dev/null 2>&1)
}

# Blocks until a pattern shows up in the snapshot, or gives up.
await()  { (cd "$ROOT" && native automate assert --timeout-ms "$1" "$2" >/dev/null 2>&1); }
awaitno() { (cd "$ROOT" && native automate assert --absent --timeout-ms "$1" "$2" >/dev/null 2>&1); }

# Opens a profile the account is known to follow, and says so by leaving the
# app on it.
#
# Taking the first avatar in the feed is not enough. Most of them are people the
# account follows, but a quoted note or a reply carries strangers, and landing on
# one turns a bug in the app and an unlucky feed into the same red. So it walks
# the cards until the profile it reaches offers to unfollow.
#
# Every step waits for the state it needs rather than sleeping at it. Sleeping
# is what broke the first version: a profile that took a moment longer than the
# sleep left the walk reading widget ids off the page it was still on, so the
# next press landed somewhere arbitrary and the two after that were nonsense.
# Six attempts then failed for one slow page.
#
# The walk repeats until a deadline, because the feed lags the account. The scope
# label flips to "Following" when the list is adopted, but the cards on screen at
# that instant are still the starter pack's, and every one of their authors is a
# stranger. Waiting on the label alone, the walk opened six strangers in a row
# and reported that the list had never been adopted, which is a sentence about
# the app that was not true.
open_followed_profile() {
  local n id deadline=$((SECONDS + 150))
  while [ "$SECONDS" -lt "$deadline" ]; do
    for n in 1 2 3 4 5 6; do
      snap
      id="$(grep -oE 'main-canvas#[0-9]+ role=button name="Open profile"' "$SNAP" \
            | sed -n "${n}p" | grep -oE '#[0-9]+' | tr -d '#')"
      [ -n "$id" ] || continue
      (cd "$ROOT" && native automate widget-click main-canvas "$id" >/dev/null 2>&1) || continue
      # No closing quote: this is the one pattern that matches Follow and
      # Following alike, and the assert dialect has no alternation.
      await 15000 'role=button name="Follow' || continue
      snap
      [ -n "$(wid button Following)" ] && return 0
      click button "Back" || true
      # Back on the feed means the profile's Back button is gone. Without this the
      # next iteration reads its avatar ids off the profile page.
      awaitno 10000 'role=button name="Back"' || true
    done
    sleep 5
  done
  return 1
}

# The account's contact list as it stands on the relay, written to a file.
fetch_list() { # out-file
  local out="$1" raw="$1.raw"
  : >"$raw"
  bounded 45 nak req -k 3 -l 1 -a "$PUBKEY" "$RELAY" >"$raw" 2>/dev/null || true
  head -1 "$raw" >"$out" || true
  # A zero-byte file is "the relay answered with nothing", which is a real and
  # different outcome from "nak is missing"; the caller reports it as such.
  [ -s "$out" ]
}

# The list, once the relay is serving something this run published. Polls, so a
# slow signer or a slow relay costs time rather than a false red.
fetch_list_after() { # min-stamp out-file
  local min="$1" out="$2" tries=0
  while [ "$tries" -lt 10 ]; do
    if fetch_list "$out" && [ "$(stamp "$out" created_at)" -gt "$min" ]; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 3
  done
  return 1
}

people() { # event-file  -> one pubkey per line
  python3 -c "
import json, sys
line = open(sys.argv[1]).readline().strip()
e = json.loads(line)
for t in e['tags']:
    if t[0] == 'p' and len(t) >= 2:
        print(t[1].lower())
" "$1" | sort -u
}

stamp() { # event-file field
  python3 -c "
import json, sys
print(json.loads(open(sys.argv[1]).readline())[sys.argv[2]])
" "$1" "$2"
}

# ---------------------------------------------------------------------------

build() {
  say "Building (ReleaseFast, automation on)..."
  (cd "$ROOT" && zig build -Doptimize=ReleaseFast -Dautomation=true) \
    || die "the build failed."
}

# A packaged bundle, launched the way a person launches it.
#
# This is the journey the unit suite structurally cannot cover, and the one that
# has already shipped broken once in this project's sibling: tests green, app
# dead on first launch, because a Finder launch hands a process a minimal
# environment that a shell launch does not. So the launch here goes through
# LaunchServices, exactly as double-clicking does, and the assertion is that
# the app and the keyholder it starts are both alive a few seconds later.
#
# It runs LAST in a full pass. Packaging clears zig-out on purpose, so that
# nothing instrumented can be signed and shipped, which also means it destroys
# the automation binary every other journey drives.
journey_bundle() {
  say "Journey: the packaged bundle comes up"
  [ "$(uname -s)" = "Darwin" ] || { skip "packaging is macOS only"; return; }

  local app="$WORK/Plaza.app" home="$WORK/bundle-home"
  mkdir -p "$home"

  # The bundle carries Notary's daemon and window, so packaging needs a Notary
  # checkout. At the SAME tag the release workflow pins, read from the workflow
  # rather than typed here: a bundle built against a different Notary is not the
  # bundle anybody downloads, and this journey exists to test the one they do.
  local notary_ref
  notary_ref="$(sed -n 's/^ *NOTARY_REF: *\(.*\)$/\1/p' "$ROOT/.github/workflows/release.yml" | head -1)"
  [ -n "$notary_ref" ] || { fail "could not read NOTARY_REF from the release workflow"; return; }
  local notary="$WORK/notary"
  info "packaging against notary $notary_ref"
  if ! git clone -q --depth 1 --branch "$notary_ref" https://github.com/zig-nostr/notary.git "$notary" 2>"$WORK/notary-clone.log"; then
    skip "could not fetch notary $notary_ref. See $WORK/notary-clone.log"
    return
  fi

  (cd "$ROOT" && scripts/package-macos.sh --notary "$notary" --output "$app" >"$WORK/package.log" 2>&1) \
    || { fail "packaging failed. See $WORK/package.log"; return; }
  pass "the bundle built and passed signature verification"

  # `open --env` is what makes this faithful AND safe at once: LaunchServices
  # gives the app the minimal environment a double click gives it, and HOME
  # still points somewhere disposable.
  open -n --env "HOME=$home" "$app" || { fail "the bundle would not launch"; return; }
  sleep 8

  # `|| true` on both, because a bare `A && B` that fails is a nonzero line, and
  # `set -e` would exit the run at the exact moment the check found something.
  local alive=0
  pgrep -f "$app/Contents/MacOS/plaza$" >/dev/null 2>&1 && alive=$((alive + 1)) || true
  pgrep -f "$app/Contents/MacOS/signer" >/dev/null 2>&1 && alive=$((alive + 1)) || true

  if [ "$alive" -eq 2 ]; then
    pass "the app and its keyholder daemon are both running"
  else
    fail "expected the app and its signer to be running, found $alive of 2"
  fi

  # It wrote a store under the disposable home rather than anywhere else.
  if [ -f "$home/.plaza/feed.mdb" ]; then
    pass "it kept its data under the home it was given"
  else
    fail "no store under $home/.plaza: where did it write?"
  fi

  pkill -f "$app/Contents/MacOS/plaza" 2>/dev/null || true
  sleep 2
}

# Reading needs no identity.
#
# A cold start with nothing on disk has to reach the public internet, fill a
# feed and render it, without a key existing anywhere. If this fails, nobody
# ever sees the app at all.
journey_guest() {
  say "Journey: a cold app fills a feed with no identity"
  build
  local home="$WORK/guest-home"
  rm -rf "$home"; mkdir -p "$home"
  launch "$home"

  # Notes arrive from relays, so this waits rather than sleeps.
  if (cd "$ROOT" && native automate assert --timeout-ms 60000 \
        'role=button name="Open profile"' 'role=button name="Sign in"' >/dev/null 2>&1); then
    pass "notes from relays are on screen and the app is offering to sign in"
  else
    fail "no feed after 60s on a cold start. See $WORK/app.log"
  fi

  if [ ! -e "$home/.plaza/identity.key" ]; then
    pass "reading created no key"
  else
    fail "a key exists after a session that never asked for one"
  fi

  # The window opens at the size app.zon asks for, measured rather than assumed.
  #
  # This is here because it was WRONG for the entire life of the app and nothing
  # noticed: the toolkit reported the window's frame where the runtime wanted its
  # content size, so the canvas was 32 points taller than the view it lived in
  # and the status bar was laid out below the bottom edge. It was invisible on
  # every fresh launch and came back the first time anyone dragged the window,
  # which is why it read as intermittent.
  #
  # No unit test can see this: the layout is correct at whatever size it is
  # handed, and the defect is which size that is. It only exists in a real
  # window, so it is only catchable here.
  snap
  local want_h canvas_h
  want_h=$(grep -oE '\.height = [0-9]+' "$ROOT/app.zon" | head -1 | grep -oE '[0-9]+')
  canvas_h=$(grep -oE 'main-canvas#[0-9]+ role=group name="" bounds=\(0,0 [0-9]+x[0-9]+\)' \
    "$SNAP" | head -1 | grep -oE 'x[0-9]+\)' | grep -oE '[0-9]+')
  if [ -n "$canvas_h" ] && [ "$canvas_h" = "$want_h" ]; then
    pass "the canvas is the ${want_h}pt app.zon declares, so nothing is laid out past the window"
  else
    fail "app.zon asks for a ${want_h}pt window and the canvas is ${canvas_h:-unknown}pt. Anything on the bottom edge is off screen (see plaza#100)"
  fi

  stop_app
}

# The one that matters.
#
# A real contact list, a real relay, and an independent tool reading back what
# was published. The account's list is the adversarial input: several hundred
# people is more than any internal buffer this app sizes by hand, so a cap that
# leaked into a write shows up here as a number and nowhere else.
#
# The round trip restores what it changed, which also happens to exercise both
# branches: removing a name is the shrink path the code calls the dangerous one,
# and adding it back is the growth path.
journey_follows() {
  say "Journey: editing one follow leaves the rest alone"

  if [ -z "${PLAZA_ACCEPTANCE_KEY:-}" ]; then
    skip "no PLAZA_ACCEPTANCE_KEY: the only check that can see relay damage did not run"
    return
  fi
  command -v nak >/dev/null 2>&1 || { skip "nak is not installed"; return; }
  command -v python3 >/dev/null 2>&1 || { skip "python3 is not installed"; return; }

  build
  local secret="$PLAZA_ACCEPTANCE_KEY"
  case "$secret" in
    nsec1*) secret="$(nak decode "$secret" | python3 -c 'import json,sys; print(json.load(sys.stdin)["private_key"])')" ;;
  esac
  [ "${#secret}" -eq 64 ] || { fail "PLAZA_ACCEPTANCE_KEY is not a 32 byte secret key"; return; }
  PUBKEY="$(nak key public "$secret")"
  info "account $PUBKEY"

  local base="$WORK/list-before.json"
  if ! fetch_list "$base"; then
    fail "could not read the account's contact list from $RELAY"
    return
  fi
  people "$base" >"$WORK/people-before.txt"
  local before
  before="$(wc -l <"$WORK/people-before.txt" | tr -d ' ')"
  info "the account follows $before people, list stamped $(stamp "$base" created_at)"
  if [ "$before" -lt 200 ]; then
    skip "this account follows only $before people, too few to prove a splice"
    return
  fi

  # Seeded rather than typed, and seeded into the KEYHOLDER rather than into
  # Plaza. Plaza holds no secret key any more: there is no field in it that can,
  # which is the whole point of the split. So the key goes to the daemon through
  # its own dev-only environment variable, and Plaza's session says only which
  # account it is signed in as.
  #
  # The window where a key is really brought is a second process with no
  # automation server in it, by design, which is why this is seeded at all.
  local home="$WORK/follows-home"
  rm -rf "$home"; mkdir -p "$home/.plaza"
  # No session file: Plaza adopts whatever key the keyholder reports on its
  # first health poll. That path exists so a key brought in from a terminal
  # signs you in without a restart, and it is exactly what a seeded daemon
  # looks like from here.
  launch "$home" "SIGNER_SECRET_KEY=$secret"
  # The feed scope is the app's own answer to "have I got your list yet": it
  # reads "Starter pack" until the account's own contact list is adopted, and
  # "Following" after. Waiting on notes instead is what broke this: cards from
  # the starter pack are on screen well before the real list lands, so the walk
  # below would open six profiles the account does not follow yet and conclude
  # the list was never adopted at all.
  if (cd "$ROOT" && native automate assert --timeout-ms 120000 \
        'role=text name="Following"' 'role=button name="Open profile"' >/dev/null 2>&1); then
    pass "signed in, with the account's own follow list adopted"
  else
    fail "the account's own list never arrived in 120s. See $WORK/app.log"
    stop_app
    return
  fi

  if ! open_followed_profile; then
    fail "no profile in the feed offers to unfollow: is the list adopted at all?"
    stop_app
    return
  fi

  local t0
  t0="$(stamp "$base" created_at)"

  # Waits for Follow to APPEAR rather than for Following to go away. The absence
  # of a label is also what a navigation away looks like, so the negative form
  # would pass on a press that went somewhere else entirely.
  click button "Following" || { fail "could not press Following"; stop_app; return; }
  if await 15000 'role=button name="Follow"'; then
    pass "the button turned back into Follow"
  else
    fail "the button did not change after unfollowing"
  fi

  # The button moves before the relay does, so the read back polls for a list
  # newer than the one this run started from rather than sleeping at a number
  # and hoping.
  local after="$WORK/list-after.json"
  if ! fetch_list_after "$t0" "$after"; then
    fail "the unfollow never reached $RELAY: it is still serving the list from before this run"
    stop_app
    return
  fi
  pass "the relay is serving the list this run published"
  people "$after" >"$WORK/people-after.txt"
  local removed added
  removed="$(comm -23 "$WORK/people-before.txt" "$WORK/people-after.txt" | wc -l | tr -d ' ')"
  added="$(comm -13 "$WORK/people-before.txt" "$WORK/people-after.txt" | wc -l | tr -d ' ')"
  info "published list: $(wc -l <"$WORK/people-after.txt" | tr -d ' ') people, $removed removed, $added added"

  if [ "$removed" = "1" ] && [ "$added" = "0" ]; then
    pass "unfollowing one person removed exactly that person"
  elif [ "$removed" -gt 100 ]; then
    fail "unfollowing one person removed $removed. A list this app chose was published over a real one, or a buffer bound leaked into the write."
  else
    fail "unfollowing one person removed $removed and added $added"
  fi

  # Put it back, and confirm the account is exactly where it started.
  local t1 final="$WORK/list-final.json"
  t1="$(stamp "$after" created_at)"
  await 20000 'role=button name="Follow"' || true
  click button "Follow" || fail "could not press Follow"
  await 15000 'role=button name="Following"' || true
  if fetch_list_after "$t1" "$final"; then
    people "$final" >"$WORK/people-final.txt"
    if cmp -s "$WORK/people-before.txt" "$WORK/people-final.txt"; then
      pass "following them again restored the list exactly"
    else
      fail "the list did not come back: $(comm -23 "$WORK/people-before.txt" "$WORK/people-final.txt" | wc -l | tr -d ' ') still missing"
    fi
  else
    fail "the re-follow never reached $RELAY, so the account is one person short. Run this again."
  fi

  stop_app
}

# Frame cost under a hard scroll, which has its own script and its own budgets.
#
# Run against a home of ours like everything else here. On its own that script
# inherits whatever home it is called from, which is fine when a person runs it
# deliberately and wrong for an unattended pass that also signs accounts in and
# out. Where a key was given, the scroll happens on that account's own feed,
# which is the load that matters: a few hundred follows, not a guest's handful.
journey_frames() {
  say "Journey: the feed stays inside its frame budget"
  local home="$WORK/follows-home"
  [ -d "$home" ] || home="$WORK/frames-home"
  mkdir -p "$home"
  if (cd "$ROOT" && HOME="$home" scripts/frame-budget.sh >"$WORK/frames.log" 2>&1); then
    pass "$(grep -E 'rebuild p90' "$WORK/frames.log" | head -1 | sed 's/^ *//')"
  else
    fail "over budget. See $WORK/frames.log"
    grep -E "OVER BUDGET" "$WORK/frames.log" | head -5 >&2 || true
  fi
}

# ---------------------------------------------------------------------------

mkdir -p "$WORK"
# Resolved, because on macOS TMPDIR is under /var/folders, /var is a symlink to
# /private/var, and a launched process reports the resolved path. The bundle
# journey matched its processes by path and found none of them: not the two it
# was asserting on, and not the ones it then tried to kill, which is how a
# passing-looking run left an app of its own running afterwards.
WORK="$(cd "$WORK" && pwd -P)"
say "Working in $WORK"

want="${1:-all}"

case "$want" in
  all)      journey_guest; journey_follows; journey_frames; journey_bundle ;;
  bundle)   journey_bundle ;;
  guest)    journey_guest ;;
  follows)  journey_follows ;;
  frames)   journey_frames ;;
  *)        die "unknown journey \"$want\". Try: bundle, guest, follows, frames." ;;
esac

echo
say "$PASSED passed, $FAILED failed, $SKIPPED skipped"
if [ "$SKIPPED" -gt 0 ] && [ "$FAILED" -eq 0 ]; then
  info "A skipped journey proved nothing. Read the reason before tagging."
fi
[ "$FAILED" -eq 0 ] || exit 1

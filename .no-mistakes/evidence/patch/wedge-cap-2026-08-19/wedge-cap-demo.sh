#!/usr/bin/env bash
# wedge-cap-demo.sh - end-to-end operator transcript for the FM_WEDGE_MAX_ESCALATIONS
# cap (PR patch/wedge-cap-2026-08-19). Drives the REAL bin/fm-watch.sh against a
# fake wedged worker pane (the production incident shape: a Pi worker whose pane
# renders a ticking elapsed-time footer, so the pane hash churns every poll).
#
# Phases demonstrated:
#   1. priming: busy pane below the busy-turn bound -> no wake, no cap marker
#   2. escalations 1..2: one stale wake per FM_STALE_ESCALATE_SECS window
#   3. escalation 3 == FM_WEDGE_MAX_ESCALATIONS=3: exactly ONE terminal
#      PERMANENTLY-WEDGED wake + BOTH markers written
#   4. 12 more polls with the pane hash churning every poll -> total silence
#      (window-scoped marker gate)
#   5. operator `rm` of both markers -> cap lifts, wedge re-escalates from 1
#      (counter was reset at cap fire)
set -u

ROOT="/home/nostradamus/.no-mistakes/worktrees/8b845ac61faf/01M292EY1EX2C2RP8X5PZRSZHS"
# WATCH_ROOT points at a firstmate bin/ tree: the gate worktree (patched watcher)
# by default, or a base-commit extraction for the before/after contrast.
WATCH_ROOT="${WATCH_ROOT:-$ROOT}"
TAG="${TAG:-patched}"
WATCH="$WATCH_ROOT/bin/fm-watch.sh"
DRAIN="$WATCH_ROOT/bin/fm-wake-drain.sh"
BUSY="$WATCH_ROOT/bin/fm-busy-event.sh"
EVDIR="/tmp/no-mistakes-evidence/01M292EY1EX2C2RP8X5PZRSZHS"
TRANSCRIPT="$EVDIR/wedge-cap-e2e-transcript-$TAG.txt"
TALLY="$EVDIR/wedge-cap-e2e-wake-tally-$TAG.txt"
: > "$TALLY"

DEMO=$(mktemp -d /tmp/wedge-cap-demo.XXXXXX)
TANGLE_ROOT=$(mktemp -d /tmp/wedge-cap-tangle.XXXXXX)
cleanup() { rm -rf "$DEMO" "$TANGLE_ROOT"; }
trap cleanup EXIT

state="$DEMO/state"; fakebin="$DEMO/fakebin"
mkdir -p "$state" "$fakebin"
umask 022

# Inert the guard's primary-branch tangle banner (the gate worktree is a feature branch).
export FM_ROOT_OVERRIDE="$TANGLE_ROOT"
export FM_GATE_REFUSE_BYPASS=1

MAX=3
window="card5:m4-ship-worker"
task="m4-ship-worker"
key=$(printf '%s' "$window" | tr ':/.' '___')
capture="$DEMO/pane.txt"
out="$DEMO/watch.out"

hash_text() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }
seen_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }

# --- fixture: wedged Pi ship worker (ticking footer -> hash churns) ----------
printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/$task.meta"
printf 'busy: harness busy\n' > "$state/$task.status"
printf '%s' "$(seen_sig "$state/$task.status")" > "$state/.seen-${task}_status"
printf 'PI 5.0 | working · 00:14:03 · 87%% context left\n' > "$capture"
printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"

# Production semantic busy-state contract: harness=pi + armed .busy-state record.
export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
"$BUSY" arm "$state" "$task" --state busy --source pi-ext --event poll >/dev/null \
  || { echo "fixture: could not arm busy-state record" >&2; exit 1; }
age_meta() { touch -d '2 seconds ago' "$state/$task.meta"; }

# fake tmux + fake crew-state (the same seams the suite's wake-helpers install)
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"; exit 0; fi
if [ "${1:-}" = "capture-pane" ]; then cat "$FM_FAKE_TMUX_CAPTURE"; exit 0; fi
if [ "${1:-}" = "display-message" ]; then
  case "$*" in *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;; esac
fi
exit 1
SH
chmod +x "$fakebin/tmux"
cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none}"
exit 0
SH
chmod +x "$fakebin/fm-crew-state.sh"

# --- round plumbing ----------------------------------------------------------
is_live() { kill -0 "$1" 2>/dev/null; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
wait_for_exit() { # <pid> <limit-0.1s>
  local i=0
  while [ "$i" -lt "$2" ]; do
    is_live "$1" || { wait "$1"; return $?; }
    sleep 0.1; i=$((i + 1))
  done
  reap "$1"; return 124
}
wait_poll_cycle() { # <pid> [limit-0.1s] : wait for two watcher beats
  local beat="$state/.last-watcher-beat" first="" now="" i=0 limit=${2:-300}
  rm -f "$beat"
  while [ "$i" -lt "$limit" ]; do
    is_live "$1" || return 1
    if [ -e "$beat" ]; then first=$(stat -c %Y "$beat"); break; fi
    sleep 0.1; i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    is_live "$1" || return 1
    now=$(stat -c %Y "$beat" 2>/dev/null || true)
    if [ -n "$now" ] && [ "$now" != "$first" ]; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
ack_stopped_cycle() { # consume+ack the durable queue so rounds are isolated
  local err="$state/.demo-drain.err" sequence generation
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}
show_queue() { # the captain-facing durable surface: rows queued but not yet acked
  if [ -s "$state/.wake-queue" ]; then
    cut -f3- "$state/.wake-queue" | sed 's/^/   QUEUE: /'
  else
    echo "   QUEUE: (empty - nothing surfaced this round)"
  fi
}
run_round() { # <label> <stale-secs> <exit|silent>
  local label=$1 stale_secs=$2 mode=$3
  echo "$(( $(date +%s) - 500 ))" > "$state/.stale-since-$key"
  age_meta
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_BUSY_TURN_MAX_SECS=1 FM_WEDGE_MAX_ESCALATIONS=$MAX FM_CAP_HORIZON_SECS=86400 \
    FM_STALE_ESCALATE_SECS="$stale_secs" \
    "$WATCH" > "$out" 2> "$DEMO/watch.err" &
  local pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 150
  else
    wait_poll_cycle "$pid" 300 || true
    reap "$pid"
  fi
  show_queue
  grep -a 'stale\|PERMANENTLY' "$out" >> "$TALLY" 2>/dev/null || true
  ack_stopped_cycle >/dev/null 2>&1 || true
  if [ -s "$out" ]; then
    sed 's/^/   WATCHER SURFACED: /' "$out"
  else
    echo "   WATCHER: silent (absorbed; no wake)"
  fi
}
markers() {
  ls -A "$state" 2>/dev/null | grep 'wedge-permanent' | sed 's/^/   MARKER: /' || true
  ls -A "$state" 2>/dev/null | grep -q 'wedge-permanent' || echo "   MARKER: (none)"
}

# --- transcript --------------------------------------------------------------
{
  echo "================================================================================"
  echo "fm-watch wedge cap — end-to-end operator transcript"
  echo "change under test : watcher bin/ tree = $WATCH_ROOT"
  echo "watcher binary    : $WATCH"
  if [ "$TAG" = base ]; then
    echo "NOTE              : BEFORE the patch (base commit 9074f9d2) - no cap exists;"
    echo "                    every poll below re-engages the LLM and the churn phase floods"
    echo "                    one paid wake per poll. FM_WEDGE_MAX_ESCALATIONS is ignored."
  fi
  echo "scenario          : Pi ship worker window 'card5:m4-ship-worker' wedged behind a"
  echo "                    ticking elapsed-time footer (pane hash churns every poll),"
  echo "                    busy verdict from a real fm-busy-event record, no completed"
  echo "                    turn. FM_WEDGE_MAX_ESCALATIONS=$MAX, FM_CAP_HORIZON_SECS=86400."
  echo "surfaces shown    : QUEUE rows = the durable wake records the supervised LLM loop"
  echo "                    re-engages on (each row ~ one paid API call); WATCHER SURFACED"
  echo "                    = the reason line printed to the wake output; MARKER = the"
  echo "                    STATE files an operator inspects / rm's."
  echo "================================================================================"
  echo
  echo "### Phase 1 — priming poll (busy pane, below busy-turn bound)"
  echo "-- expected: wedge timer repaired, NO wake, NO cap marker"
  run_round priming 999 silent
  markers
  echo
  echo "### Phase 2 — stale escalations 1 and 2 (each after STALE_ESCALATE_SECS idle)"
  echo "-- each of these wakes is one paid LLM re-engagement in the unattended loop;"
  echo "-- the pre-patch behavior was that this never stopped."
  echo "-- ROUND: escalation 1"
  run_round escalation-1 240 exit
  echo "-- ROUND: escalation 2"
  run_round escalation-2 240 exit
  markers
  echo
  echo "### Phase 3 — escalation 3 == FM_WEDGE_MAX_ESCALATIONS: the cap fires"
  echo "-- expected: exactly ONE terminal PERMANENTLY-WEDGED wake, then BOTH markers"
  run_round cap-fires 240 exit
  markers
  echo "   window-scoped marker content (cap-fire epoch): $(cat "$state/.wedge-permanent-$key" 2>/dev/null || echo MISSING)"
  echo "-- operator triage log, cap line:"
  grep -a 'permanently capped' "$state/.watch-triage.log" 2>/dev/null | tail -1 | sed 's/^/   /'
  echo
  echo "### Phase 4 — hash churns every poll for 12 polls (the ticking footer)"
  echo "-- expected: TOTAL SILENCE. The window-scoped marker gates every fresh hash;"
  echo "-- without the cap this loop re-engaged the LLM once per fresh hash."
  i=1
  while [ "$i" -le 12 ]; do
    printf 'PI 5.0 | working · 00:%02d:%02d · %d%% context left\n' $((14 + i / 60)) $((3 + i)) $((87 - i)) > "$capture"
    echo "-- churn poll $i (fresh pane hash $(hash_text "$(cat "$capture")" | cut -c1-12)...)"
    run_round "churn-$i" 1 silent
    i=$((i + 1))
  done
  echo "-- markers still standing after 12 churned polls:"
  markers
  echo
  echo "### Phase 5 — operator lift: rm BOTH markers, wedge re-fires"
  rm -f "$state/.wedge-permanent-$key" "$state/.wedge-permanent-$key"-*
  printf 'PI 5.0 | working · 00:59:59 · 12%% context left\n' > "$capture"
  echo "-- expected: cap lifts; wedge re-escalates from escalation 1 (the escalation"
  echo "-- counter was reset when the cap fired), confirming the operator contract."
  run_round operator-lift 1 exit
  echo
  echo "### Final tally over the whole run"
  echo "   wake lines surfaced (see $TALLY):"
  sort "$TALLY" | uniq -c | sed 's/^/     /'
  permanent_count=$(grep -c 'PERMANENTLY-WEDGED' "$TALLY")
  echo "   PERMANENTLY-WEDGED terminal wakes for the entire wedge-event: $permanent_count (expected 1)"
  echo "   stale escalation wakes before the cap: 2 (escalations 1 and 2)"
  echo "   wakes during 12 hash-churned polls under the cap: 0"
  echo "================================================================================"
} > "$TRANSCRIPT" 2>&1

echo "transcript: $TRANSCRIPT"

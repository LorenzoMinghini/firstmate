#!/usr/bin/env bash
# Adversarial live proof for the FM_WEDGE_MAX_ESCALATIONS cap (bin/fm-watch.sh).
#
# Usage: wedge-cap-adversarial-live.sh <path-to-worktree>
#
# Drives the REAL watcher (the worktree's bin/fm-watch.sh) against a REAL tmux
# server on a lab-private socket inside a disposable lab home minted by the
# repository's own bin/fm-lab-home.sh. Nothing here stubs tmux, the crew-state
# verdict, or the watcher: the fixture is a real process in a real pane whose
# text re-renders every second while making no progress - the shape of the pane
# that produced the unbounded escalation train.
#
# Arms, in order, on the SAME pane/window with the SAME thresholds:
#   A. control, cap OFF (FM_WEDGE_MAX_ESCALATIONS=0, the shipped default):
#      the re-rendering wedge must escalate on nearly every poll. This is the
#      oracle that makes the silence in arms B/C attributable to the cap
#      setting rather than to the fixture shape.
#   B. cap ON: one terminal PERMANENTLY-WEDGED wake at the bound, and the
#      window-scoped state/.wedge-permanent-<key> marker on disk.
#   C. adversarial: after the cap fired, MORE polls of the still-wedged,
#      still-re-rendering pane must publish nothing at all and must not advance
#      the escalation counter. This is the loop the cap exists to stop: a
#      hash-scoped ceiling would let a pane that re-renders every poll rebuild
#      its counter on a fresh hash and keep firing.
#   D. operator escape hatch: rm state/.wedge-permanent-<key> inside the
#      horizon must re-open the window on the next poll.
#   E. adversarial, detection not silenced: with the cap fired again, the agent
#      process is replaced by a plain shell - the endpoint is present but has no
#      agent running in it. A capped poll must still report that dead endpoint
#      exactly once, and must not escalate it as a wedge.
#   F. release on genuine recovery: a fresh completed turn takes the pane off the
#      stale path and must clear the window-scoped cap marker.
#
# Observable result per cycle: the watcher's published reason line on stdout and
# the durable wake rows it appended to the lab home's .wake-queue, plus the
# per-window state markers in the lab state dir.
set -u

ROOT=${1:?usage: wedge-cap-adversarial-live.sh <path-to-worktree>}
ROOT=$(cd "$ROOT" && pwd)
WATCH="$ROOT/bin/fm-watch.sh"
LAB_BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-wedge-cap-adv.XXXXXX")
LAB_HOME="$LAB_BASE/lab-home"
LAB_SOCKET=''

say() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$1"; }
cleanup() {
  if [ -n "$LAB_SOCKET" ]; then tmux -S "$LAB_SOCKET" kill-server >/dev/null 2>&1 || true; fi
  if [ -n "$LAB_HOME" ] && [ -d "$LAB_HOME" ]; then
    "$ROOT/bin/fm-lab-home.sh" teardown "$LAB_HOME" >/dev/null 2>&1 || true
  fi
  [ -n "${LAB_BASE:-}" ] && [ -d "$LAB_BASE" ] && rm -rf "$LAB_BASE"
  return 0
}
fail() { printf 'FAIL: %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

say "adversarial live run against $WATCH"

# --- disposable lab home + private tmux socket (repo's own mechanism) --------
"$ROOT/bin/fm-lab-home.sh" create "$LAB_HOME" >/dev/null || fail "could not mint a lab home"
LAB_TMUX_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB_HOME") || fail "could not mint a tmux socket dir"
export TMUX_TMPDIR="$LAB_TMUX_DIR"
LAB_SOCKET="$TMUX_TMPDIR/tmux-$(id -u)/default"
mkdir -p "$(dirname "$LAB_SOCKET")" && chmod 700 "$(dirname "$LAB_SOCKET")"
STATE="$LAB_HOME/state"
QUEUE="$STATE/.wake-queue"
TASK=wedged-worker
WINDOW_NAME=wedged
SESSION=wedge-adv
WINDOW="$SESSION:$WINDOW_NAME"
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')

# --- the fixture: a real process in a real pane, re-rendering, no progress ---
# The pane's foreground process is a copy of the system shell named so the
# repository's own liveness classifier reads it as a harness agent (the same
# stand-in the repository's live guard uses with its wedged-claude script); it
# is NOT the Claude CLI and no Claude-path claim is made here. It waits with a
# bash-internal timed read, so the foreground process group never has a gap in
# which only the shell is visible - the liveness read stays `alive` throughout.
TMP_ROOT="$LAB_BASE"
cp /bin/bash "$TMP_ROOT/claude-fixture"
AGENT_BIN="$TMP_ROOT/churn-claude"
cat > "$AGENT_BIN" <<AGENT
#!$TMP_ROOT/claude-fixture
# A wedged worker whose pane keeps re-rendering: alive, occupying the pane,
# making no progress, a new frame every second.
while :; do
  printf 'claude> working (elapsed 00:00:01) frame %s\n' "\$(date +%s%N)"
  read -r -t 1 -u 0 _ || true
done
AGENT
chmod +x "$AGENT_BIN"
tmux -S "$LAB_SOCKET" new-session -d -s "$SESSION" -n "$WINDOW_NAME" "$AGENT_BIN" >/dev/null 2>&1 \
  || fail "could not start a tmux server on the lab-private socket"

# Record the window the way firstmate records a spawned crew.
cat > "$STATE/$TASK.meta" <<META
window=$WINDOW
backend=tmux
harness=claude
kind=ship
META
printf 'working: implementing\n' > "$STATE/$TASK.status"
FM_HOME="$LAB_HOME" bash -c 'cd "$1"; . bin/fm-classify-lib.sh; . bin/fm-wake-lib.sh; fm_wake_status_mark_current "$2" "$3"' \
  _ "$ROOT" "$STATE" "$STATE/$TASK.status" >/dev/null 2>&1 \
  || say "note: could not pre-mark the status log as seen (the first poll may publish one status-signal wake, drained after every cycle)"
# Arm the busy record the production path reads: an agent mid-turn that never
# finished, so the pane crosses the completed-turn bound at once and is routed
# through the wedge timer the cap bounds.
printf 'g1\n' > "$STATE/$TASK.busy-gen"
printf 'v1 gen=g1 seq=1 state=busy source=fm-spawn event=turn_start ts=%s\n' "$(date +%s)" \
  > "$STATE/$TASK.busy-state"
touch -d '30 seconds ago' "$STATE/$TASK.meta"

MAX=0
STALE_SECS=2
HORIZON_SECS=3600
CYCLE_BOUND=10
cycle=0
CYCLE_WOKE=0
CYCLE_REASON=''
CYCLE_ROWS=''

reset_window() {
  rm -f "$STATE"/.wedge-permanent-* "$STATE"/.wedge-rollback-failed-* \
    "$STATE"/.wedge-terminal-queued-* "$STATE"/.wedge-escalations-* \
    "$STATE"/.stale-since-* "$STATE"/.stale-* "$STATE"/.count-* "$STATE"/.hash-* \
    "$STATE"/.dead-reported-* "$STATE"/.last-watcher-beat
  touch -d '30 seconds ago' "$STATE/$TASK.meta"
  : > "$QUEUE" 2>/dev/null || true
  FM_HOME="$LAB_HOME" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
}

marker_state() { if [ -e "$STATE/.wedge-permanent-$KEY" ]; then printf 'present'; else printf 'absent'; fi; }
counter_state() { local v; v=$(cat "$STATE/.wedge-escalations-$KEY" 2>/dev/null | tr -d '\n'); if [ -n "$v" ]; then printf '%s' "$v"; else printf 'empty'; fi; }

# cycle <label>: one real watcher cycle. Records the published reason line, the
# durable wake rows this cycle appended, and the window's cap state afterwards.
cycle() {
  local label=$1 out rc beat i rows_before rows_after nrows
  cycle=$((cycle + 1))
  out="$TMP_ROOT/cycle-$cycle.out"
  rm -f "$STATE/.last-watcher-beat"
  rows_before=$( [ -f "$QUEUE" ] && wc -l < "$QUEUE" | tr -d ' ' || printf '0' )
  FM_HOME="$LAB_HOME" TMUX_TMPDIR="$LAB_TMUX_DIR" \
    FM_WEDGE_MAX_ESCALATIONS="$MAX" FM_CAP_HORIZON_SECS="$HORIZON_SECS" \
    FM_STALE_ESCALATE_SECS="$STALE_SECS" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_BUSY_TURN_MAX_SECS=1 \
    "$WATCH" > "$out" 2>&1 &
  local pid=$!
  beat="$STATE/.last-watcher-beat"
  i=0
  while [ "$i" -lt 300 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ -s "$beat" ] && break
    sleep 0.1
    i=$((i + 1 ))
  done
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt $(( CYCLE_BOUND * 10 )) ]; do
    sleep 0.1
    i=$(( i + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rc=alive
  else
    wait "$pid" 2>/dev/null
    rc=$?
  fi
  rows_after=$( [ -f "$QUEUE" ] && wc -l < "$QUEUE" | tr -d ' ' || printf '0' )
  if [ -f "$QUEUE" ] && [ "$rows_after" -gt "$rows_before" ]; then
    CYCLE_ROWS=$(tail -n "+$(( rows_before + 1 ))" "$QUEUE")
  else
    CYCLE_ROWS=''
  fi
  nrows=0
  [ -n "$CYCLE_ROWS" ] && nrows=$(printf '%s\n' "$CYCLE_ROWS" | grep -c . || true)
  CYCLE_REASON=$(head -1 "$out" 2>/dev/null)
  case "$CYCLE_REASON" in '') CYCLE_WOKE=0 ;; *) CYCLE_WOKE=1 ;; esac
  say "$label -> exit=$rc woke=$CYCLE_WOKE queue_rows=$nrows counter=$(counter_state) marker=$(marker_state)"
  say "    reason: ${CYCLE_REASON:-none}"
  if [ -n "$CYCLE_ROWS" ]; then
    printf '%s\n' "$CYCLE_ROWS" | cut -f5 | sed 's/^/    queued: /'
  fi
  # Consume what the watcher handed out, the way a supervisor does once it has
  # acted on a wake: the row leaves the durable queue. The cap's duplicate
  # suppression reads that queue (an unacknowledged terminal row still in it
  # suppresses a second one), so leaving rows behind here would model an
  # operator who never acted rather than one who did.
  : > "$QUEUE" 2>/dev/null || true
  FM_HOME="$LAB_HOME" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
}

say "fixture: real pane $WINDOW running a process whose name classifies as an agent, re-rendering every second, busy record armed; thresholds stale=${STALE_SECS}s horizon=${HORIZON_SECS}s cap=$MAX"

# --- A. control arm: the cap OFF (the shipped default) ---------------------
say "A. CONTROL: FM_WEDGE_MAX_ESCALATIONS=0 (the shipped default) on the re-rendering pane"
reset_window
MAX=0
cycle "control prime (wedge timer armed, nothing due yet)"
control_wakes=0
i=1
while [ "$i" -le 4 ]; do
  cycle "control cycle $i"
  if printf '%s' "$CYCLE_REASON" | grep -q 'possible wedge'; then
    control_wakes=$(( control_wakes + 1 ))
  else
    say "    note: control cycle $i did not publish a wedge escalation"
  fi
  i=$(( i + 1 ))
done
[ "$control_wakes" -ge 3 ] \
  || fail "the cap-off control wedge-escalated only $control_wakes times in 4 polls of a re-rendering wedge, so the fixture is not exercising the ladder and later silence proves nothing"
[ "$(marker_state)" = absent ] || fail "a cap marker exists with the cap OFF"
say "A. control: $control_wakes/4 polls of a re-rendering wedge escalated with the cap at its default, and no cap marker was written"

# --- B. the cap engages ---------------------------------------------------
say "B. CAP ON at 2: the same pane must get exactly one terminal PERMANENTLY-WEDGED wake"
reset_window
MAX=2
cycle "capped prime (wedge timer armed, nothing due yet)"
terminal=0
i=1
while [ "$i" -le 4 ]; do
  cycle "capped cycle $i"
  if printf '%s' "$CYCLE_REASON" | grep -q 'PERMANENTLY-WEDGED'; then terminal=$(( terminal + 1 )); break; fi
  i=$(( i + 1 ))
done
[ "$terminal" -eq 1 ] || fail "the cap did not fire exactly once within 4 capped polls (fired $terminal times)"
[ "$(marker_state)" = present ] || fail "the cap fired but wrote no window-scoped marker"
say "B. the cap fired once at the bound and wrote state/.wedge-permanent-$KEY"

# --- C. adversarial: the re-rendering pane must go quiet ------------------
say "C. ADVERSARIAL: more polls of the still-wedged, still-re-rendering pane under the fired cap"
quiet=0
i=1
while [ "$i" -le 4 ]; do
  cycle "post-cap churn poll $i"
  [ "$CYCLE_WOKE" -eq 0 ] || fail "post-cap churn poll $i published a wake: the cap is not silencing a pane that re-renders every poll"
  [ "$(counter_state)" = empty ] || fail "post-cap churn poll $i advanced the escalation counter ($(counter_state)): the marker is not holding the ceiling"
  [ "$(marker_state)" = present ] || fail "post-cap churn poll $i lost the cap marker mid-horizon"
  quiet=$(( quiet + 1 ))
  i=$(( i + 1 ))
done
say "C. $quiet/4 polls of a pane that re-rendered on every one of them published nothing and advanced no counter"

# --- D. the documented operator escape hatch ------------------------------
say "D. operator escape hatch: rm the window-scoped cap marker inside the horizon"
rm -f "$STATE/.wedge-permanent-$KEY"
cycle "first poll after the cap marker was removed"
printf '%s' "$CYCLE_REASON" | grep -q 'possible wedge' \
  || fail "removing the cap marker did not re-open the window with an ordinary escalation on the next poll: ${CYCLE_REASON:-none}"
printf '%s' "$CYCLE_REASON" | grep -q 'PERMANENTLY-WEDGED' \
  && fail "the first post-rm poll re-fired the terminal wake instead of an ordinary escalation"
say "D. the window is audible again on the very next poll after the marker was removed"

# --- E. adversarial: a capped window must still report a dead endpoint ----
say "E. ADVERSARIAL: with the cap fired again, the agent process is replaced by a plain shell"
refire=0
i=1
while [ "$i" -le 4 ]; do
  cycle "re-fire cycle $i"
  if printf '%s' "$CYCLE_REASON" | grep -q 'PERMANENTLY-WEDGED'; then refire=$(( refire + 1 )); break; fi
  i=$(( i + 1 ))
done
[ "$refire" -ge 1 ] || fail "the cap never re-fired after the operator escape hatch"
[ "$(marker_state)" = present ] || fail "no cap marker after the re-fire"
tmux -S "$LAB_SOCKET" respawn-pane -k -t "$WINDOW" "bash --norc" >/dev/null 2>&1 \
  || fail "could not replace the pane's process with a plain shell"
sleep 1
cycle "capped poll with the endpoint present but running no agent"
[ "$CYCLE_WOKE" -eq 1 ] || fail "a capped poll published nothing while the pane had no agent running in it: the cap silenced detection"
printf '%s' "$CYCLE_ROWS" | grep -q 'agent dead' \
  || fail "the capped poll did not report the agentless endpoint: ${CYCLE_REASON:-none}"
if printf '%s' "$CYCLE_REASON" | grep -q 'possible wedge'; then
  fail "the agentless endpoint was escalated as a wedge instead of reported"
fi
say "E. the capped window reported the dead endpoint once"
i=1
while [ "$i" -le 2 ]; do
  cycle "repeat capped poll $i"
  [ "$CYCLE_WOKE" -eq 0 ] || fail "repeat capped poll $i repeated the dead-endpoint report or re-fired the terminal wake"
  [ "$(marker_state)" = present ] || fail "repeat capped poll $i lost the cap marker"
  i=$(( i + 1 ))
done
say "E. two further capped polls repeated nothing and kept the cap marker"

# --- F. release on genuine recovery ---------------------------------------
say "F. the crew completes its turn: the pane leaves the stale path"
touch "$STATE/$TASK.turn-ended"
cycle "poll after the completed turn"
[ "$(marker_state)" = absent ] \
  || fail "the window-scoped cap marker survived the pane leaving the stale path"
say "F. the cap marker was released when the worker resumed"

say "SUMMARY: control cap-off escalated $control_wakes/4 polls of a re-rendering wedge; capped, one terminal wake then $quiet/4 silent polls; operator rm re-opened it; a capped window still reported its dead endpoint once; the marker released on recovery"
say "adversarial live run complete"
cleanup
trap - EXIT
exit 0
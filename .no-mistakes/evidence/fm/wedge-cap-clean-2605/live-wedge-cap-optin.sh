#!/usr/bin/env bash
# live-wedge-cap-optin.sh - LIVE proof for the wedge escalation-counter reset
# opt-in (branch fm/wedge-cap-clean-2605, commit d9f0f90).
#
# What it drives: the REAL bin/fm-watch.sh (and, for the oracle, upstream
# main's own bin/fm-watch.sh materialised from git) against a REAL tmux server
# on a lab-private socket, holding a REAL process in a REAL pane, inside a
# disposable lab home minted by the repository's own bin/fm-lab-home.sh. No
# stub of the watcher, no stub of tmux, no recorded fixture.
#
# The scenario, one wedged pane:
#   rung 1   the pane is busy and its turn bound is crossed -> escalation 1
#   rung 2   the same, still wedged                      -> escalation 2
#   surface  the pane goes idle for one poll: the FIRST-SIGHT stale surface
#            fires (a plain stale wake, no escalation count) and the episode
#            ends. What happens to the escalation COUNT here is the whole
#            change.
#   rung 3   the pane wedges again -> escalation 3, which is the rung that
#            carries the demand-deep-inspection prompt.
#   rung 4   the same -> escalation 4.
#
# The oracle for "today's behaviour" is upstream main's own watcher, driven
# through the same harness on the same pane: upstream is what an unconfigured
# home ran before this branch, so upstream's trace IS today's behaviour.
#
# Arms:
#   A  branch, cap unset        -> must equal upstream's trace (ladder 1,2,3,4,
#                                  demand-deep-inspection at 3, no cap marker)
#   B  upstream main, cap unset -> the oracle trace
#   C  branch, cap = 3          -> the count resets at the surface, so the
#                                  re-wedge starts at 1 again and the cap fires
#                                  PERMANENTLY-WEDGED at 3 (the opt-in half)
#   D  branch, cap = 99999999999999999999 (a value bash cannot compare)
#                               -> must equal arm A exactly: an unusable value
#                                  is an invalid one, so the home reads as
#                                  unconfigured, keeps today's ladder, and never
#                                  engages the cap
set -u

ROOT=~/.no-mistakes/worktrees/8b845ac61faf/01M5F1PTQH43K09NV8Y43HNXKS
EVID=~/.no-mistakes/evidence/01M5F1PTQH43K09NV8Y43HNXKS
TRANSCRIPT="$EVID/wedge-cap-optin-live-transcript.txt"
BRANCH_WATCH="$ROOT/bin/fm-watch.sh"

LAB=
LAB_TMUX_DIR=
SOCKET=
SESSION=
WINDOW=
KEY=
TASK=wedged-worker
STATE=
GEN=
PANE_TEXT='claude> working (elapsed 00:00:01)'

# The live thresholds. The production values are a four-minute stale bound and
# a day-long cap horizon; no test budget can spend those, and shrinking them
# exercises the identical code path.
STALE_SECS=2
ROUND_BOUND=90

: > "$TRANSCRIPT"

# say writes to the transcript file and to stderr, never to stdout: the arm
# runner's stdout is captured by a command substitution, and a transcript line
# landing in a captured trace would corrupt the trace it is describing.
say() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$TRANSCRIPT" >&2
}

cleanup() {
  if [ -n "$SOCKET" ]; then
    tmux -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  fi
  if [ -n "$LAB" ]; then
    "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
    rm -rf "$LAB"
  fi
}
trap cleanup EXIT

fail() { say "FAIL: $1"; exit 1; }

# pane_hash: the watcher's own pane hash, computed the way bin/fm-watch.sh
# computes it (hash_pane over the same bounded capture), so the seeded first
# sight is the one the watcher will recognise.
pane_hash() {
  local tail40
  tail40=$(tmux capture-pane -p -t "$WINDOW" -S -40 2>/dev/null)
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$tail40" | md5 -q
  else
    printf '%s' "$tail40" | md5sum | cut -d' ' -f1
  fi
}

# ---------------------------------------------------------------- setup ------

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || fail "could not mint a lab dir"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || fail "fm-lab-home.sh could not mint a lab home at $LAB"
LAB_TMUX_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || fail "fm-lab-home.sh could not mint a tmux socket dir"
export TMUX_TMPDIR="$LAB_TMUX_DIR"
SOCKET="$TMUX_TMPDIR/tmux-$(id -u)/default"
mkdir -p "$(dirname "$SOCKET")" || fail "could not create $LAB_TMUX_DIR/tmux-$(id -u)"
chmod 700 "$(dirname "$SOCKET")" || fail "could not make the lab tmux socket dir private"
STATE="$LAB/state"
say "lab home $LAB; tmux socket $SOCKET; watcher tree $ROOT"

# The wedged worker: a real, live process whose command name the backend's own
# agent classifier reads as a coding agent, sitting there making no progress.
AGENT_BIN="$LAB/wedged-claude"
cat > "$AGENT_BIN" <<'AGENT'
#!/usr/bin/env bash
printf 'claude> working (elapsed 00:00:01)\n'
sleep 2147483647
AGENT
chmod +x "$AGENT_BIN"

tmux -S "$SOCKET" new-session -d -s wedgelab -n pane "$AGENT_BIN" >/dev/null 2>&1 \
  || fail "could not start a tmux server on the lab-private socket"
SESSION=$(tmux -S "$SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | head -1)
[ -n "$SESSION" ] || fail "the lab tmux server started but listed no session"
WINDOW="$SESSION:pane"
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
say "real tmux pane $WINDOW holds a real process that has made no progress (key=$KEY)"

cat > "$STATE/$TASK.meta" <<META
window=$WINDOW
backend=tmux
harness=claude
kind=ship
META
# A non-terminal status line: the crew said it was working and then went quiet.
printf 'working: implementing\n' > "$STATE/$TASK.status"
# Prime the signal scan through the production signature owner so the status
# line is not a pending signal and every cycle of this run is a PANE cycle.
FM_HOME="$LAB" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$STATE/$TASK.status" \
  || fail "could not prime the status signal scan"
say "status signal scan primed through fm_wake_status_mark_current"

# The busy record, written through the production writer (bin/fm-busy-event.sh
# is the only writer of the semantic busy-state contract).
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$TASK" --state busy --source fm-spawn --event launch-brief) \
  || fail "could not arm the busy record"
say "busy record armed (gen=$GEN) through bin/fm-busy-event.sh"

# The crew-state verdict the watcher's own triage reads, captured for the
# transcript so the route each round took is visible rather than inferred.
CREW_STATE=$(FM_HOME="$LAB" timeout 60 "$ROOT/bin/fm-crew-state.sh" "$TASK" 2>&1 | head -1)
say "crew state for the wedged crew: ${CREW_STATE:-<none>}"

flip_busy() { # busy|idle
  "$ROOT/bin/fm-busy-event.sh" apply "$STATE" "$TASK" "$1" --gen "$GEN" \
    --source fm-spawn --event "agent-$1" >/dev/null \
    || fail "could not flip the busy record to $1"
}

# reset_markers: put the window back to a fresh first sight, so every arm
# starts from the same state the previous arm started from.
reset_markers() {
  rm -f "$STATE"/.stale-since-* "$STATE"/.stale-* "$STATE"/.count-* \
        "$STATE"/.hash-* "$STATE"/.wedge-escalations-* "$STATE"/.wedge-permanent-* \
        "$STATE"/.wedge-terminal-queued-* "$STATE"/.wedge-rollback-failed-* \
        "$STATE"/.paused-* "$STATE"/.writing-* "$STATE"/.waiting-* 2>/dev/null || true
  pane_hash > "$STATE/.hash-$KEY"
  printf '1\n' > "$STATE/.count-$KEY"
  touch -d '5 seconds ago' "$STATE/$TASK.meta"
}

# run_round <label> <watcher> [ENV=VAL ...]: one real watcher cycle against the
# real pane, in the lab home. The watcher exits on the wake it publishes, so a
# round IS one published wake (or one silent cycle).
run_round() {
  local label=$1 watcher=$2
  shift 2
  local out="$LAB/round-$label.out"
  : > "$out"
  rm -f "$STATE/.last-watcher-beat"
  local started ended
  started=$(date +%s)
  env FM_HOME="$LAB" TMUX_TMPDIR="$LAB_TMUX_DIR" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS="$STALE_SECS" FM_BUSY_TURN_MAX_SECS=1 \
    "$@" bash "$watcher" > "$out" 2>&1 &
  local pid=$!
  local i=0 beats=0 lastbeat= rc=alive
  while [ "$i" -lt $(( ROUND_BOUND * 5 )) ]; do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    # The watcher touches the liveness beacon at the end of every poll cycle,
    # so a rising count is proof it is polling and not waking.
    local b
    b=$(stat -c %Y "$STATE/.last-watcher-beat" 2>/dev/null || echo 0)
    if [ "$b" != "$lastbeat" ] && [ "$b" != 0 ]; then
      lastbeat=$b
      beats=$((beats + 1))
    fi
    # A cycle that reached six polls without a published wake is a silent
    # cycle: stop it and record it as silent. Six polls, not three: the wedge
    # timer is planted on the first poll and the escalation that follows needs
    # the age to cross STALE_ESCALATE_SECS, so the third poll is the one that
    # escalates. Stopping earlier would kill the round before it could.
    if [ "$beats" -ge 6 ] && [ ! -s "$out" ]; then break; fi
    sleep 0.2
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  else
    wait "$pid" 2>/dev/null
    rc=$?
  fi
  ended=$(date +%s)
  local esc inspect capped counter reason
  esc=$(sed -n 's/.*escalation \([0-9][0-9]*\).*/\1/p' "$out" | tail -1)
  [ -n "$esc" ] || esc=-
  if grep -F 'demand-deep-inspection' "$out" >/dev/null; then inspect=1; else inspect=0; fi
  if grep -F 'PERMANENTLY-WEDGED' "$out" >/dev/null; then capped=1; else capped=0; fi
  counter=$(cat "$STATE/.wedge-escalations-$KEY" 2>/dev/null || true)
  case "$counter" in ''|*[!0-9]*) counter=- ;; esac
  reason=$(grep -m1 -E '^(stale|signal|check):' "$out" 2>/dev/null || true)
  say "$label rc=$rc esc=$esc inspect=$inspect capped=$capped counter=$counter secs=$((ended - started)) reason=${reason:-none}"
  # Drain the queue so the next round starts from an empty one.
  FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
  printf '%s esc=%s inspect=%s capped=%s counter=%s\n' "$label" "$esc" "$inspect" "$capped" "$counter"
}

# arm_scenario <arm-name> <watcher> [ENV=VAL ...]: the rounds of the scenario,
# each on the same real pane, with the busy record flipped between the second
# rung and the surface. The trace file holds the ROUND lines only - the arm
# name goes to the transcript - so two arms' traces can be compared byte for
# byte without the labels getting in the way.
arm_scenario() {
  local arm=$1 watcher=$2
  shift 2
  local trace="$LAB/trace-$arm"
  : > "$trace"
  say "--- arm $arm: $(basename "$(dirname "$watcher")")/${FM_WEDGE_MAX_ESCALATIONS:+cap=$FM_WEDGE_MAX_ESCALATIONS} ---"
  reset_markers
  flip_busy busy
  run_round rung1 "$watcher" "$@" >> "$trace"
  run_round rung2 "$watcher" "$@" >> "$trace"
  # The pane goes idle for one poll: the first-sight stale SURFACE fires and
  # the episode ends.
  flip_busy idle
  run_round surface "$watcher" "$@" >> "$trace"
  # The pane wedges again on the same frame.
  flip_busy busy
  run_round rung3 "$watcher" "$@" >> "$trace"
  run_round rung4 "$watcher" "$@" >> "$trace"
  run_round rung5 "$watcher" "$@" >> "$trace"
  local marker=0
  [ -e "$STATE/.wedge-permanent-$KEY" ] && marker=1
  say "arm $arm final marker=$marker"
  printf 'final marker=%s\n' "$marker" >> "$trace"
  printf '%s\n' "$trace"
}

# ------------------------------------------------------------------ arms -----

say "=== arm B: upstream main's own watcher, cap unset (the oracle: today's behaviour) ==="
UPSTREAM="$LAB/upstream-main"
mkdir -p "$UPSTREAM"
git -C "$ROOT" archive origin/main bin | tar -x -C "$UPSTREAM" \
  || fail "could not materialise upstream main's bin/ tree"
[ -x "$UPSTREAM/bin/fm-watch.sh" ] || fail "upstream main's watcher is missing from the materialised tree"
say "upstream main watcher: $UPSTREAM/bin/fm-watch.sh ($(git -C "$ROOT" rev-parse --short origin/main))"
TRACE_B=$(arm_scenario upstream "$UPSTREAM/bin/fm-watch.sh")

say "=== arm A: this branch's watcher, cap unset (the maintainer's ask) ==="
TRACE_A=$(arm_scenario branch-unset "$BRANCH_WATCH")

say "=== arm C: this branch's watcher, cap configured at 3 (the opt-in half) ==="
TRACE_C=$(arm_scenario branch-cap3 "$BRANCH_WATCH" FM_WEDGE_MAX_ESCALATIONS=3)

say "=== arm D: this branch's watcher, cap = a value bash cannot compare ==="
TRACE_D=$(arm_scenario branch-outofrange "$BRANCH_WATCH" FM_WEDGE_MAX_ESCALATIONS=99999999999999999999)

# ------------------------------------------------------------- verdicts ------

verdict=0
report() { # <ok?> <text>
  if [ "$1" = 0 ]; then say "PASS: $2"; else say "FAIL: $2"; verdict=1; fi
}

# A must equal B byte for byte: an unconfigured home must behave exactly as
# upstream main behaves.
if diff -u "$TRACE_B" "$TRACE_A" > "$LAB/diff-A-B.txt"; then
  report 0 "arm A (branch, cap unset) is byte-identical to arm B (upstream main, cap unset): an unconfigured home keeps today's behaviour"
else
  report 1 "arm A diverged from upstream main:
$(cat "$LAB/diff-A-B.txt")"
fi

# The specific property the maintainer named: the deep-inspection prompt is
# still delivered on the same rung, and the ladder still keeps climbing.
grep -F 'rung3 esc=3 inspect=1 capped=0' "$TRACE_A" >/dev/null \
  || report 1 "arm A did not reach escalation 3 with demand-deep-inspection: $(cat "$TRACE_A")"
grep -F 'rung4 esc=4 inspect=1 capped=0' "$TRACE_A" >/dev/null \
  || report 1 "arm A did not continue the ladder to escalation 4: $(cat "$TRACE_A")"
grep -F 'rung5 esc=5 inspect=1 capped=0' "$TRACE_A" >/dev/null \
  || report 1 "arm A did not continue the ladder to escalation 5: $(cat "$TRACE_A")"
grep -F 'final marker=0' "$TRACE_A" >/dev/null \
  || report 1 "arm A wrote a cap marker on an unconfigured home: $(cat "$TRACE_A")"
grep -F 'capped=1' "$TRACE_A" >/dev/null \
  && report 1 "arm A fired PERMANENTLY-WEDGED on an unconfigured home: $(cat "$TRACE_A")"
# The count must have survived the surface (the keep-count contract).
grep -F 'surface esc=- inspect=0 capped=0 counter=2' "$TRACE_A" >/dev/null \
  || report 1 "arm A's surface did not leave the escalation count standing at 2: $(cat "$TRACE_A")"

# C: with a cap configured the count resets at the surface, so the re-wedge
# starts at 1 again, and the cap fires at its own threshold.
grep -F 'surface esc=- inspect=0 capped=0 counter=-' "$TRACE_C" >/dev/null \
  || report 1 "arm C's surface did not reset the escalation count under a configured cap: $(cat "$TRACE_C")"
grep -F 'rung3 esc=1 inspect=0 capped=0' "$TRACE_C" >/dev/null \
  || report 1 "arm C's re-wedge did not restart the ladder at escalation 1 under a configured cap: $(cat "$TRACE_C")"
grep -F 'rung5 esc=3 inspect=1 capped=1' "$TRACE_C" >/dev/null \
  || report 1 "arm C never fired PERMANENTLY-WEDGED at its configured threshold of 3: $(cat "$TRACE_C")"
grep -F 'final marker=1' "$TRACE_C" >/dev/null \
  || report 1 "arm C left no window-scoped cap marker standing: $(cat "$TRACE_C")"

# D: a value bash cannot compare is an invalid value, so the home reads as
# unconfigured and behaves exactly like arm A.
if diff -u "$TRACE_A" "$TRACE_D" > "$LAB/diff-A-D.txt"; then
  report 0 "arm D (cap = 99999999999999999999) is byte-identical to arm A (cap unset): an unusable cap value is read as an invalid one, so the home keeps today's behaviour and the cap never engages"
else
  report 1 "arm D diverged from arm A:
$(cat "$LAB/diff-A-D.txt")"
fi

say ""
say "----- traces -----"
for t in "$TRACE_A" "$TRACE_B" "$TRACE_C" "$TRACE_D"; do
  say "--- $t ---"
  cat "$t"
done
say "----- end traces -----"

if [ "$verdict" -eq 0 ]; then
  say "LIVE RESULT: all arms behaved as required"
else
  say "LIVE RESULT: at least one arm did not behave as required"
fi
exit "$verdict"

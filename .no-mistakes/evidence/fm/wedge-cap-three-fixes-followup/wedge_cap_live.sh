#!/usr/bin/env bash
# wedge_cap_live.sh - drive the REAL bin/fm-watch.sh against a REAL wedged tmux
# pane on a private socket, inside a disposable firstmate lab home.
#
# What is real here: bin/fm-watch.sh itself, bin/backends/tmux.sh reading a real
# tmux server's real pane captures, the lab state dir, the durable wake queue,
# the operator triage log, and the wake queue's TSV rows.
#
# What is supplied, both through the product's own seams:
#   * FM_CREW_STATE_BIN - the crew-state seam every watcher suite in this repo
#     uses. The responder reports a crew whose no-mistakes pipeline is running
#     while its pane renders nothing: exactly the population this cap exists
#     for, and the only shape that reaches the wedge ladder at all (an idle pane
#     that is not busy and is provably working).
#   * fault_once.so - a one-shot filesystem write fault, built in the disposable
#     workspace, used only to make a state dir refuse ONE cap-state write and
#     accept the next. It knows nothing about the watcher.
#
# Usage: wedge_cap_live.sh <scenario>
#   reset-fault      the post-fire escalation-counter reset is refused once
#   cap-healthy      a cap fire on a state dir that accepts every write
#   cap-off          an unconfigured home keeps today's ladder
#   sentinel-routes  each of the three cap-state write failures, in turn
# KEEP_WORK=1 / KEEP_LAB=1 leave the scratch dirs for inspection.
set -u

ROOT=${FM_TEST_ROOT:-/home/nostradamus/.no-mistakes/worktrees/8b845ac61faf/01M5J589FVNWBHDEHPHC7Y1148}
EV=${FM_TEST_EV:-/home/nostradamus/.no-mistakes/evidence/01M5J589FVNWBHDEHPHC7Y1148}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wedge-live.XXXXXX")
SCENARIO=${1:-}
LAB=
REAL_TMUX=$(command -v tmux)
SOCK=fm-wedge-live
SESSION=fmlab
WIN=fm-wedge1
TASK=wedge1
TARGET="$SESSION:$WIN"
T= KEY=
CAP=2

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$LAB" ]; then
    TMUX_TMPDIR="$LAB/tmux" tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
    case "${KEEP_LAB:-0}" in 1) printf 'lab kept: %s\n' "$LAB" >&2 ;; *) rm -rf "$LAB" ;; esac
  fi
  case "${KEEP_WORK:-0}" in 1) printf 'work kept: %s\n' "$WORK" >&2 ;; *) rm -rf "$WORK" ;; esac
  exit $rc
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
hdr() { printf '\n===== %s\n' "$*"; }
have() { [ -e "$1" ]; }

PANE_SCRIPT="$WORK/pane.sh"
cat > "$PANE_SCRIPT" <<'PEOF'
#!/usr/bin/env bash
# A wedged crew pane: one static frame, then a long foreground sleep. The frame
# never changes again, so every real capture-pane of this window is identical -
# what a wedged agent pane actually looks like to the watcher.
cat <<'FRAME'
╭─ crew: no-mistakes pipeline ──────────────────────────────╮
│ > re-run the pipeline and fix every review finding        │
│                                                           │
│   ✓ read 214 files                                        │
│   ✓ code review  · 3 findings                              │
│   ⣾ no-mistakes validating (round 1)                      │
│                                                           │
│   esc to interrupt · ctrl+c to exit                       │
╰───────────────────────────────────────────────────────────╯
FRAME
exec sleep 100000
PEOF
chmod +x "$PANE_SCRIPT"

lab_teardown() {
  [ -n "$LAB" ] || return 0
  TMUX_TMPDIR="$LAB/tmux" tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
  LAB=
}

lab_new() {  # a fresh disposable home, private socket, real frozen pane
  lab_teardown
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || return 1
  mkdir -p "$LAB/tmux" "$LAB/shim"
  cat > "$LAB/shim/tmux" <<SHIM
#!/usr/bin/env bash
export TMUX_TMPDIR="$LAB/tmux"
exec "$REAL_TMUX" -f /dev/null -L "$SOCK" "\$@"
SHIM
  chmod +x "$LAB/shim/tmux"
  TMUX_TMPDIR="$LAB/tmux" "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true
  TMUX_TMPDIR="$LAB/tmux" "$REAL_TMUX" -L "$SOCK" new-session -d -s "$SESSION" -n "$WIN" \
    -x 200 -y 50 "$PANE_SCRIPT" || return 1
  local i=0 frame=
  while [ "$i" -lt 60 ]; do
    frame=$(TMUX_TMPDIR="$LAB/tmux" "$REAL_TMUX" -L "$SOCK" capture-pane -p -t "$TARGET" -S -40 2>/dev/null)
    case "$frame" in *'no-mistakes validating'*) break ;; esac
    i=$((i + 1)); sleep 0.1
  done
  T="$LAB/state"
  KEY=$(printf '%s' "$TARGET" | tr ':/.' '___')
  printf 'window=%s\nbackend=tmux\nkind=ship\nharness=claude\n' "$TARGET" > "$T/$TASK.meta"
  printf 'working: still wedged\n' > "$T/$TASK.status"
  cat > "$LAB/shim/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
# The crew-state contract is one line: state, source, detail.
printf 'state: working · source: run-step · validating (running)\n'
SH
  chmod +x "$LAB/shim/fm-crew-state.sh"
  printf '%s\n' "$frame" > "$WORK/pane-frame.txt"
  printf '%s\n' '#!/usr/bin/env bash' \
    '# One real watcher process against the lab. "$@" are env assignments.' \
    'set -u' \
    'exec env -u NO_MISTAKES_GATE \' \
    "  FM_HOME=\"$LAB\" FM_STATE_OVERRIDE=\"$LAB/state\" FM_CONFIG_OVERRIDE=\"$LAB/config\" \\" \
    "  FM_CREW_STATE_BIN=\"$LAB/shim/fm-crew-state.sh\" \\" \
    '  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \' \
    '  FM_WATCH_HANDLING_SUCCESSOR=1 \' \
    "  PATH=\"$LAB/shim:\$PATH\" \\" \
    "  \"\$@\" \"$ROOT/bin/fm-watch.sh\"" \
    > "$WORK/run-watch.sh"
  chmod +x "$WORK/run-watch.sh"
  printf '\n--- the live pane the watcher read (real tmux capture-pane of %s) ---\n' "$TARGET"
  sed -n '1,12p' "$WORK/pane-frame.txt"
}

# watch_run <outfile> <bound-secs> <env...>: run the real watcher, return its own
# exit status. 124 means the bound elapsed with the watcher still running, which
# is what a window the cap has silenced looks like.
watch_run() {  # <out> <secs> <env...>
  local out=$1 secs=$2; shift 2
  : > "$out"
  timeout --foreground -s TERM "$secs" "$WORK/run-watch.sh" "$@" > "$out" 2>&1
  return $?
}

prime() {  # <cap> - one poll the real watcher takes of this real pane
  watch_run "$WORK/prime.out" 25 FM_STALE_ESCALATE_SECS=999999 FM_WEDGE_MAX_ESCALATIONS="$1"
  if [ ! -e "$T/.hash-$KEY" ] || [ ! -e "$T/.stale-since-$KEY" ]; then
    say "PRIME FAILED (hash: $(have "$T/.hash-$KEY" && echo yes || echo no), timer: $(have "$T/.stale-since-$KEY" && echo yes || echo no))"
    say "prime watcher output:"; sed 's/^/    | /' "$WORK/prime.out"
    say "prime triage log:"; triage_tail 8 | sed 's/^/    | /'
    return 1
  fi
  return 0
}

age_timer() { printf '%s\n' "$(( $(date +%s) - ${1:-500} ))" > "$T/.stale-since-$KEY"; }
triage_tail() { tail -n "${1:-6}" "$T/.watch-triage.log" 2>/dev/null; }
count_rows() { local n; n=$(grep -c "$1" "$T/.wake-queue" 2>/dev/null) || n=0; case "$n" in ''|*[!0-9]*) n=0 ;; esac; printf '%s\n' "$n"; }
queue_bytes() { [ -e "$T/.wake-queue" ] && wc -c < "$T/.wake-queue" || printf '0\n'; }
queue_digest() { [ -e "$T/.wake-queue" ] && cut -f3,5 "$T/.wake-queue" | sed 's/^/    | /'; }

dump_state() {  # <label>
  hdr "state after: $1"
  if have "$T/.wedge-permanent-$KEY"; then
    say "cap marker .wedge-permanent-$KEY:  PRESENT ($(cat "$T/.wedge-permanent-$KEY"))"
  else
    say "cap marker .wedge-permanent-$KEY:  absent"
  fi
  if have "$T/.wedge-escalations-$KEY"; then
    say "escalation counter:                [$(cat "$T/.wedge-escalations-$KEY")]"
  else
    say "escalation counter:                absent"
  fi
  if have "$T/.wedge-rollback-failed-$KEY"; then
    say "rollback-failure sentinel:         PRESENT"
  else
    say "rollback-failure sentinel:         absent"
  fi
  if have "$T/.stale-since-$KEY"; then
    say "idle timer .stale-since-$KEY:      PRESENT ($(cat "$T/.stale-since-$KEY"))"
  else
    say "idle timer .stale-since-$KEY:      absent"
  fi
  say "PERMANENTLY-WEDGED rows in queue:  $(count_rows PERMANENTLY-WEDGED)"
  say "wake-queue bytes:                  $(queue_bytes)"
}

round() {  # <label> <secs> <env...>
  local label=$1 secs=$2; shift 2
  age_timer 500
  watch_run "$WORK/round.out" "$secs" "$@"
  local rc=$?
  say "[$label] watcher exit status: $rc   (124 = still running when the bound elapsed)"
  if [ -s "$WORK/round.out" ]; then
    say "[$label] watcher output (the wake it published):"
    sed 's/^/    | /' "$WORK/round.out"
  else
    say "[$label] watcher output: nothing - no wake delivered"
  fi
  return $rc
}

case "$SCENARIO" in

reset-fault)
  say "SCENARIO reset-fault"
  say "  FM_WEDGE_MAX_ESCALATIONS=$CAP. The cap fires, and the escalation-counter reset"
  say "  that ends its episode is refused ONCE (EIO); the rollback that follows succeeds."
  lab_new || exit 1
  prime "$CAP" || exit 1
  say "pane hash the real watcher recorded: $(cat "$T/.hash-$KEY")"
  printf '1\n' > "$T/.wedge-escalations-$KEY"   # the next ladder hit escalates past the bound
  rm -f "$WORK/fault.marker"
  age_timer 500
  # FM_FAULT_NTH=2: the FIRST write of the counter path in this watcher process
  # is the escalation-count write (a refusal there is a different route); the
  # SECOND is the post-fire reset under test.
  LD_PRELOAD="$EV/fault_once.so" \
    FM_FAULT_MATCH=".wedge-escalations-$KEY" FM_FAULT_NTH=2 \
    FM_FAULT_MARKER="$WORK/fault.marker" FM_FAULT_ERRNO=EIO \
    watch_run "$WORK/round.out" 30 \
      FM_STALE_ESCALATE_SECS=240 FM_WEDGE_MAX_ESCALATIONS="$CAP" FM_ROLLBACK_SENTINEL_TTL_SECS=3600
  say "one-shot write fault fired: $([ -e "$WORK/fault.marker" ] && echo yes || echo NO)"
  hdr "the operator line, checked against the state on disk"
  reset_line=$(grep -F 'escalation-counter reset FAILED' "$T/.watch-triage.log" | tail -1)
  say "$reset_line"
  counter_now=$(cat "$T/.wedge-escalations-$KEY" 2>/dev/null)
  case "$reset_line" in
    *'escalation count rolled back'*) : ;;
    *) say "  CLAIM FAILED: the line does not report the count rollback" ;;
  esac
  if [ -z "$counter_now" ]; then
    say "  claim 'escalation count rolled back' VERIFIED on disk: the counter is empty, not saturated at the bound"
  else
    say "  claim 'escalation count rolled back' FAILED: counter still reads [$counter_now]"
  fi
  if have "$T/.wedge-permanent-$KEY"; then
    say "  claim 'the cap marker stands' VERIFIED on disk: $(basename "$T/.wedge-permanent-$KEY") is present"
  else
    say "  claim 'the cap marker stands' FAILED: the marker is gone, which is what the OLD wording ('cap state rolled back') claimed"
  fi
  if have "$T/.wedge-rollback-failed-$KEY"; then
    say "  the rollback-failure sentinel is present, so this took a different tier than the line above reports"
  else
    say "  no rollback-failure sentinel: the rollback itself succeeded, the tier the line above names"
  fi
  hdr "operator triage log (tail)"
  triage_tail 6
  hdr "durable wake queue"
  queue_digest
  dump_state "the refused post-fire escalation-counter reset"

  hdr "next poll of the same wedged pane, cap still configured, marker standing"
  before=$(queue_bytes)
  round "silent poll" 20 FM_STALE_ESCALATE_SECS=240 FM_WEDGE_MAX_ESCALATIONS="$CAP"
  after=$(queue_bytes)
  say "wake-queue bytes before/after the silent poll: $before / $after"
  if [ "$before" = "$after" ]; then
    say "  claim 'this window stays silent' VERIFIED: no wake queued while the marker stands"
  else
    say "  claim 'this window stays silent' FAILED: the queue grew from $before to $after"
  fi
  say "triage tail after the silent poll:"; triage_tail 4 | sed 's/^/    | /'

  hdr "operator deletes the cap marker (STATE/.wedge-permanent-$KEY)"
  rm -f "$T/.wedge-permanent-$KEY"
  round "after operator rm" 25 FM_STALE_ESCALATE_SECS=240 FM_WEDGE_MAX_ESCALATIONS="$CAP"
  case "$(cat "$WORK/round.out")" in
    *'possible wedge'*) say "  claim 'an operator can delete the marker to re-engage at once' VERIFIED: the very next poll escalated this window again" ;;
    *) say "  claim 'delete the marker to re-engage at once' FAILED: the next poll published $(cat "$WORK/round.out")" ;;
  esac
  dump_state "the operator's re-engagement"

  hdr "and the same release through horizon expiry instead of an operator rm"
  lab_new || exit 1
  prime "$CAP" || exit 1
  printf '%s\n' "$(( $(date +%s) - 5 ))" > "$T/.wedge-permanent-$KEY"
  say "cap marker back-dated 5s, FM_CAP_HORIZON_SECS=1: the horizon has elapsed"
  round "past the horizon" 25 FM_STALE_ESCALATE_SECS=240 FM_WEDGE_MAX_ESCALATIONS="$CAP" FM_CAP_HORIZON_SECS=1
  case "$(cat "$WORK/round.out")" in
    *'possible wedge'*) say "  claim 'until its horizon elapses' VERIFIED: the ladder resumed once the marker aged out" ;;
    *) say "  claim 'until its horizon elapses' FAILED: nothing was published past the horizon" ;;
  esac
  ;;

cap-healthy)
  say "SCENARIO cap-healthy"
  say "  FM_WEDGE_MAX_ESCALATIONS=$CAP on a state dir that accepts every cap-state write."
  lab_new || exit 1
  prime "$CAP" || exit 1
  printf '1\n' > "$T/.wedge-escalations-$KEY"
  round "cap fire" 30 FM_STALE_ESCALATE_SECS=240 FM_WEDGE_MAX_ESCALATIONS="$CAP"
  hdr "operator triage log (tail)"
  triage_tail 6
  hdr "durable wake queue"
  queue_digest
  dump_state "a healthy cap fire"
  hdr "the next poll while the marker stands"
  before=$(queue_bytes)
  round "silent poll" 20 FM_STALE_ESCALATE_SECS=240 FM_WEDGE_MAX_ESCALATIONS="$CAP"
  say "wake-queue bytes before/after the silent poll: $before / $(queue_bytes)"
  ;;

cap-off)
  say "SCENARIO cap-off"
  say "  No FM_WEDGE_MAX_ESCALATIONS at all: an unconfigured home keeps today's ladder."
  lab_new || exit 1
  prime 0 || exit 1
  hdr "operator triage log after the prime poll (tail)"
  triage_tail 4
  n=1
  while [ "$n" -le 5 ]; do
    round "ladder rung $n" 25 FM_STALE_ESCALATE_SECS=240
    say "    escalation counter now: [$(cat "$T/.wedge-escalations-$KEY" 2>/dev/null)]"
    say "    cap marker: $(have "$T/.wedge-permanent-$KEY" && echo PRESENT || echo absent)"
    n=$((n + 1))
  done
  hdr "operator triage log (tail)"
  triage_tail 8
  hdr "durable wake queue"
  queue_digest
  dump_state "five uncapped wedge escalations"
  ;;

sentinel-routes)
  say "SCENARIO sentinel-routes"
  say "  Each of the three cap-state write failures in turn, each on a fresh lab."
  for route in marker-write count-write reset-write; do
    hdr "route: $route"
    LAB=; lab_new || exit 1
    prime "$CAP" || exit 1
    printf '1\n' > "$T/.wedge-escalations-$KEY"
    rm -f "$WORK/fault.marker"
    age_timer 500
    case "$route" in
      marker-write) m=".wedge-permanent-$KEY"; nth=1 ;;
      count-write)  m=".wedge-escalations-$KEY"; nth=1 ;;
      reset-write)  m=".wedge-escalations-$KEY"; nth=2 ;;
    esac
    LD_PRELOAD="$EV/fault_once.so" \
      FM_FAULT_MATCH="$m" FM_FAULT_NTH="$nth" FM_FAULT_MARKER="$WORK/fault.marker" FM_FAULT_ERRNO=EIO \
      watch_run "$WORK/round.out" 30 FM_STALE_ESCALATE_SECS=240 \
        FM_WEDGE_MAX_ESCALATIONS="$CAP" FM_ROLLBACK_SENTINEL_TTL_SECS=3600
    rc=$?
    say "watcher exit status: $rc; one-shot fault fired: $([ -e "$WORK/fault.marker" ] && echo yes || echo NO)"
    say "watcher output:"; sed 's/^/    | /' "$WORK/round.out"
    say "operator triage log (tail):"; triage_tail 3 | sed 's/^/    | /'
    dump_state "the refused $route"
    lab_teardown
  done
  ;;

*)
  say "unknown scenario '$SCENARIO'" >&2
  exit 2
  ;;
esac
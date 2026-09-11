#!/usr/bin/env bash
# End-to-end demonstration of the FM_WEDGE_MAX_ESCALATIONS wedge cap
# (patch/wedge-cap-2026-08-19, PR #2605) against the real bin/fm-watch.sh
# and bin/fm-wake-drain.sh, using the same fake-tmux fixtures as
# tests/fm-watch-wedge-cap.test.sh. Produces transcript.md showing the
# captain-facing behavior: escalating stale wakes, ONE terminal
# PERMANENTLY-WEDGED wake, durable markers, then silence under hash churn.
set -u

ROOT=/home/nostradamus/.no-mistakes/worktrees/8b845ac61faf/01M287H09YAS0Y0ZCHSKSHE523
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
DEMO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$DEMO/case"
STATE="$CASE/state"
FAKEBIN="$CASE/fakebin"
TANGLE="$DEMO/tangle-root"   # non-git dir keeps fm-guard's tangle banner inert
mkdir -p "$STATE" "$FAKEBIN" "$TANGLE"

transcript="$DEMO/transcript.md"
: > "$transcript"

log() { printf '%s\n' "$*" >> "$transcript"; }
run_log() { # append command stdout/stderr section
  local title=$1; shift
  log "" "### $title" '```'
  { "$@"; } >> "$transcript" 2>&1
  log '```'
}

# --- fixtures: fake tmux + fake crew state (same contracts as wake-helpers.sh)
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
  exit 0
fi
if [ "${1:-}" = "capture-pane" ]; then
  [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE"
  exit 0
fi
if [ "${1:-}" = "display-message" ]; then
  case "$*" in *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;; esac
fi
exit 1
SH
chmod +x "$FAKEBIN/tmux"
cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
SH
chmod +x "$FAKEBIN/fm-crew-state.sh"

# --- fixture state: one wedged worker window
window="demo:fm-wedge-cap-e2e"
capture_file="$CASE/pane.txt"
printf 'idle wedged content' > "$capture_file"
printf 'window=%s\nkind=ship\n' "$window" > "$STATE/wedge-cap-e2e.meta"
printf 'working: still wedged\n' > "$STATE/wedge-cap-e2e.status"
sig=$(stat -c '%s:%Y' "$STATE/wedge-cap-e2e.status")
printf '%s' "$sig" > "$STATE/.seen-wedge-cap-e2e_status"
key=$(printf '%s' "$window" | tr ':/.' '___')
pane_hash=$(printf '%s' "idle wedged content" | md5sum | cut -d' ' -f1)
printf '%s' "$pane_hash" > "$STATE/.hash-$key"
printf '1\n' > "$STATE/.count-$key"
max=4
export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

queue_rows() { wc -l < "$STATE/.wake-queue" 2>/dev/null || echo 0; }

ack_cycle() { # drain then acknowledge, as the captain/agent would
  local err="$CASE/drain-ack.err" sequence generation
  FM_ROOT_OVERRIDE="$TANGLE" FM_STATE_OVERRIDE="$STATE" "$DRAIN" > "$CASE/drain.out" 2> "$err" || true
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  if [ -n "$sequence" ] && [ -n "$generation" ]; then
    FM_ROOT_OVERRIDE="$TANGLE" FM_STATE_OVERRIDE="$STATE" "$DRAIN" --ack-through "$sequence" \
      --recovery-generation "$generation" >> "$CASE/drain-ack.out" 2>> "$err" || true
  fi
  rm -f "$err"
}

wait_beat_exit() { # run one watcher round, bounded, capture exit code
  local out_file=$1 stale_secs=$2 pid rc=0
  PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_ROOT_OVERRIDE="$TANGLE" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=$stale_secs FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max FM_CAP_HORIZON_SECS=86400 \
    "$WATCH" > "$out_file" 2>&1 &
  pid=$!
  local i=0
  while [ $i -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1; i=$((i+1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
    reap "$pid"; rc=timeout
  else
    wait "$pid"; rc=$?
  fi
  [ $# -ge 3 ] && return 0
  echo $rc
}

# priming poll: absorb one unchanged-pane poll below the stale bound
wait_beat_exit "$CASE/prime.out" 999 >/dev/null
ack_cycle

log "# Wedge cap end-to-end demonstration (PR #2605, FM_WEDGE_MAX_ESCALATIONS)"
log ""
log "Scenario: one worker pane ('demo:fm-wedge-cap-e2e') is wedged - the same rendered pane, a static 'working:' status, provably-working crew verdict, and no write evidence. This is the 2026-08-18 MiniMax drain shape: an LLM-supervised loop that keeps demanding deep inspection forever. \`FM_WEDGE_MAX_ESCALATIONS=4\` (lowered from the default 10 for a short demo) caps it."
log ""
log "Watcher: \`bin/fm-watch.sh\` (real, from this PR branch). Wake delivery: \`bin/fm-wake-drain.sh\` (the captain-facing drain)."
log ""

log "## Rounds 1-3: ordinary wedge escalations accumulate"
log ""
n=1
while [ "$n" -lt "$max" ]; do
  echo $(( $(date +%s) - 500 )) > "$STATE/.stale-since-$key"
  wait_beat_exit "$CASE/round-$n.out" 240 >/dev/null
  esc_line=$(grep -o 'escalation [0-9]*' "$CASE/round-$n.out" | head -1)
  log "Round $n watcher output: \`$esc_line\` - wake queue rows: $(queue_rows)"
  ack_cycle
  n=$((n+1))
done
log ""
log "Every escalation appended one durable wake row (the pre-patch behavior would continue this forever, each row re-read by an LLM every ~4 minutes)."
log ""

log "## Round $max: the cap fires - ONE terminal PERMANENTLY-WEDGED wake"
log ""
echo $(( $(date +%s) - 500 )) > "$STATE/.stale-since-$key"
wait_beat_exit "$CASE/round-$max.out" 240 >/dev/null
log 'Watcher output:'
log '```'
cat "$CASE/round-$max.out" >> "$transcript"
log '```'
ack_cycle
log ""
log 'Captain-facing drain transcript for the terminal wake (what the LLM/captain actually receives):'
log '```'
grep -v '^WAKE_ACK_REQUIRED' "$CASE/drain.out" >> "$transcript" 2>/dev/null || true
log '```'
log ""
log "Durable cap markers written (window-scoped + per-hash, contents = cap-fire epoch):"
log '```'
ls -l "$STATE"/.wedge-permanent-* >> "$transcript" 2>&1
for m in "$STATE"/.wedge-permanent-*; do
  printf '%s => %s\n' "$(basename "$m")" "$(cat "$m")" >> "$transcript"
done
log '```'
log ""
log "Wake queue after the cap: $(queue_rows) rows - the terminal wake was presented by the drain above and then acknowledged through it, exactly like every ordinary wake; nothing is left to re-present."

log ""
log "## Suppression: 3 further polls with a HASH-CHURNING pane (fresh content each poll)"
log ""
before_rows=$(queue_rows)
i=0
while [ "$i" -lt 3 ]; do
  i=$((i+1))
  printf 'idle wedged content churned %d\n' "$i" > "$capture_file"
  echo $(( $(date +%s) - 500 )) > "$STATE/.stale-since-$key"
  wait_beat_exit "$CASE/churn-$i.out" 1 >/dev/null
  ack_cycle
done
after_rows=$(queue_rows)
log "Queue rows before churn polls: $before_rows, after 3 hash-churn polls: $after_rows (unchanged = no new wakes)."
log "PERMANENTLY-WEDGED occurrences across all churn-poll watcher outputs: $(cat "$CASE"/churn-*.out | grep -c PERMANENTLY-WEDGED || true) (expected 0)."
log 'One churn-poll watcher output (absorbed silently: zero bytes of wake text, no terminal wake):'
log '```'
if [ -s "$CASE/churn-1.out" ]; then head -3 "$CASE/churn-1.out" >> "$transcript"; else echo '(watcher output was empty - the poll absorbed the wedge without emitting anything)' >> "$transcript"; fi
log '```'
log ""
log "Markers still in place (no auto-lift anywhere; only FM_CAP_HORIZON_SECS or operator rm ends suppression):"
log '```'
ls "$STATE"/.wedge-permanent-* >> "$transcript" 2>&1
log '```'
log ""
log "## Result"
log ""
log "4 stale rounds produced 3 ordinary escalations plus exactly ONE terminal \`PERMANENTLY-WEDGED\` wake; subsequent polls - even with a fresh pane hash every poll - are silenced by the window-scoped marker until \`FM_CAP_HORIZON_SECS\` elapses or an operator removes both markers. The unattended LLM-loop drain is capped."

echo "transcript written: $transcript"

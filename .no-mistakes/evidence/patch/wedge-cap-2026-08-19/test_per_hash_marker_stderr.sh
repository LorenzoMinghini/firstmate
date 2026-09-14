#!/usr/bin/env bash
# Evidence-producing test for the 1ac0c79 fix (per-hash wedge-cap marker
# write wrapped in braces for stderr parity with the window-scoped write).
#
# Test goal: when the per-hash marker write fails because the target path
# is a directory (the realistic fs failure), bash's "Is a directory"
# diagnostic must NOT leak to the watcher's stderr.
set -u

cd /home/nostradamus/.no-mistakes/worktrees/8b845ac61faf/01M2G6AGNKQ8M460MY1XFYZERB
ROOT="$(pwd)"

# Source the shared harness to reuse make_case, hash_text, etc.
. tests/wake-helpers.sh

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot evidence-per-hash-stderr-test)

# --- local helpers (mirror tests/fm-watch-wedge-cap.test.sh) ---
ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation"
}
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in Z*) return 1 ;; esac
  return 0
}
wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then wait "$pid"; return "$?"; fi
    sleep 0.1; i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}
file_mtime() { stat -c %Y "$1" 2>/dev/null; }
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1; i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# --- fixture setup ---
dir=$(make_case per-hash-marker-fail)
state="$dir/state"
fakebin="$dir/fakebin"
out="$dir/watch.out"
err="$dir/watch.err"
capture_file="$dir/pane.txt"

window="test:fm-per-hash-marker-fail"
printf 'idle wedged content for per-hash marker fail test\n' > "$capture_file"
printf 'window=%s\nkind=ship\n' "$window" > "$state/per-hash-marker-fail.meta"
printf 'working: still wedged\n' > "$state/per-hash-marker-fail.status"
sig=$(stat -c '%s:%Y' "$state/per-hash-marker-fail.status")
printf '%s' "$sig" > "$state/.seen-per-hash-marker-fail_status"

key=$(printf '%s' "$window" | tr ':/.' '___')
pane_hash=$(hash_text "idle wedged content for per-hash marker fail test")
printf '%s' "$pane_hash" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"

export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

marker_hash="$state/.wedge-permanent-$key-${pane_hash:0:12}"
marker_window="$state/.wedge-permanent-$key"

echo "Marker paths:"
echo "  per-hash: $marker_hash"
echo "  window:   $marker_window"

# === STAGE 1: Prime ===
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=2 "$WATCH" > "$out" 2> "$err" &
pid=$!
if ! wait_poll_cycle "$state" "$pid"; then
  reap "$pid"; echo "Prime failed"; exit 1
fi
reap "$pid"
ack_stopped_cycle "$state" || true
echo "Prime complete"

# === STAGE 2: Drive max-1 normal escalations ===
max=2
n=1
while [ "$n" -lt "$max" ]; do
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" 2> "$err" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; echo "round $n watch failed"; exit 1; }
  ack_stopped_cycle "$state" || true
  n=$((n + 1))
done
counter_val=$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)
echo "Escalation counter before firing round: $counter_val (expected $((max - 1)))"

# === STAGE 3: Plant the per-hash marker path as a non-empty directory ===
mkdir -p "$marker_hash/blocker"
echo "Planted per-hash marker blocker"

# === STAGE 4: Drive the firing round ===
echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
: > "$err"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WEDGE_MAX_ESCALATIONS=$max "$WATCH" > "$out" 2> "$err" &
pid=$!
fire_rc=0
wait_for_exit "$pid" 100 || fire_rc=$?
if [ "$fire_rc" -eq 124 ]; then
  reap "$pid"; echo "firing round timed out"; exit 1
fi
# fire_rc is now whatever the watcher exited with

echo
echo "=== FIRING ROUND RESULT ==="
echo "Exit code: $fire_rc"
echo "stderr content:"
cat "$err"
echo "[end stderr]"

# === ASSERTIONS ===
echo
echo "=== ASSERTIONS ==="
fail_count=0

# 1. Bash's "Is a directory" diagnostic must NOT leak to stderr.
if grep -F "Is a directory" "$err" >/dev/null 2>&1; then
  echo "FAIL: bash 'Is a directory' diagnostic leaked to stderr (the 1ac0c79 fix is broken)"
  grep -F "Is a directory" "$err"
  fail_count=$((fail_count + 1))
else
  echo "OK: bash 'Is a directory' diagnostic is suppressed (the 1ac0c79 fix is in effect)"
fi

# 2. The triage_log line must be present.
triage_log="$state/.watch-triage.log"
if [ -e "$triage_log" ] && grep -F "per-hash marker write FAILED" "$triage_log" >/dev/null 2>&1; then
  echo "OK: triage_log 'per-hash marker write FAILED' emitted"
  grep -F "per-hash marker write FAILED" "$triage_log" | head -1
else
  echo "FAIL: triage_log line not emitted"
  fail_count=$((fail_count + 1))
fi

# 3. Exit code must be 1.
if [ "$fire_rc" -eq 1 ]; then
  echo "OK: exit code 1 (rollback succeeded)"
else
  echo "FAIL: expected exit 1, got $fire_rc"
  fail_count=$((fail_count + 1))
fi

echo
echo "=== RESULT ==="
if [ "$fail_count" -eq 0 ]; then
  echo "PASS: all assertions hold - 1ac0c79 fix verified end-to-end"
  exit 0
else
  echo "FAIL: $fail_count assertion(s) failed"
  exit 1
fi

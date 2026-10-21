#!/usr/bin/env bash
# Independent differential proof for the maintainer's ask, on the wedge route
# tests/fm-watch-wedge-cap-unconfigured-parity.test.sh does not drive: the
# TERMINAL-OVERRIDE absorb (a captain-relevant status log that
# crew_is_provably_working overrides). bin/fm-watch.sh calls
# wedge_episode_end "$key" 0 1 (keep-count) there, so with the cap UNSET the
# escalation counter must survive exactly as it survived on upstream main -
# which is what keeps the pane reaching the demand-deep-inspection prompt - and
# with a cap CONFIGURED the counter must restart.
#
# Same workload three times: upstream main's own bin/ tree, this branch with the
# cap unset, this branch with FM_WEDGE_MAX_ESCALATIONS=2. The oracle is
# upstream main's observable output, not the code under test.
set -u

ROOT=~/.no-mistakes/worktrees/8b845ac61faf/01M5FMZ32QXZCMQFQ4HMB23ASX
TMP=/tmp/wedgecap-ev/tov
rm -rf "$TMP"; mkdir -p "$TMP"
WINDOW='test:fm-terminal-override'
TASK=tov
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
STALE_SECS=240
FRAME='zzz frozen frame zzz'

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
wait_for_exit() {
  local pid=$1 limit=${2:-400} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return "$?"; }
    sleep 0.1; i=$((i+1))
  done
  reap "$pid"; return 124
}
hash_text() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}
# wait_poll_cycle <state> <pid>: wait until the watcher has completed a poll
# cycle, so a poll that publishes NO wake (the absorb round) can be ended on
# evidence of having run rather than on a timeout.
wait_poll_cycle() {
  local state=$1 pid=$2 limit=${3:-400} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"; first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat"); [ -n "$first" ] && break
    sleep 0.1; i=$((i+1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then return 0; fi
    sleep 0.1; i=$((i+1))
  done
  return 1
}

mark_status_seen() {
  FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}
ack_cycle() {
  local state=$1 err seq gen
  err="$state/.ack.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \(.*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$seq" ] && [ -n "$gen" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen"
}

# poll <tag> <state> <fakebin> <watch> <pane> <out> [cap-env]: one watcher poll.
poll() {
  local state=$1 fakebin=$2 watch=$3 pane=$4 out=$5 cap_env=${6-}
  local pid
  : > "$out"
  local -a cap_args=()
  [ -n "$cap_env" ] && cap_args+=("$cap_env")
  env FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_STALE_ESCALATE_SECS=$STALE_SECS \
    PATH="$fakebin:$PATH" "${cap_args[@]}" bash "$watch" > "$out" 2>&1 &
  pid=$!
  # A round that absorbs stays inside the poll loop, so it is ended on the
  # heartbeat that proves a cycle completed; a round that publishes a wake
  # exits on it, which wait_poll_cycle reports as the process being gone.
  if wait_poll_cycle "$state" "$pid" 600; then
    reap "$pid"
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    reap "$pid"
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  return 0
}

# run_arm <tag> <watcher> [cap-env] -> observable trace on stdout
run_arm() {
  local tag=$1 watch=$2 cap_env=${3-}
  local dir="$TMP/$tag" state fakebin out pane absorbed_esc esc inspect capped counter_after
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; pane="$dir/pane.txt"
  mkdir -p "$state" "$fakebin"
  cp "$TMP/fakebin/tmux" "$fakebin/tmux"
  cp "$TMP/fakebin/fm-crew-state.sh" "$fakebin/fm-crew-state.sh"
  chmod +x "$fakebin/tmux" "$fakebin/fm-crew-state.sh"

  printf '%s\n' "$FRAME" > "$pane"
  printf 'window=%s\nkind=ship\n' "$WINDOW" > "$state/$TASK.meta"
  # A captain-relevant terminal status line: the surface the override route owns.
  printf 'done: implementation complete, ready to validate\n' > "$state/$TASK.status"
  mark_status_seen "$state" "$state/$TASK.status"
  printf '%s' "$(hash_text "$FRAME")" > "$state/.hash-$KEY"
  printf '1\n' > "$state/.count-$KEY"
  # The window has already escalated twice: that counter is what is under test.
  printf '2\n' > "$state/.wedge-escalations-$KEY"

  # Round 1: first sight of this stale identity, on the terminal-override route.
  poll "$state" "$fakebin" "$watch" "$pane" "$out" "$cap_env" || {
    printf '%s: round 1 never settled: %s\n' "$tag" "$(cat "$out")" >&2; return 1; }
  local r1
  case "$(head -1 "$out" 2>/dev/null)" in '') r1=silent ;; *) r1="woke($(head -1 "$out"))" ;; esac
  absorbed_esc=$(cat "$state/.wedge-escalations-$KEY" 2>/dev/null || echo '-')
  printf 'round1(override absorb)=%s counter-after-absorb=%s\n' "$r1" "$absorbed_esc"
  ack_cycle "$state" || true

  # Age the wedge timer the absorb just re-armed, exactly as the repository's own
  # wedge harness does, so round 2 is an escalation rather than a wait.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$KEY"

  # Round 2: the same stale identity with the timer past the threshold. This
  # escalation's COUNT is what proves whether the absorb kept the counter.
  poll "$state" "$fakebin" "$watch" "$pane" "$out" "$cap_env" || {
    printf '%s: round 2 never settled: %s\n' "$tag" "$(cat "$out")" >&2; return 1; }
  esc=$(sed -n 's/.*escalation \([0-9][0-9]*\).*/\1/p' "$out" | tail -1); [ -n "$esc" ] || esc='-'
  grep -F 'demand-deep-inspection' "$out" >/dev/null && inspect=1 || inspect=0
  grep -F 'PERMANENTLY-WEDGED' "$out" >/dev/null && capped=1 || capped=0
  printf 'round2(ladder) esc=%s inspect=%s capped=%s\n' "$esc" "$inspect" "$capped"
  counter_after=$(cat "$state/.wedge-escalations-$KEY" 2>/dev/null || echo '-')
  [ -e "$state/.wedge-permanent-$KEY" ] && printf 'cap-marker=1\n' || printf 'cap-marker=0\n'
  printf 'final counter=%s\n' "$counter_after"
  ack_cycle "$state" || true
}

mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"; exit 0; fi
if [ "${1:-}" = "capture-pane" ]; then [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE"; exit 0; fi
if [ "${1:-}" = "display-message" ]; then
  case "$*" in *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;; esac
fi
exit 1
SH
cat > "$TMP/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
SH

UPSTREAM=$(git -C "$ROOT" rev-parse --verify --quiet origin/main) || { echo "no origin/main" >&2; exit 1; }
UP_TREE="$TMP/upstream"
rm -rf "$UP_TREE"; mkdir -p "$UP_TREE"
git -C "$ROOT" archive "$UPSTREAM" bin | tar -x -C "$UP_TREE" || exit 1
echo "baseline: origin/main = $UPSTREAM"
echo

echo "=== arm 1: upstream main, cap unset ==="
run_arm upstream "$UP_TREE/bin/fm-watch.sh" | tee "$TMP/trace-upstream"
echo "=== arm 2: this branch, cap unset ==="
run_arm branch-unset "$ROOT/bin/fm-watch.sh" | tee "$TMP/trace-branch"
echo "=== arm 3: this branch, FM_WEDGE_MAX_ESCALATIONS=2 ==="
run_arm branch-cap2 "$ROOT/bin/fm-watch.sh" 'FM_WEDGE_MAX_ESCALATIONS=2' | tee "$TMP/trace-cap2"

echo
echo "=== verdict ==="
rc=0
diff -u "$TMP/trace-upstream" "$TMP/trace-branch" > "$TMP/parity.diff" || {
  echo "FAIL: the unconfigured branch diverged from upstream main"; cat "$TMP/parity.diff"; rc=1; }
grep -F 'round2(ladder) esc=3 inspect=1 capped=0' "$TMP/trace-branch" >/dev/null || {
  echo "FAIL: the unconfigured branch did not reach escalation 3 with demand-deep-inspection"; cat "$TMP/trace-branch"; rc=1; }
grep -F 'counter-after-absorb=2' "$TMP/trace-branch" >/dev/null || {
  echo "FAIL: the unconfigured override absorb did not keep escalation 2"; cat "$TMP/trace-branch"; rc=1; }
grep -F 'round2(ladder) esc=1 inspect=0 capped=0' "$TMP/trace-cap2" >/dev/null || {
  echo "FAIL: a configured cap did not reset the counter at the absorb (expected esc=1 inspect=0)"; cat "$TMP/trace-cap2"; rc=1; }
grep -F 'counter-after-absorb=-' "$TMP/trace-cap2" >/dev/null || {
  echo "FAIL: a configured cap kept the counter at the override absorb"; cat "$TMP/trace-cap2"; rc=1; }
[ "$rc" -eq 0 ] && echo "PASS: unconfigured keeps upstream's counter (escalation 3 + demand-deep-inspection); a configured cap resets it (escalation 1)"
exit "$rc"
# fm/supervision-turn-cost live validation evidence

Branch fm/supervision-turn-cost, base bb8dd20, head 9737287. All drives against the real scripts
in the gate worktree, disposable lab home /tmp/fm-lab.8BMmvy (created and removed same turn).

## 1. Focused suites (real script execution)
- `bash tests/fm-supervision-tuning-lib.test.sh` -> PASS (absent file, well-formed file, env wins,
  non-numeric/unknown/injection values ignored, file never evaluated as shell).
- `bash tests/fm-watch-idle-cadence.test.sh` -> PASS (idle fleet 300s, busy fleet 15s, shipped
  default unchanged without the tuning file).

## 2. Real fm-brief.sh output (lab home, config/supervision-tuning present)
File: idle_poll_secs=300, max_fix_rounds=4
`FM_HOME=$LAB bin/fm-brief.sh lab-gate-policy demo-repo --mode no-mistakes --base-branch main`
brief.md line 98: `# Validation gate policy`, batching rule, and
`- Spend at most 4 fix rounds on this run's own findings.`

## 3. Env-var wins over file (real brief, FM_MAX_FIX_ROUNDS=1 with file saying 4)
`- Spend at most 1 fix rounds ...`

## 4. Absent tuning file (real brief, file moved aside)
`- Spend at most 2 fix rounds ...` (shipped default)

## 5. Watcher grace derivation (sourcing real bin/fm-watch.sh)
With idle_poll_secs=300, FM_POLL=15:
  idle=300 grace=360 poll=300   (grace derived from the slower poll: max(300,300+60)=360)
Without the file:
  idle=0 grace=300 poll=15      (shipped default)

## 6. Daemon live startup (lab tmux socket, plain-shell throwaway supervisor pane)
Inside lab pane: `env FM_HOME=$LAB timeout 15 bash bin/fm-supervise-daemon.sh`
state/.supervise-daemon.log:
  daemon starting (pid 3513353); target=%0; target_source=TMUX_PANE; backend=tmux; afk=off;
  stale_escalate=240s; batch=90s
  daemon shutting down   (exit 124 = the test timeout, clean shutdown)
The tuning-load path in fm_super_main executed cleanly in a real daemon run; no harness agent CLI
(claude/codex/...) exists on PATH, so a full agent-in-the-loop end-to-end drive was not possible.

## Teardown
tmux -L fm-lab kill-server; rm -rf lab home; worktree clean (git status empty).

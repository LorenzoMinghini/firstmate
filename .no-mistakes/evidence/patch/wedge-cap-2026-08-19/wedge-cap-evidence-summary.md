# Wedge cap (FM_WEDGE_MAX_ESCALATIONS) — evidence summary

PR branch: `patch/wedge-cap-2026-08-19` (bin/fm-watch.sh, tests/fm-watch-wedge-cap.test.sh)

## User intent
A wedged crew pane used to re-engage the supervised LLM loop with one paid stale
wake per poll, forever (the 2026-08-18 MiniMax ~359M-token drain). The patch caps
consecutive wedge escalations per window: at `FM_WEDGE_MAX_ESCALATIONS` the
watcher emits ONE terminal `PERMANENTLY-WEDGED` wake, writes BOTH
`STATE/.wedge-permanent-<key>` (window-scoped) and
`STATE/.wedge-permanent-<key>-<hash12>` (per-hash), and stays silent until
`FM_CAP_HORIZON_SECS` elapses or an operator removes both markers. Hash churn
(a ticking elapsed-time footer) can no longer rebuild the escalation counter.

## Method
Identical end-to-end scenario driven against the real unmodified `bin/fm-watch.sh`
from both the base commit (`9074f9d2`, extracted via `git archive`) and the patched
gate worktree: a Pi ship worker window wedged behind a ticking footer, busy verdict
from a real `fm-busy-event.sh` record, priming poll, two escalation polls, the
cap-threshold poll, then 12 polls with a fresh pane hash each, then operator `rm`
of both markers. Driver: `wedge-cap-demo.sh` (same fixture seams as
`tests/wake-helpers.sh`; `FM_WEDGE_MAX_ESCALATIONS=3` for a short demo cycle).

## Result — before vs after (same poll sequence)

| stage                         | base 9074f9d2                          | patched                                  |
|-------------------------------|----------------------------------------|------------------------------------------|
| escalations 1–2 polls         | stale wake each                        | stale wake each (identical)              |
| escalation 3 poll (cap)       | stale wake + demand-deep-inspection    | ONE terminal PERMANENTLY-WEDGED wake + both markers + triage line |
| 12 hash-churned polls         | 12 more wakes (escalations 4–15)       | 0 wakes; both markers hold               |
| operator `rm` both markers    | n/a                                    | cap lifts; wedge re-escalates from 1     |
| total wakes surfaced          | 16                                     | 4 (2 escalations + 1 terminal + 1 post-lift) |
| PERMANENTLY-WEDGED count      | 0                                      | 1 for the whole wedge-event              |

## Artifacts
- `wedge-cap-e2e-transcript-patched.txt` — patched watcher transcript (queue rows, surfaced reasons, markers, triage log)
- `wedge-cap-e2e-transcript-base.txt` — base-commit transcript showing the pre-patch flood
- `wedge-cap-e2e-wake-tally-patched.txt` / `wedge-cap-e2e-wake-tally-base.txt` — raw surfaced wake lines
- `wedge-cap-demo.sh` — the driver that produced them

## Focused suite
`bash tests/fm-watch-wedge-cap.test.sh` — all 15 cases pass, covering: cap fire
ordering (wake queued before markers, v13), both marker writes, silence across
pause transitions and fresh hashes, horizon expiry/re-fire, invalid-override
fallbacks, rollback + rollback-failed sentinel short-circuit (v14–v16), the
busy-route sentinel window-key regression (v17), escalation-counter reset at cap
fire, and operator rm re-engagement.

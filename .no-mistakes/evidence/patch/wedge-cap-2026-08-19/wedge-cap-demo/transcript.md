# Wedge cap end-to-end demonstration (PR #2605, FM_WEDGE_MAX_ESCALATIONS)

Scenario: one worker pane ('demo:fm-wedge-cap-e2e') is wedged - the same rendered pane, a static 'working:' status, provably-working crew verdict, and no write evidence. This is the 2026-08-18 MiniMax drain shape: an LLM-supervised loop that keeps demanding deep inspection forever. `FM_WEDGE_MAX_ESCALATIONS=4` (lowered from the default 10 for a short demo) caps it.

Watcher: `bin/fm-watch.sh` (real, from this PR branch). Wake delivery: `bin/fm-wake-drain.sh` (the captain-facing drain).

## Rounds 1-3: ordinary wedge escalations accumulate

Round 1 watcher output: `escalation 1` - wake queue rows: 1
Round 2 watcher output: `escalation 2` - wake queue rows: 1
Round 3 watcher output: `escalation 3` - wake queue rows: 1

Every escalation appended one durable wake row (the pre-patch behavior would continue this forever, each row re-read by an LLM every ~4 minutes).

## Round 4: the cap fires - ONE terminal PERMANENTLY-WEDGED wake

Watcher output:
```
stale: demo:fm-wedge-cap-e2e (idle 503s, possible wedge, escalation 4, PERMANENTLY-WEDGED: FM_WEDGE_MAX_ESCALATIONS=4 reached - no further wakes for this WINDOW until FM_CAP_HORIZON_SECS (default 86400s) elapses or operator manually removes BOTH STATE/.wedge-permanent-<key> AND STATE/.wedge-permanent-<key>-<hash12>; local patch 2026-08-19)
```

Captain-facing drain transcript for the terminal wake (what the LLM/captain actually receives):
```
1789145785	4	stale	demo:fm-wedge-cap-e2e	stale: demo:fm-wedge-cap-e2e (idle 503s, possible wedge, escalation 4, PERMANENTLY-WEDGED: FM_WEDGE_MAX_ESCALATIONS=4 reached - no further wakes for this WINDOW until FM_CAP_HORIZON_SECS (default 86400s) elapses or operator manually removes BOTH STATE/.wedge-permanent-<key> AND STATE/.wedge-permanent-<key>-<hash12>; local patch 2026-08-19)
```

Durable cap markers written (window-scoped + per-hash, contents = cap-fire epoch):
```
-rw-rw-r-- 1 nostradamus nostradamus 11 Sep 11 18:56 /tmp/no-mistakes-evidence/01M287H09YAS0Y0ZCHSKSHE523/wedge-cap-demo/case/state/.wedge-permanent-demo_fm-wedge-cap-e2e
-rw-rw-r-- 1 nostradamus nostradamus 11 Sep 11 18:56 /tmp/no-mistakes-evidence/01M287H09YAS0Y0ZCHSKSHE523/wedge-cap-demo/case/state/.wedge-permanent-demo_fm-wedge-cap-e2e-f903c289f70d
.wedge-permanent-demo_fm-wedge-cap-e2e => 1789145785
.wedge-permanent-demo_fm-wedge-cap-e2e-f903c289f70d => 1789145785
```

Wake queue after the cap: 0 rows - the terminal wake was presented by the drain above and then acknowledged through it, exactly like every ordinary wake; nothing is left to re-present.

## Suppression: 3 further polls with a HASH-CHURNING pane (fresh content each poll)

Queue rows before churn polls: 0, after 3 hash-churn polls: 0 (unchanged = no new wakes).
PERMANENTLY-WEDGED occurrences across all churn-poll watcher outputs: 0 (expected 0).
One churn-poll watcher output (absorbed silently: zero bytes of wake text, no terminal wake):
```
(watcher output was empty - the poll absorbed the wedge without emitting anything)
```

Markers still in place (no auto-lift anywhere; only FM_CAP_HORIZON_SECS or operator rm ends suppression):
```
/tmp/no-mistakes-evidence/01M287H09YAS0Y0ZCHSKSHE523/wedge-cap-demo/case/state/.wedge-permanent-demo_fm-wedge-cap-e2e
/tmp/no-mistakes-evidence/01M287H09YAS0Y0ZCHSKSHE523/wedge-cap-demo/case/state/.wedge-permanent-demo_fm-wedge-cap-e2e-f903c289f70d
```

## Result

4 stale rounds produced 3 ordinary escalations plus exactly ONE terminal `PERMANENTLY-WEDGED` wake; subsequent polls - even with a fresh pane hash every poll - are silenced by the window-scoped marker until `FM_CAP_HORIZON_SECS` elapses or an operator removes both markers. The unattended LLM-loop drain is capped.

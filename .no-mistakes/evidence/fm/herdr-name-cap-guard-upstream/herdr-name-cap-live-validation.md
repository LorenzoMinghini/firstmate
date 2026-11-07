# Live validation: herdr agent-name-cap guard (fm/herdr-name-cap-guard-upstream)

Environment: real herdr 0.9.5 on this host; isolated lab session `fm-lab-capg2`
via bin/fm-herdr-lab.sh (prepare/provision/teardown contract), disposable marked
lab home via bin/fm-lab-home.sh. Teardown confirmed only the default session
remains. Worktree clean afterwards.

## Oracle: real herdr `agent start` cap (herdr 0.9.5)
- 33-char name -> `{"error":{"code":"invalid_agent_name","message":"agent name must
  start with a lowercase letter and contain only lowercase letters, digits, '-' or
  '_' (1-32 characters)"},"id":"cli:agent:start"}`, rc=1
- 32-char name -> agent started successfully (rc=0) in the lab workspace/pane.

## Guard scenarios driven live against bin/fm-spawn.sh / bin/fm-control.sh
1. fresh spawn, 33-char id, --backend herdr:
   `error: herdr caps agent names at 32 characters ... task id 'aaa...' (33 chars);
   pick a shorter id before spawning`, rc=1. No herdr tab/pane created (tab count
   stayed 1).
2. fresh spawn, 32-char id, --backend herdr: no cap refusal; fails downstream on
   missing brief (cap is inclusive at 32).
3. fresh spawn, 33-char id, --backend tmux: no cap refusal (guard is
   herdr-only); fails downstream on missing brief.
4. fm-spawn --relaunch, herdr meta, 33-char id: cap refusal before any endpoint
   inspection, rc=1.
5. fm-control relaunch, herdr meta, 33-char id: cap refusal BEFORE stopping the
   old agent or mutating durable records, rc=1.

## Regression proof (test fails without the guard)
Copied the worktree to a disposable temp dir, removed the guard blocks from
bin/fm-control-lib.sh, bin/fm-spawn.sh, bin/fm-control.sh (bash -n OK, no guard
refs remained), ran tests/fm-spawn-herdr-name-cap.test.sh there: first 33-char
assertion fails — without the guard the spawn falls past the cap check into an
unrelated downstream failure (`cd: .../projects/none: No such file or directory`),
the silent-stranding shape the guard exists to prevent. See
herdr-name-cap-guardless-regression.log.

## Focused suite with the guard (worktree as-is)
`bash tests/fm-spawn-herdr-name-cap.test.sh` -> 9/9 ok, FM_TEST_COMPLETE.

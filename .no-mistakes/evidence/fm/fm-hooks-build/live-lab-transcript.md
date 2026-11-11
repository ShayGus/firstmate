# Live lab transcript (lab home /tmp/fm-lab.VHYAC0, private tmux socket /tmp/fml.DoHlyF/tmux-1000/fm-lab)
## hooks.json
{
  "version": 1,
  "hooks": [
    {
      "id": "instruction-check",
      "event": "worker.start.before",
      "argv": [
        "/tmp/fm-lab.VHYAC0/hooks/instruction-check"
      ],
      "timeout_seconds": 60
    },
    {
      "id": "notify-start",
      "event": "worker.start.after",
      "argv": [
        "/tmp/fm-lab.VHYAC0/hooks/instruction-check"
      ]
    },
    {
      "id": "notify-brief",
      "event": "brief.generated.after",
      "argv": [
        "/tmp/fm-lab.VHYAC0/hooks/instruction-check"
      ]
    },
    {
      "id": "steer-check",
      "event": "task.steer.before",
      "argv": [
        "/tmp/fm-lab.VHYAC0/hooks/steer-check"
      ]
    },
    {
      "id": "steer-notify",
      "event": "task.steer.after",
      "argv": [
        "/tmp/fm-lab.VHYAC0/hooks/steer-check"
      ]
    },
    {
      "id": "cleanup-gate",
      "event": "task.cleanup.before",
      "argv": [
        "/tmp/fm-lab.VHYAC0/hooks/steer-check"
      ]
    },
    {
      "id": "cleanup-notify",
      "event": "task.cleanup.after",
      "argv": [
        "/tmp/fm-lab.VHYAC0/hooks/steer-check"
      ]
    }
  ]
}
## instruction-check hook
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> "$FM_HOME/hook-log.jsonl"
ev=$(jq -r .event <<<"$payload"); id=$(jq -r .task_id <<<"$payload")
case "$ev" in *.after) exit 0 ;; esac
brief=$(jq -r .brief_path <<<"$payload")
req="$FM_HOME/records/$id.request"
[ -f "$req" ] || { echo "no original request for $id; cannot compare" >&2; exit 3; }
if grep -qi 'every ERP system' "$req" && grep -qi 'ERPNext only' "$brief"; then
  echo "scope mismatch: request says 'every ERP system' but instructions say 'ERPNext only'" >&2; exit 9
fi
echo "instructions match request for $id"
## steer-check hook
#!/usr/bin/env bash
payload=$(cat); printf '%s\n' "$payload" >> "$FM_HOME/hook-log.jsonl"
case "$(jq -r .event <<<"$payload")" in *.after) exit 0;; esac
if jq -r '.message // ""' <<<"$payload" | grep -qi 'ERPNext only'; then echo "steer narrows scope to ERPNext only" >&2; exit 4; fi
## spawn/brief run
TMUX=/tmp/fml.DoHlyF/tmux-1000/fm-lab,2163308,0
=== S1 fm-brief.sh ship (brief.generated.after notify)
scaffolded: /tmp/fm-lab.VHYAC0/data/erp1/brief.md (ship, mode=local-only; replace {TASK} and {FIRSTMATE_SPEC})
rc=0
/tmp/fmhk-scripts/drive-spawn.sh: line 10: /tmp/fm-lab.VHYAC0/data/erp2/brief.md.new: No such file or directory
=== S2 fm-spawn.sh erp1 with ERPNext-only instructions (expect veto)
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fm-lab.VHYAC0
warning: /tmp/fm-lab.VHYAC0/data/erp1/launch-brief.md records no ship branch; defaulting to legacy branch fm/erp1
notice: erp1 ships mode=local-only while the standing posture for erp is no-mistakes - less rigor than the captain's standing posture; proceed only on a current explicit captain instruction or an intake judgment you can state
error: hook instruction-check failed worker.start.before (exit 9; timeout bound 60s)
scope mismatch: request says 'every ERP system' but instructions say 'ERPNext only'
rc=1
meta exists? no
tmux windows:
primary:bash
=== S3 fm-spawn.sh erp3 with no request record (checker cannot compare -> veto)
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fm-lab.VHYAC0
warning: /tmp/fm-lab.VHYAC0/data/erp3/launch-brief.md records no ship branch; defaulting to legacy branch fm/erp3
notice: erp3 ships mode=local-only while the standing posture for erp is no-mistakes - less rigor than the captain's standing posture; proceed only on a current explicit captain instruction or an intake judgment you can state
error: hook instruction-check failed worker.start.before (exit 3; timeout bound 60s)
no original request for erp3; cannot compare
rc=1
=== S4 fm-spawn.sh erp2 raw command with matching instructions (expect launch)
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fm-lab.VHYAC0
warning: /tmp/fm-lab.VHYAC0/data/erp2/launch-brief.md records no ship branch; defaulting to legacy branch fm/erp2
notice: erp2 ships mode=local-only while the standing posture for erp is no-mistakes - less rigor than the captain's standing posture; proceed only on a current explicit captain instruction or an intake judgment you can state
spawned erp2 harness=bash kind=ship mode=local-only yolo=off window=primary:fm-erp2 worktree=~/.treehouse/erp-80b0b2/1/erp
rc=0
meta:
window=primary:fm-erp2
endpoint_task_id=erp2
worktree=~/.treehouse/erp-80b0b2/1/erp
project=/tmp/fm-lab.VHYAC0/projects/erp
harness=bash
kind=ship
mode=local-only
yolo=off
branch=fm/erp2
tasktmp=/tmp/fm-erp2
model=default
effort=default
spawn_gen=s1794394314.2166222.27749
tmux windows:
primary:bash
primary:fm-erp2
DRIVE-DONE
## approved snapshot vs evaluated digest
7bf008c551b7233441c908d08aa57a4ac0c6638b157c9cf49fb5808e4c283fd8  /tmp/fm-lab.VHYAC0/data/erp2/launch-approved.ZxV0Y7
## steer/cleanup run
=== S5 fm-send.sh erp2 narrowing steer (expect veto)
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fm-lab.VHYAC0
error: hook steer-check failed task.steer.before (exit 4; timeout bound 120s)
steer narrows scope to ERPNext only
rc=1
=== S6 fm-send.sh erp2 ordinary steer (expect delivery)
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fm-lab.VHYAC0
rc=0
/tmp/fm-lab.VHYAC0/state/erp2.inbox/001.msg
=== S7 fm-teardown.sh erp2 (cleanup before/after)
fm-gate-refuse: gate agent lifecycle permitted only against lab home /tmp/fm-lab.VHYAC0
teardown: reaping leaked worktree process(es) for erp2: 2167778 2171308
teardown: force-killing leaked worktree process(es) for erp2: 2167778
🌳 Worktree returned to pool.
teardown erp2 complete (window primary:fm-erp2, worktree ~/.treehouse/erp-80b0b2/1/erp)
Backlog: erp2 just finished (this home keeps no markdown backlog at /tmp/fm-lab.VHYAC0/data/backlog.md). Update /tmp/fm-lab.VHYAC0/data/backlog.md - move erp2 to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due.
rc=0
meta removed
DRIVE-DONE

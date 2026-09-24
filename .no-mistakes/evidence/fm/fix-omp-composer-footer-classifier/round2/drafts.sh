#!/usr/bin/env bash
# Adversarial drafts: type multi-line drafts (Shift+Enter) whose continuation
# lines mimic omp footer cells into live omp panes, read the verdict through
# HEAD and base d4f3b78 fm_backend_herdr_composer_state, capture, then clear.
set -u
R=/home/shayg/.no-mistakes/worktrees/f4bb769f35f8/01M39SN6G9D40EFA3V9GBC85A0
E=/home/shayg/.no-mistakes/evidence/01M39SN6G9D40EFA3V9GBC85A0/round2
S=$(cat $E/lab-session.txt)
L() { "$R/bin/fm-herdr-lab.sh" run "$S" "$@"; }
draft() {  # <id> <pane> <leading-text> <line>...
  local id=$1 pane=$2 first=$3 l; shift 3
  [ -z "$first" ] || L pane send-text "$pane" "$first" >/dev/null
  for l in "$@"; do L pane send-keys "$pane" shift+enter >/dev/null; L pane send-text "$pane" "$l" >/dev/null; done
  sleep 1.5
  L pane read "$pane" --source visible > "$E/captures/draft-$id.txt" 2>&1
  "$E/drive.sh" capture "$pane" > "$E/captures/draft-$id.ansi"
  printf '%-14s %s head=%-8s base=%s\n' "$id" "$pane" "$("$E/drive.sh" state "$pane")" "$("$E/drive.sh" state_base "$pane")"
  printf '    screen tail:\n'; grep -v '^[[:space:]]*$' "$E/captures/draft-$id.txt" | tail -$(( $# + 3 )) | sed 's/^/    | /'
  L pane send-keys "$pane" ctrl+c >/dev/null; sleep 1
  printf '    after clear: head=%s\n' "$("$E/drive.sh" state "$pane")"
}
draft ctx-1M        w1:p2 '' 'fix · tests · ◫ 9.0%/1M ⟲'
draft ctx-272K      w1:p3 '' 'fix · tests · ◫ 9.0%/272K ⟲'
draft compact-1.1M  w1:p4 '' '◑ GLM-5.3-Flash · ⑂ fm/branch · ◫ 9.0%/1.1M ⟲' '○ 🐴 ponytail: ⚡ FULL'
draft quota-5h      w1:p5 '' '⬢ GLM-5.3-Flash · ◉ max · ⑂ fm/branch · ⏱ pro · 5h 94% (2h 33m) · 7d 96% (3d 20h)' '● Action: keep backups'
draft quota-7d      w1:p7 '' '⬢ GPT-6-Sol · ◑ med · ⑂ fm/omp-footer   ⏱ pro · 7d 14% (4d 19h) · ✦ 3 exp 9d 11h'
draft paired-bare   w1:p2 '' '⬢ GLM-5.3-Flash · ◉ max · ⑂ fm/branch' '● Action: keep backups'
draft plugin-only   w1:p3 '' '○ 🐴 ponytail: ⚡ FULL'
draft tok-s         w1:p4 '' '⚡ 42 tok/s'
draft wrapped-quota w1:p5 'word word word word word word word word word word word word word word word word word abcdefgh' '⬢ GLM-5.3-Flash · ◉ max · ⑂ fm/branch · ⏱ pro · 5h 94% (2h 33m) · 7d 96% (3d 20h)'
draft single-line   w1:p7 'please rerun the tests'

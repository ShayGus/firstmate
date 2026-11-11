#!/usr/bin/env bash
# Lifecycle hook contract and shared worker boundaries, with fake local commands.
# shellcheck disable=SC2031 # Each fixture deliberately resets exported per-case paths.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-hook-lib.sh
. "$ROOT/bin/fm-hook-lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-lifecycle-hooks)

make_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  fm_test_spawn_home "$HOME_DIR" claude
  export FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
  export FM_DATA_OVERRIDE="$HOME_DIR/data" FM_STATE_OVERRIDE="$HOME_DIR/state"
  export FM_PROJECTS_OVERRIDE="$HOME_DIR/projects"
  cat > "$CASE/hook command" <<'SH'
#!/usr/bin/env bash
set -eu
payload=$(cat)
printf '%s\n' "$payload" | jq -c '. + {observed_cwd:env.PWD,observed_home:env.FM_HOME}' >> "$FM_HOME/events.jsonl"
event=$(printf '%s' "$payload" | jq -r .event)
case "${HOOK_BEHAVIOR:-}" in
  mutate) printf 'changed\n' >> "$(printf '%s' "$payload" | jq -r .brief_path)" ;;
  save)
    for field in brief promotion_instructions; do
      file=$(printf '%s' "$payload" | jq -r --arg f "${field}_path" '.[$f] // empty')
      [ -z "$file" ] || cp "$file" "$FM_HOME/evaluated-$field"
    done ;;
  timeout)
    sleep 20 &
    child=$!
    printf '%s\n' "$child" > "$FM_HOME/hook-child.pid"
    wait "$child" ;;
  noisy) for ((i=0; i<10000; i++)); do printf 'diagnostic line %s\n' "$i"; done; exit 7 ;;
esac
if [ "${HOOK_FAIL_EVENT:-}" = "$event" ]; then echo 'scope mismatch: every ERP system versus ERPNext only' >&2; exit 7; fi
printf '%s\0' "$@" > "$FM_HOME/argv"
SH
  chmod +x "$CASE/hook command"
}

config() {
  local event
  : > "$CASE/entries"
  for event in "$@"; do
    jq -nc --arg event "$event" --arg command "$CASE/hook command" \
      '{id:$event,event:$event,argv:[$command,"space argument","$(touch should-not-exist); *","trailing\n"],timeout_seconds:1}' >> "$CASE/entries"
  done
  jq -s '{version:1,hooks:.}' "$CASE/entries" > "$HOME_DIR/config/hooks.json"
  chmod 600 "$HOME_DIR/config/hooks.json"
}

assert_events() {
  local actual
  actual=$(jq -r .event "$HOME_DIR/events.jsonl" | paste -sd, -)
  [ "$actual" = "$1" ] || fail "events differ: $actual (wanted $1)"
}

run_contract() {
  fm_hook_begin worker.start spawn task_id task brief_path "${1:-}" || return 1
  fm_hook_before || return 1
  fm_hook_after
}

test_runner() {
  local out rc event payload
  make_case contract
  run_contract || fail 'absent config changed behavior'
  [ ! -e "$HOME_DIR/events.jsonl" ] || fail 'absent config executed a command'
  config worker.start.before worker.start.after
  printf 'all ERP systems\n' > "$CASE/candidate"
  run_contract "$CASE/candidate" || fail 'passing hook refused'
  assert_events worker.start.before,worker.start.after
  jq -es '.[0].brief_sha256 == .[1].brief_sha256 and .[1].before_invocation_id == .[0].invocation_id and .[0].observed_cwd == .[0].home and .[0].observed_home == .[0].home' "$HOME_DIR/events.jsonl" >/dev/null || fail 'payload identity, cwd, or correlation differs'
  # shellcheck disable=SC2016 # Test literal shell metacharacters.
  printf '%s\0' 'space argument' '$(touch should-not-exist); *' $'trailing\n' > "$CASE/expected-argv"
  cmp -s "$HOME_DIR/argv" "$CASE/expected-argv" || fail 'literal argv changed'
  [ ! -e "$HOME_DIR/should-not-exist" ] || fail 'argv was interpreted as shell'
  : > "$HOME_DIR/events.jsonl"
  rc=0
  out=$(HOOK_FAIL_EVENT=worker.start.before run_contract "$CASE/candidate" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'before refusal was ignored'
  assert_events worker.start.before
  assert_contains "$out" 'every ERP system' 'refusal lost diagnostics'
  : > "$HOME_DIR/events.jsonl"
  HOOK_FAIL_EVENT=worker.start.after run_contract "$CASE/candidate" >/dev/null 2>&1 || fail 'after failure rejected action'
  assert_events worker.start.before,worker.start.after
  rc=0
  HOOK_BEHAVIOR=mutate run_contract "$CASE/candidate" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail 'changed candidate reused approval'
  config worker.start.before
  rc=0
  HOOK_BEHAVIOR=timeout run_contract "$CASE/candidate" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail 'timeout was allowed'
  for event in unknown task.status.after; do
    config "$event"
    run_contract >/dev/null 2>&1 && fail 'unknown event was allowed'
  done
  config worker.start.before
  jq '.hooks[0].argv[0]="/not/an/executable"' "$HOME_DIR/config/hooks.json" > "$CASE/new"
  cp "$CASE/new" "$HOME_DIR/config/hooks.json"
  run_contract >/dev/null 2>&1 && fail 'missing executable was allowed'
  for payload in '{"version":1,"hooks":[]} {"version":1,"hooks":[]}' '{"version":2,"hooks":[]}' '{"version":1,"hooks":[],"typo":true}' '{"version":1,"hooks":[{}]}' 'broken'; do
    printf '%s' "$payload" > "$HOME_DIR/config/hooks.json"
    run_contract >/dev/null 2>&1 && fail "malformed config allowed: $payload"
  done
  config worker.start.before
  chmod 666 "$HOME_DIR/config/hooks.json"
  run_contract >/dev/null 2>&1 && fail 'writable config was allowed'
  chmod 600 "$HOME_DIR/config/hooks.json"
  chmod 000 "$HOME_DIR/config"
  if [ ! -x "$HOME_DIR/config" ]; then
    run_contract >/dev/null 2>&1 && fail 'inaccessible config directory was treated as absence'
  fi
  chmod 700 "$HOME_DIR/config"
  mv "$HOME_DIR/config/hooks.json" "$CASE/config"
  ln -s "$CASE/config" "$HOME_DIR/config/hooks.json"
  run_contract >/dev/null 2>&1 && fail 'symlink config was allowed'
  pass 'runner: absent/pass/refusal/timeout/missing command/config trust and literal argv'
}

test_snapshot_and_notify_order() {
  make_case snapshot
  config worker.start.before worker.start.after
  fm_hook_begin worker.start spawn || fail begin
  printf 'broken' > "$HOME_DIR/config/hooks.json"
  fm_hook_before || fail 'config changed inside action snapshot'
  fm_hook_after || fail 'notification failed'
  assert_events worker.start.before,worker.start.after
  config worker.start.after
  jq '.hooks += [.hooks[0] | .id="second-notify"]' "$HOME_DIR/config/hooks.json" > "$CASE/new"
  cp "$CASE/new" "$HOME_DIR/config/hooks.json"
  : > "$HOME_DIR/events.jsonl"
  HOOK_FAIL_EVENT=worker.start.after fm_hook_notify worker.start spawn 2>/dev/null || fail 'notify failure leaked'
  assert_events worker.start.after,worker.start.after
  config worker.start.before
  jq '.hooks += [.hooks[0]]' "$HOME_DIR/config/hooks.json" > "$CASE/new"
  cp "$CASE/new" "$HOME_DIR/config/hooks.json"
  run_contract >/dev/null 2>&1 && fail 'duplicate id accepted'
  config worker.start.before
  jq '.hooks[0].timeout_seconds=901' "$HOME_DIR/config/hooks.json" > "$CASE/new"
  cp "$CASE/new" "$HOME_DIR/config/hooks.json"
  run_contract >/dev/null 2>&1 && fail 'unbounded timeout accepted'
  config worker.start.after
  jq '.hooks[0].timeout_seconds=31' "$HOME_DIR/config/hooks.json" > "$CASE/new"
  cp "$CASE/new" "$HOME_DIR/config/hooks.json"
  fm_hook_begin worker.start spawn >/dev/null 2>&1 && fail 'oversized notification timeout accepted'
  config worker.start.before
  jq '.hooks += [.hooks[0] | .id="later-before"]' "$HOME_DIR/config/hooks.json" > "$CASE/new"
  cp "$CASE/new" "$HOME_DIR/config/hooks.json"
  : > "$HOME_DIR/events.jsonl"
  HOOK_FAIL_EVENT=worker.start.before run_contract >/dev/null 2>&1 && fail 'before refusal passed'
  assert_events worker.start.before
  config worker.start.before worker.start.after
  : > "$HOME_DIR/events.jsonl"
  ( cd "$CASE" && FM_HOME=home FM_CONFIG_OVERRIDE=home/config run_contract ) || fail 'relative home/config override failed'
  assert_events worker.start.before,worker.start.after
  pass 'runner: one config snapshot, duplicate/timeout validation and notify ordering'

}

prepare_spawn() {
  make_case "$1"
  PROJ="$CASE/project"
  WT="$CASE/worker"
  fm_git_worktree "$PROJ" "$WT" fm/task
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE")
  fm_test_spawn_brief "$HOME_DIR" task 'Connect every ERP system.'
  printf '\nDelivery contract: mode=local-only\n' >> "$HOME_DIR/data/task/brief.md"
}

spawn() {
  fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" task "$PROJ" "$@"
}

test_spawn() {
  local out flavor rc
  for flavor in ship scout raw; do
    prepare_spawn "spawn-$flavor"
    config worker.start.before worker.start.after
    rc=0
    case "$flavor" in
      scout) out=$(HOOK_FAIL_EVENT=worker.start.before spawn --scout 2>&1) || rc=$? ;;
      raw) out=$(HOOK_FAIL_EVENT=worker.start.before spawn 'printf raw' --mode local-only --yolo off 2>&1) || rc=$? ;;
      *) out=$(HOOK_FAIL_EVENT=worker.start.before spawn --mode local-only --yolo off 2>&1) || rc=$? ;;
    esac
    [ "$rc" -ne 0 ] || fail "$flavor: refusal ignored"
    assert_contains "$out" 'hook worker.start.before failed' "$flavor: did not reach gate"
    [ ! -e "$HOME_DIR/state/task.meta" ] || fail "$flavor: veto created metadata"
    assert_events worker.start.before
  done
  prepare_spawn spawn-pass
  config worker.start.before worker.start.after
  out=$(HOOK_BEHAVIOR=save spawn --mode local-only --yolo off 2>&1) || fail "spawn failed: $out"
  assert_events worker.start.before,worker.start.after
  local delivered
  delivered=$(jq -r 'select(.event=="worker.start.after") | .delivered_brief_path' "$HOME_DIR/events.jsonl")
  cmp -s "$delivered" "$HOME_DIR/evaluated-brief" || fail 'delivered brief differs from approved bytes'
  jq -es '.[0].worktree == null and .[1].worktree != null and .[0].kind == "ship"' "$HOME_DIR/events.jsonl" >/dev/null || fail 'start payload does not identify allocation boundary'
  # The general spawn fixture has no agent-state model; expose a plain shell
  # in the existing task window for recovery-grade relaunch preflight.
  mv "$FAKEBIN/tmux" "$FAKEBIN/tmux-default"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then printf 'fm-task\n'; exit 0; fi
case "$*" in *pane_current_command*) printf 'bash\n'; exit 0 ;; esac
exec "$(dirname "$0")/tmux-default" "$@"
SH
  chmod +x "$FAKEBIN/tmux"
  cp "$HOME_DIR/state/task.meta" "$CASE/before-relaunch.meta"
  : > "$HOME_DIR/events.jsonl"
  rc=0
  out=$(HOOK_FAIL_EVENT=worker.start.before fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" task --relaunch 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'relaunch veto ignored'
  assert_contains "$out" 'hook worker.start.before failed' 'relaunch did not reach shared gate'
  cmp -s "$HOME_DIR/state/task.meta" "$CASE/before-relaunch.meta" || fail 'veto rewrote relaunch task record'
  jq -es 'length==1 and .[0].operation=="relaunch" and .[0].worktree != null' "$HOME_DIR/events.jsonl" >/dev/null || fail 'relaunch context missing'
  pass 'spawn: ship/scout/raw/relaunch veto at shared gate; success delivers evaluated snapshot'
}

test_start_candidate_drift() {
  local out rc=0
  prepare_spawn spawn-drift
  config worker.start.before worker.start.after
  mv "$FAKEBIN/tmux" "$FAKEBIN/tmux-default"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = new-window ]; then
  printf 'changed during allocation\n' >> "$FM_HOME/data/task/launch-brief.md"
fi
exec "$(dirname "$0")/tmux-default" "$@"
SH
  chmod +x "$FAKEBIN/tmux"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" spawn --mode local-only --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'candidate drift allowed a worker to launch'
  assert_contains "$out" 'approved candidate changed' 'candidate drift was not detected at delivery'
  [ ! -s "$CASE/launch.log" ] || fail 'worker launch was delivered before drift refusal'
  assert_events worker.start.before
  pass 'start: changed candidate between admission and delivery refuses without launching'
}

test_promotion() {
  local out rc
  make_case promotion
  mkdir -p "$HOME_DIR/data/task"
  fm_test_spawn_brief "$HOME_DIR" task 'Build all connectors.'
  printf 'kind=scout\nwindow=fm-task\nworktree=%s\n' "$CASE/worker" > "$HOME_DIR/state/task.meta"
  cp "$HOME_DIR/state/task.meta" "$CASE/original-meta"
  cp "$HOME_DIR/data/task/brief.md" "$CASE/original-brief"
  config worker.promote.before worker.promote.after
  rc=0
  out=$(HOOK_FAIL_EVENT=worker.promote.before "$ROOT/bin/fm-promote.sh" task --mode local-only --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'promotion veto ignored'
  assert_contains "$out" 'hook worker.promote.before failed' 'promotion did not reach gate'
  cmp -s "$CASE/original-meta" "$HOME_DIR/state/task.meta" || fail 'veto changed kind/mode'
  cmp -s "$CASE/original-brief" "$HOME_DIR/data/task/brief.md" || fail 'veto changed brief'
  [ ! -e "$HOME_DIR/data/task/ship-instructions.md" ] || fail 'veto published instructions'
  : > "$HOME_DIR/events.jsonl"
  out=$(HOOK_BEHAVIOR=save "$ROOT/bin/fm-promote.sh" task --mode local-only --yolo off 2>&1) || fail "promotion failed: $out"
  assert_events worker.promote.before,worker.promote.after
  cmp -s "$HOME_DIR/evaluated-brief" "$HOME_DIR/data/task/brief.md" || fail 'published brief differs from evaluated candidate'
  cmp -s "$HOME_DIR/evaluated-promotion_instructions" "$HOME_DIR/data/task/ship-instructions.md" || fail 'published instructions differ from candidate'
  pass 'promotion: veto preserves contract; success publishes evaluated candidates'
}

test_brief() {
  local kind out
  make_case brief
  config brief.generated.after
  for kind in scout ship secondmate; do
    if [ "$kind" = scout ]; then
      out=$("$ROOT/bin/fm-brief.sh" scout fixture --scout 2>&1) || fail "$out"
    elif [ "$kind" = secondmate ]; then
      out=$("$ROOT/bin/fm-brief.sh" mate fixture --secondmate 2>&1) || fail "$out"
    else
      out=$(HOOK_FAIL_EVENT=brief.generated.after "$ROOT/bin/fm-brief.sh" ship fixture --mode local-only 2>&1) || fail "$out"
    fi
  done
  assert_events brief.generated.after,brief.generated.after,brief.generated.after
  jq -es '.[0].kind == "scout" and .[1].kind == "ship" and .[2].kind == "secondmate" and all(.[]; .brief_sha256 != null and .before_invocation_id == null)' "$HOME_DIR/events.jsonl" >/dev/null || fail 'generated payload invalid'
  pass 'brief: ship/scout/charter notifications run after generation and cannot veto'
}

test_cancellation_and_output_bound() {
  local pid child state i out rc=0
  make_case cancellation
  config worker.start.before
  jq '.hooks[0].timeout_seconds=30' "$HOME_DIR/config/hooks.json" > "$CASE/new"
  cp "$CASE/new" "$HOME_DIR/config/hooks.json"
  HOOK_BEHAVIOR=timeout bash -c '. "$1"; fm_hook_begin worker.start spawn && fm_hook_before' _ "$ROOT/bin/fm-hook-lib.sh" > "$CASE/cancel.log" 2>&1 &
  pid=$!
  for ((i=0; i<100; i++)); do [ ! -s "$HOME_DIR/hook-child.pid" ] || break; sleep 0.1; done
  [ -s "$HOME_DIR/hook-child.pid" ] || { kill -TERM "$pid"; fail 'hook child did not start'; }
  child=$(cat "$HOME_DIR/hook-child.pid")
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  state=alive
  for ((i=0; i<100; i++)); do
    state=$(ps -o stat= -p "$child" 2>/dev/null | tr -d '[:space:]')
    case "$state" in ''|Z*) break ;; esac
    sleep 0.1
  done
  case "$state" in ''|Z*) ;; *) kill "$child" 2>/dev/null || true; fail 'cancelled hook left a running descendant' ;; esac
  out=$(HOOK_BEHAVIOR=noisy run_contract 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'noisy refusal passed'
  [ "${#out}" -le 9000 ] || fail 'diagnostics exceed bounded tail'
  assert_contains "$out" 'diagnostic line 9999' 'diagnostic tail was lost'
  pass 'runner: cancellation reaps owned group and diagnostics retain only a bounded tail'
}

test_ambient_variables() {
  local rc out
  make_case ambient
  cat > "$CASE/env hook" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n%s\n%s\n%s\n' "$FM_CONFIG_OVERRIDE" "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE" "$FM_PROJECTS_OVERRIDE" > "$FM_HOME/seen-dirs"
echo 'ambient gate ran' >&2
exit 7
SH
  chmod +x "$CASE/env hook"
  jq -nc --arg c "$CASE/env hook" '{version:1,hooks:[{id:"gate",event:"task.steer.before",argv:[$c]}]}' > "$HOME_DIR/config/hooks.json"
  chmod 600 "$HOME_DIR/config/hooks.json"
  mkdir -p "$CASE/elsewhere"
  rc=0
  # shellcheck disable=SC2016 # $1 expands in the child shell.
  out=$(env -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    CONFIG="$CASE/elsewhere" STATE="$CASE/elsewhere" DATA="$CASE/elsewhere" PROJECTS="$CASE/elsewhere" \
    bash -c '. "$1/bin/fm-hook-lib.sh"; fm_hook_begin task.steer steer task_id t && fm_hook_before' _ "$ROOT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'unrelated CONFIG variable disabled the blocking gate'
  assert_contains "$out" 'ambient gate ran' 'gate did not run from FM_HOME/config'
  printf '%s\n%s\n%s\n%s\n' "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" > "$CASE/expected-dirs"
  cmp -s "$HOME_DIR/seen-dirs" "$CASE/expected-dirs" || fail 'unrelated shell variables reached the hook as directory overrides'
  rm -f "$HOME_DIR/seen-dirs"
  rc=0
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$CASE/elsewhere" \
    bash -c '. "$1/bin/fm-hook-lib.sh"; fm_hook_begin task.steer steer task_id t && fm_hook_before' _ "$ROOT" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail 'FM_CONFIG_OVERRIDE was not honored'
  [ "$(sed -n 3p "$HOME_DIR/seen-dirs")" = "$CASE/elsewhere" ] || fail 'FM_DATA_OVERRIDE was not forwarded'
  pass 'runner: only FM_* overrides, not ambient CONFIG/STATE/DATA/PROJECTS, locate hook inputs'
}

test_runner
test_ambient_variables
test_cancellation_and_output_bound
test_snapshot_and_notify_order
test_spawn
test_start_candidate_drift
test_promotion
test_brief

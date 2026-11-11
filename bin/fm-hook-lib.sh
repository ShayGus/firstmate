#!/usr/bin/env bash
# Home-local lifecycle command hooks; contract: docs/lifecycle-hooks.md.
# Source this library, then fm_hook_begin <event-prefix> <operation> [key value...],
# fm_hook_before, and (only after success) fm_hook_after [key value...].
# fm_hook_begin snapshots config and candidate digests once per action.
# fm_hook_unchanged rechecks approved candidate bytes at publication/delivery.
# After-only events use fm_hook_notify <event-prefix> <operation> [key value...].
# No configuration means no commands, JSON tooling, or temporary files.

_FM_HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_HOOK_LIB_DIR/fm-timeout-lib.sh"

fm_hook_absolute() {
  case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac
}

fm_hook_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | awk '{print $1}'
  else
    sha256sum < "$1" | awk '{print $1}'
  fi
}

fm_hook_error() {
  printf 'error: lifecycle hook %s: %s\n' "${FM_HOOK_PREFIX:-unknown}" "$*" >&2
  return 1
}

# These action-scoped results deliberately remain in the invoking shell.
# shellcheck disable=SC2034
fm_hook_begin() {
  FM_HOOK_ACTIVE=0
  FM_HOOK_PREFIX=$1
  local operation=$2 home=${FM_HOME:-} config file attrs uid permissions key value digest meta task_id state data projects
  shift 2
  config=${FM_CONFIG_OVERRIDE:-$home/config}
  file="$config/hooks.json"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    # A failed lookup through an inaccessible ancestor is not proven absence.
    local parent=$config next
    while [ ! -e "$parent" ] && [ ! -L "$parent" ]; do
      next=${parent%/*}
      [ "$next" != "$parent" ] || next=.
      [ -n "$next" ] || next=/
      [ "$next" != "$parent" ] || break
      parent=$next
    done
    [ -d "$parent" ] && [ -x "$parent" ] || { fm_hook_error "config directory inaccessible: $config"; return 1; }
    return 0
  fi
  FM_HOOK_ACTIVE=1
  config=$(fm_hook_absolute "$config") || return 1
  state=$(fm_hook_absolute "${FM_STATE_OVERRIDE:-$home/state}") || return 1
  data=$(fm_hook_absolute "${FM_DATA_OVERRIDE:-$home/data}") || return 1
  projects=$(fm_hook_absolute "${FM_PROJECTS_OVERRIDE:-$home/projects}") || return 1
  FM_HOOK_CONFIG_DIR=$config
  FM_HOOK_STATE_DIR=$state
  FM_HOOK_DATA_DIR=$data
  FM_HOOK_PROJECTS_DIR=$projects
  FM_HOOK_SNAPSHOT=
  FM_HOOK_PAYLOAD=
  FM_HOOK_BEFORE_ID=
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || fm_hook_error "not a readable regular config: $file" || return 1
  if [ "$(uname -s)" = Darwin ]; then
    attrs=$(stat -f '%u %Lp' "$file") || return 1
  else
    attrs=$(stat -c '%u %a' "$file") || return 1
  fi
  read -r uid permissions <<< "$attrs"
  [ "$uid" = "$(id -u)" ] && [ "$((8#$permissions & 022))" -eq 0 ] || fm_hook_error "config must be user-owned and not group/world writable: $file" || return 1
  FM_HOOK_SNAPSHOT=$(cat "$file") || return 1
  if ! printf '%s' "$FM_HOOK_SNAPSHOT" | jq -se '
    def events: ["worker.start.before","worker.start.after","worker.promote.before","worker.promote.after","brief.generated.after","task.steer.before","task.steer.after","task.merge.before","task.merge.after","task.cleanup.before","task.cleanup.after"];
    length == 1 and (.[0] | type == "object" and (keys - ["version","hooks"] == []) and .version == 1 and
    (.hooks | type == "array") and
    ([.hooks[].id] | length == (unique | length)) and
    all(.hooks[];
      type == "object" and (keys - ["id","event","argv","timeout_seconds"] == []) and
      (.id | type == "string" and length > 0 and (contains("\u0000") | not)) and
      (.event as $e | events | index($e) != null) and
      (.argv | type == "array" and length > 0 and all(.[]; type == "string" and (contains("\u0000") | not))) and
      (.argv[0] | startswith("/")) and
      ((has("timeout_seconds") | not) or
        (.timeout_seconds | type == "number" and floor == . and . > 0) and
        (.timeout_seconds <= (if .event | endswith(".before") then 900 else 30 end)))))
  ' >/dev/null 2>&1; then
    fm_hook_error "invalid version 1 config: $file"
    return 1
  fi
  [ -d "$home" ] && home=$(cd "$home" && pwd -P) || return 1
  FM_HOOK_PAYLOAD=$(jq -n --arg home "$home" --arg operation "$operation" '
    {version:1,home:$home,operation:$operation,task_id:null,kind:null,project:null,
     mode:null,yolo:null,harness:null,backend:null,branch:null,base_branch:null,
     source_brief_path:null,brief_path:null,brief_sha256:null,worktree:null}') || return 1
  task_id=
  local args=("$@") i
  for ((i=0; i+1<${#args[@]}; i+=2)); do
    [ "${args[i]}" != task_id ] || task_id=${args[i+1]}
  done
  meta="$state/$task_id.meta"
  if [ -n "$task_id" ] && [ -f "$meta" ] && [ ! -L "$meta" ]; then
    for key in kind project mode yolo harness backend branch base_branch worktree; do
      value=$(sed -n "s/^$key=//p" "$meta" | head -n 1)
      [ -n "$value" ] || continue
      [ "$value" != - ] || continue
      case "$key" in project|worktree) value=$(fm_hook_absolute "$value") || return 1 ;; esac
      FM_HOOK_PAYLOAD=$(printf '%s' "$FM_HOOK_PAYLOAD" | jq --arg key "$key" --arg value "$value" '.[$key]=$value') || return 1
    done
  fi
  while [ "$#" -ge 2 ]; do
    key=$1 value=$2
    shift 2
    case "$key" in
      project|worktree|source_brief_path|brief_path|promotion_instructions_path|inbox_record|delivered_brief_path)
        [ "$value" != - ] || value=
        [ -z "$value" ] || value=$(fm_hook_absolute "$value") || return 1
        ;;
    esac
    FM_HOOK_PAYLOAD=$(printf '%s' "$FM_HOOK_PAYLOAD" | jq --arg key "$key" --arg value "$value" '.[$key] = (if $value == "" then null else $value end)') || return 1
  done
  for key in brief promotion_instructions; do
    value=$(printf '%s' "$FM_HOOK_PAYLOAD" | jq -r --arg key "${key}_path" '.[$key] // empty') || return 1
    [ -n "$value" ] || continue
    case "$value" in /*) ;; *) fm_hook_error "candidate path is not absolute: $value"; return 1 ;; esac
    [ -f "$value" ] && [ -r "$value" ] || { fm_hook_error "candidate unreadable: $value"; return 1; }
    digest=$(fm_hook_digest "$value") || return 1
    FM_HOOK_PAYLOAD=$(printf '%s' "$FM_HOOK_PAYLOAD" | jq --arg key "${key}_sha256" --arg value "$digest" '.[$key]=$value') || return 1
  done
}

fm_hook_unchanged() {
  [ "${FM_HOOK_ACTIVE:-0}" = 1 ] || return 0
  local key path expected actual
  for key in brief promotion_instructions; do
    path=$(printf '%s' "$FM_HOOK_PAYLOAD" | jq -r --arg key "${key}_path" '.[$key] // empty') || return 1
    [ -n "$path" ] || continue
    expected=$(printf '%s' "$FM_HOOK_PAYLOAD" | jq -r --arg key "${key}_sha256" '.[$key]') || return 1
    actual=$(fm_hook_digest "$path") || return 1
    [ "$actual" = "$expected" ] || { fm_hook_error "approved candidate changed: $path"; return 1; }
  done
}

fm_hook_run() {
  local phase=$1 event="${FM_HOOK_PREFIX}.$1" payload invocation row id seconds rc output encoded value hook_home
  local argv=()
  [ "${FM_HOOK_ACTIVE:-0}" = 1 ] || return 0
  invocation="$(date +%s)-${BASHPID:-$$}-$RANDOM-$RANDOM"
  if [ "$phase" = before ]; then FM_HOOK_BEFORE_ID=$invocation; fi
  payload=$(printf '%s' "$FM_HOOK_PAYLOAD" | jq --arg event "$event" --arg invocation "$invocation" \
    --arg before "${FM_HOOK_BEFORE_ID:-}" --argjson timestamp "$(date +%s)" \
    '. + {event:$event,invocation_id:$invocation,timestamp:$timestamp} |
     if $event | endswith(".after") then . + {before_invocation_id:(if $before == "" then null else $before end)} else . end') || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r .id) || return 1
    seconds=$(printf '%s' "$row" | jq -r --arg phase "$phase" '.timeout_seconds // (if $phase == "before" then 120 else 5 end)') || return 1
    argv=()
    while IFS= read -r encoded; do
      # NUL framing preserves literal newlines, spaces and trailing newlines.
      IFS= read -r -d '' value < <(printf '%s' "$encoded" | jq -j '. + "\u0000"') || true
      argv+=("$value")
    done < <(printf '%s' "$row" | jq -c '.argv[]')
    rc=0
    output=$(mktemp "${TMPDIR:-/tmp}/fm-hook.XXXXXX") || return 1
    if [ ! -f "${argv[0]}" ] || [ ! -x "${argv[0]}" ]; then
      rc=127
      printf 'executable missing or not executable: %s\n' "${argv[0]}" > "$output"
    else
      # Bound the entire pipeline, including descendants holding its output open.
      hook_home=$(printf '%s' "$payload" | jq -r .home) || return 1
      # shellcheck disable=SC2016 # Child shell expands its own argv and PIPESTATUS.
      (cd "$hook_home" &&
        export FM_HOME="$hook_home" FM_CONFIG_OVERRIDE="$FM_HOOK_CONFIG_DIR" \
          FM_STATE_OVERRIDE="$FM_HOOK_STATE_DIR" FM_DATA_OVERRIDE="$FM_HOOK_DATA_DIR" \
          FM_PROJECTS_OVERRIDE="$FM_HOOK_PROJECTS_DIR" &&
        fm_exec_timed "$seconds" 1 bash -c '"$@" 2>&1 | tail -c 8192; exit "${PIPESTATUS[0]}"' _ "${argv[@]}"
      ) <<< "$payload" > "$output" 2>&1 || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      printf '%s: hook %s failed %s (exit %s; timeout bound %ss)\n' \
        "$(if [ "$phase" = before ]; then printf error; else printf warning; fi)" "$id" "$event" "$rc" "$seconds" >&2
      tail -c 8192 "$output" >&2
    fi
    rm -f "$output"
    if [ "$rc" -ne 0 ] && [ "$phase" = before ]; then return 1; fi
  done < <(printf '%s' "$FM_HOOK_SNAPSHOT" | jq -c --arg event "$event" '.hooks[] | select(.event == $event)')
}

fm_hook_before() {
  fm_hook_run before && fm_hook_unchanged
}

# shellcheck disable=SC2120 # Optional payload updates; most callers need none.
fm_hook_after() {
  [ "${FM_HOOK_ACTIVE:-0}" = 1 ] || return 0
  local key value
  while [ "$#" -ge 2 ]; do
    key=$1 value=$2
    shift 2
    case "$key" in
      project|worktree|source_brief_path|brief_path|promotion_instructions_path|inbox_record|delivered_brief_path)
        [ "$value" != - ] || value=
        [ -z "$value" ] || value=$(fm_hook_absolute "$value") || break
        ;;
    esac
    FM_HOOK_PAYLOAD=$(printf '%s' "$FM_HOOK_PAYLOAD" | jq --arg key "$key" --arg value "$value" '.[$key]=(if $value == "" then null else $value end)') || break
  done
  fm_hook_run after || printf 'warning: lifecycle notification failed: %s.after\n' "$FM_HOOK_PREFIX" >&2
  return 0
}

fm_hook_notify() {
  if fm_hook_begin "$@"; then
    # shellcheck disable=SC2119 # This after-only event has no updates.
    fm_hook_after
  else
    printf 'warning: lifecycle notification unavailable: %s.after\n' "$1" >&2
  fi
  return 0
}

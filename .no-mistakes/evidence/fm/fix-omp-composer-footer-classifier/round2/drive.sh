#!/usr/bin/env bash
# Live driver: launch omp in the Firstmate worker posture inside the named Herdr lab,
# then classify the pane through the real fm_backend_herdr_composer_state.
set -u
R=/home/shayg/.no-mistakes/worktrees/f4bb769f35f8/01M39SN6G9D40EFA3V9GBC85A0
E=/home/shayg/.no-mistakes/evidence/01M39SN6G9D40EFA3V9GBC85A0/round2
S=$(cat $E/lab-session.txt)
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
lab() { "$R/bin/fm-herdr-lab.sh" run "$S" "$@"; }
FAKEBIN=$E/fakebin; mkdir -p $FAKEBIN
cat > $FAKEBIN/herdr <<'X'
#!/usr/bin/env bash
set -u
args=("$@"); last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then unset "args[$last]" "args[$flag]"; fi
set -- "${args[@]}"
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
X
chmod +x $FAKEBIN/herdr
export HERDR_LAB_SESSION=$S HERDR_ORIGINAL_PATH=$PATH HERDR_LAB_HELPER=$R/bin/fm-herdr-lab.sh
state() {  # <pane>
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_composer_state "$2:$3"' _ "$R" "$S" "$1"
}
capture() { lab pane read "$1" --source visible --format ansi 2>/dev/null || lab pane read "$1" 2>/dev/null; }
launch() {  # <label> <extra omp args...>
  local label=$1; shift
  local tab pane
  tab=$(lab tab create --workspace "$WS" --cwd /tmp/fm-omp-lab-proj2 --label "$label" --no-focus) || return 1
  pane=$(printf '%s' "$tab" | jq -r '.result.root_pane.pane_id')
  lab pane run "$pane" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 omp --config $R/.omp/fm-worker-overlay.yml $* --auto-approve --cwd /tmp/fm-omp-lab-proj2" >/dev/null
  printf '%s\n' "$pane"
}
state_base() {  # <pane> : same live read through base d4f3b78's backend/classifier
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_composer_state "$2:$3"' _ /tmp/fm-omp-base-d4f3b78 "$S" "$1"
}
"$@"

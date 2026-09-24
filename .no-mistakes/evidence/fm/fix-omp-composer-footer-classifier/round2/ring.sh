#!/usr/bin/env bash
# Drive Firstmate's real doorbell (fm_task_inbox_ring from bin/fm-task-inbox-lib.sh)
# against a live omp pane in the Herdr lab. Prints the ring return code:
# 0 rang, 1 skipped (composer visibly holds pending text), 2 send failed, 3 dead.
set -u
R=/home/shayg/.no-mistakes/worktrees/f4bb769f35f8/01M39SN6G9D40EFA3V9GBC85A0
E=/home/shayg/.no-mistakes/evidence/01M39SN6G9D40EFA3V9GBC85A0/round2
S=$(cat $E/lab-session.txt)
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export HERDR_LAB_SESSION=$S HERDR_ORIGINAL_PATH=$PATH HERDR_LAB_HELPER=$R/bin/fm-herdr-lab.sh
PATH="$E/fakebin:$PATH" bash -c '
  . "$1/bin/fm-backend.sh"; . "$1/bin/fm-task-inbox-lib.sh"
  rc=0; fm_task_inbox_ring herdr "$2:$3" "$4" || rc=$?; echo "ring_rc=$rc"' _ "$R" "$S" "$1" "$2"

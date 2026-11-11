#!/usr/bin/env bash
cd {run-worktree}
export FM_HOME=/tmp/fm-lab.VHYAC0 HOME=/tmp/fm-lab.VHYAC0/user-home
echo '=== S5 fm-send.sh erp2 narrowing steer (expect veto)'
bin/fm-send.sh erp2 'Change of plan: ERPNext only.'; echo "rc=$?"
ls $FM_HOME/state/ | grep -i inbox; find $FM_HOME/state -path '*inbox*' -type f | head
echo '=== S6 fm-send.sh erp2 ordinary steer (expect delivery)'
bin/fm-send.sh erp2 'Please add tests for every ERP adapter.'; echo "rc=$?"
find $FM_HOME/state -path '*inbox*' -type f | head
echo '=== S7 fm-teardown.sh erp2 (cleanup before/after)'
bin/fm-teardown.sh erp2 --force; echo "rc=$?"
ls $FM_HOME/state/erp2.meta 2>/dev/null || echo "meta removed"
echo DRIVE-DONE

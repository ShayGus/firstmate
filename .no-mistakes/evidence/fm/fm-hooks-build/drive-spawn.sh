#!/usr/bin/env bash
set -u
cd {run-worktree}
export FM_HOME=/tmp/fm-lab.VHYAC0 HOME=/tmp/fm-lab.VHYAC0/user-home
P=$FM_HOME/projects/erp
echo "TMUX=$TMUX"
echo '=== S1 fm-brief.sh ship (brief.generated.after notify)'
bin/fm-brief.sh erp1 erp --mode local-only; echo "rc=$?"
for id in erp1 erp2; do
cat > $FM_HOME/data/$id/brief.md.new <<'B'
# Task
## Captain's intent
Connect every ERP system to the ledger.

## Firstmate spec
SCOPE_LINE

Delivery contract: mode=local-only
B
done
mkdir -p $FM_HOME/data/erp2
sed 's/SCOPE_LINE/Implement the connector for ERPNext only./' $FM_HOME/data/erp1/brief.md.new > $FM_HOME/data/erp1/brief.md
sed 's/SCOPE_LINE/Implement a connector interface covering every ERP system./' $FM_HOME/data/erp1/brief.md.new > $FM_HOME/data/erp2/brief.md
printf 'Connect every ERP system to the ledger.\n' > $FM_HOME/records/erp1.request
printf 'Connect every ERP system to the ledger.\n' > $FM_HOME/records/erp2.request
echo '=== S2 fm-spawn.sh erp1 with ERPNext-only instructions (expect veto)'
bin/fm-spawn.sh erp1 $P --mode local-only --yolo off; echo "rc=$?"
echo "meta exists? $(ls $FM_HOME/state/erp1.meta 2>/dev/null || echo no)"
echo "tmux windows:"; tmux list-windows -a -F '#{session_name}:#{window_name}'
echo '=== S3 fm-spawn.sh erp3 with no request record (checker cannot compare -> veto)'
mkdir -p $FM_HOME/data/erp3; cp $FM_HOME/data/erp2/brief.md $FM_HOME/data/erp3/brief.md
bin/fm-spawn.sh erp3 $P --mode local-only --yolo off; echo "rc=$?"
echo '=== S4 fm-spawn.sh erp2 raw command with matching instructions (expect launch)'
bin/fm-spawn.sh erp2 $P 'bash -c "echo raw-worker-up; sleep 300"' --mode local-only --yolo off; echo "rc=$?"
echo "meta:"; cat $FM_HOME/state/erp2.meta 2>/dev/null | head -20
echo "tmux windows:"; tmux list-windows -a -F '#{session_name}:#{window_name}'
echo DRIVE-DONE

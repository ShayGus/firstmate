# Lifecycle command hooks

Each dispatching home can opt in with its own `config/hooks.json`.
Firstmate invokes these hooks in its shared lifecycle scripts, independently of the primary harness, worker harness, or runtime backend.
Without that file, lifecycle behavior is unchanged.
Hooks run trusted operator code, with the privileges of the invoking user; this interface is an integrity boundary, not an operating-system sandbox.

## Configuration

```json
{
  "version": 1,
  "hooks": [
    {
      "id": "instruction-check",
      "event": "worker.start.before",
      "argv": ["/absolute/path/to/check-instructions", "literal argument"],
      "timeout_seconds": 300
    },
    {
      "id": "promotion-check",
      "event": "worker.promote.before",
      "argv": ["/absolute/path/to/check-instructions"]
    }
  ]
}
```

`version` and `hooks` are required.
Each hook requires a unique nonempty `id`, an exact event name, and a nonempty array of literal string arguments in `argv`.
`argv[0]` must name an absolute executable file.
There is no shell expansion, interpolation, command discovery, package installation, or project-local hook discovery.
Use an operator-owned wrapper for service calls or additional processing.
The optional `timeout_seconds` is a positive integer: before hooks default to 120 seconds with a maximum of 900; after hooks default to 5 seconds with a maximum of 30.
Unknown fields, versions, duplicate ids, invalid commands, and unknown events are errors.
The config must be a readable regular file owned by the invoking user, not a symlink or group/world writable file.

The runner reads and validates one config snapshot per action, in array order.
It resolves configuration through `FM_CONFIG_OVERRIDE`, otherwise the invoking script's resolved config directory or `FM_HOME/config`.
Hooks run from `FM_HOME`, inheriting the invoking process's environment with explicit `FM_HOME` and resolved config, state, data, and projects overrides.
They do not inherit a worker pane's later environment.
Enable hooks separately in every dispatching home; configuration is not inherited by secondmate homes, and executable paths must work on that home's host.

## Events and success points

| Event | Boundary |
| --- | --- |
| `worker.start.before` | Fresh ship/scout, raw command, and relaunch, after built-in brief/admission preflight and before endpoint or worktree allocation. |
| `worker.start.after` | Established successful launch, after durable task/backlog publication and confirmed delivery; an unconfirmed T3 delivery emits no success event. |
| `worker.promote.before` | Both candidate files are staged, before publishing instructions, relaunch brief, or changed kind/mode. |
| `worker.promote.after` | Promotion contract and metadata have been published; this does not mean the worker read them. |
| `brief.generated.after` | After successfully writing a ship/scout scaffold with its configured include, or a secondmate charter; placeholders may still require filling. |
| `task.steer.before` | Before durable inbox enqueue, on both local and remote text paths. |
| `task.steer.after` | Enqueue is confirmed durable, before best-effort doorbell and reply bookkeeping; this does not mean the worker read or acted on the message. |
| `task.merge.before` | After built-in local/forge merge checks and before performing a merge; pinned head and authority are checked again after the hook. |
| `task.merge.after` | Confirmed local landing, or confirmed PR landing through the shared outcome publisher, including poll-discovered merges. |
| `task.cleanup.before` | After cleanup preflight and before concluding runs, closing endpoints, or returning the local copy. |
| `task.cleanup.after` | Complete cleanup and final records; refused, partial, and lost-slot warning outcomes emit no success event. |

Secondmate launch is outside the worker event catalog; charter generation emits `brief.generated.after`.
Local harness-native commands (leading `/`, or leading `$` for Codex), explicit endpoint targets, and key presses use the typed plane rather than durable steering, so they emit no steer events.
Remote task selectors always use the durable plane, including slash commands.
Remote transport retries reuse the same action snapshot and before invocation; an explicit caller retry is a new hook attempt, while existing inbox deduplication still applies.
An unconfirmed remote delivery emits no after event even if the remote record actually landed.
An external merge cannot be vetoed retroactively: its poll emits only `task.merge.after`, with operation `poll`.
Merge-queue acceptance is not landing; the existing poll supplies the after event when landing is confirmed.
Reported `done`, `blocked`, and `needs-decision` states have no universal write call and remain on the existing [fleet activity ledger](fleet-ledger.md).

## Input and verdict

Each hook receives one UTF-8 JSON object on standard input.
Core fields are `version` (1), `event`, `operation`, `invocation_id`, `timestamp` (Unix seconds), `home`, `task_id`, `kind`, `project`, `mode`, `yolo`, `harness`, `backend`, `branch`, `base_branch`, `source_brief_path`, `brief_path`, `brief_sha256`, and `worktree`.
Unavailable values are JSON `null`; paths are absolute.
`operation` distinguishes `spawn`, `relaunch`, `promote`, `brief`, `steer`, `pr`, `local`, `poll`, and `cleanup`.
`brief_path` identifies the actual candidate, including the worker-role/delivery overlay on start, with its SHA-256 digest in `brief_sha256`.
Fresh start has a null `worktree`; relaunch includes its known copy.
Promotion supplies the proposed ship kind/mode, `previous_kind: scout`, and `promotion_instructions_path` with `promotion_instructions_sha256` for the staged instructions.
Its `brief_path` identifies the proposed relaunch brief, not the old scout contract.
Successful promotion publishes those evaluated bytes; after-event paths refer to the published files.
Start delivers a unique approved snapshot, verifies both candidate and snapshot before delivery, and refuses changed bytes rather than reusing a stale approval.
The unique delivered snapshot remains with the task's data for inspection and later reads by file-based harnesses.
Relaunch and retries always run a fresh check.

Event-specific fields include `raw_command` on start; `message`, `target`, `remote_host`, `correlation_id`, and local `inbox_record` on steering; and `pr_url` or `pinned_head` on merge.
After events include `before_invocation_id` to link the successful action to its before invocation; after-only and externally observed events use null.
`invocation_id` is unique per event attempt, shared by all matching commands for that event.
Consumers should tolerate additive fields; incompatible schema changes require a new version.

Exit 0 permits a before action to continue through all existing guards.
Any nonzero exit, missing executable, timeout, signal, invalid/unreadable configuration, or changed candidate stops the action.
Before hooks run serially, stopping on the first failure.
Diagnostics identify the event, hook id and exit/bound, with at most the final 8192 bytes of command output.
The runner uses [the shared bounded-execution library](../bin/fm-timeout-lib.sh) to terminate its owned process group on timeout or cancellation, with one second of termination grace.
There is no bypass flag or approval cache.
A hook never grants merge approval, waives required checks, or overrides landed-work safety.

After hooks are one bounded try each, attempting every matching hook even after a failure.
Failures warn without rejecting, rolling back, or changing the successful action's exit status.
Notification adds bounded return latency after success; it is not queued, retried, replayed, or guaranteed exactly once.
Interruption can lose notifications and caller retries can repeat them; use the ledger when a durable feed is needed.
Stdout and stderr are diagnostic text, never instructions or shell code for Firstmate.

Keep hooks observational: do not call mutating Firstmate commands from inside a hook.
Some seams hold admission or lifecycle locks, so recursive spawn, send, merge, or cleanup can deadlock until timeout.
Start refusal creates no fresh worker record or endpoint and leaves a queued backlog item queued; a refused relaunch preserves its existing record and worktree.
Existing relaunch recovery preflight can contact a backend before the gate, but no replacement worker starts after a veto.

## Connecting an instruction checker

The external checker owns the mapping from `home` and `task_id` to its authoritative original request, design and plan task.
It reads the evaluated candidate files, compares their scope against those independent records, and exits nonzero on mismatch or unavailable comparison.
For example, a request covering every ERP system must refuse instructions limited to ERPNext.
Firstmate enforces the command's verdict; semantic comparison quality belongs to the external checker.
This repository does not ship or install the software-factory adapter, its source lookup policy, credentials, or comparison model.

Behavior regressions are exercised by `tests/fm-lifecycle-hooks.test.sh` and the existing steering, merge, and cleanup suites.

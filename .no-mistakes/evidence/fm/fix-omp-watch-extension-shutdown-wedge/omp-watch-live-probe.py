import json
import os
import pathlib
import queue
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT = pathlib.Path.cwd()
LAB = pathlib.Path(tempfile.mkdtemp(prefix=".omp-watch-probe-", dir=ROOT))
PROJECT = LAB / "project"
EVENTS = queue.Queue()
PROCESS = None


def cleanup():
    if PROCESS is not None:
        try:
            os.killpg(PROCESS.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            PROCESS.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(PROCESS.pid, signal.SIGKILL)
            PROCESS.wait()
    rows = subprocess.run(["ps", "-eo", "pid=,args="], text=True, capture_output=True).stdout
    for row in rows.splitlines():
        if str(PROJECT) not in row:
            continue
        try:
            pid = int(row.strip().split(None, 1)[0])
            os.kill(pid, signal.SIGTERM)
        except (ValueError, ProcessLookupError):
            pass
    shutil.rmtree(LAB, ignore_errors=True)


def next_event(timeout=30):
    return EVENTS.get(timeout=timeout)


def send(command_id, message):
    payload = {"id": command_id, "type": "prompt", "message": message}
    PROCESS.stdin.write(json.dumps(payload) + "\n")
    PROCESS.stdin.flush()
    print("SEND", payload, flush=True)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        event = next_event(max(0.1, deadline - time.monotonic()))
        if event.get("type") == "extension_ui_request" and event.get("method") == "notify":
            print("NOTIFY", event.get("message"), flush=True)
        if event.get("id") == command_id and event.get("type") == "response":
            print("RESPONSE", event, flush=True)
            return event
    raise RuntimeError("RPC command timed out")


def watcher_pid():
    path = PROJECT / "state/.watch.lock/pid"
    if not path.exists():
        return None
    return path.read_text().strip()


def wait_for_watcher(previous=None, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pid = watcher_pid()
        if pid and pid != previous:
            try:
                os.kill(int(pid), 0)
                return pid
            except ProcessLookupError:
                pass
        time.sleep(0.2)
    raise RuntimeError(f"watcher not live (previous={previous}, current={watcher_pid()})")


try:
    subprocess.run(["git", "-c", "advice.detachedHead=false", "clone", "-q", str(ROOT), str(PROJECT)], check=True)
    for path in ("state", "config", "data"):
        (PROJECT / path).mkdir(exist_ok=True)
    probe = PROJECT / ".omp/extensions/fm-live-probe.ts"
    probe.write_text("""
import { writeFileSync } from 'node:fs';
import watch from './fm-primary-omp-watch.ts';
export default function (pi) {
  let shutdown;
  pi.on('session_start', () => writeFileSync(process.env.FM_HOME + '/state/.lock', process.pid + '\\n'));
  const proxy = new Proxy(pi, {
    get(target, key) {
      if (key === 'on') return (event, handler) => {
        if (event === 'session_shutdown') shutdown = handler;
        return target.on(event, handler);
      };
      const value = target[key];
      return typeof value === 'function' ? value.bind(target) : value;
    }
  });
  watch(proxy);
  pi.registerCommand('fm-probe-stale-shutdown', {
    description: 'Exercise a stale watcher shutdown while OMP stays open',
    handler: async (_args, ctx) => {
      await shutdown({ type: 'session_shutdown' }, ctx);
      ctx.ui.notify('probe: shutdown callback completed while OMP remains responsive', 'info');
    }
  });
}
""")
    env = os.environ.copy()
    env.update(FM_HOME=str(PROJECT), FM_ROOT_OVERRIDE=str(PROJECT), FM_OMP_HARNESS="omp", OMP_SKIP_SETUP="1", FM_POLL="1", FM_SIGNAL_GRACE="0", FM_HEARTBEAT="600")
    args = ["omp", "--mode", "rpc", "--no-session", "--no-extensions", "-e", str(probe), "--cwd", str(PROJECT), "--config", str(PROJECT / ".omp/fm-worker-overlay.yml"), "--auto-approve", "--model", "openai-codex/gpt-6-astra"]
    PROCESS = subprocess.Popen(args, cwd=PROJECT, env=env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, bufsize=1)
    def read_events():
        for line in PROCESS.stdout:
            try:
                EVENTS.put(json.loads(line))
            except json.JSONDecodeError:
                pass
    threading.Thread(target=read_events, daemon=True).start()
    ready = False
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        event = next_event(max(0.1, deadline - time.monotonic()))
        if event.get("type") == "ready":
            ready = True
            break
    assert ready, "OMP did not become ready"
    first = wait_for_watcher()
    print("INITIAL_WATCHER", first, flush=True)
    send("before", "/fm-watch-arm-omp")
    send("shutdown", "/fm-probe-stale-shutdown")
    assert PROCESS.poll() is None, "OMP exited after injected shutdown"
    # Allow the retiring arm and watcher to release the home lock.
    time.sleep(2)
    send("repair", "/fm-watch-arm-omp")
    second = wait_for_watcher(previous=first)
    print("RECOVERED_WATCHER", second, flush=True)
    send("repeat", "/fm-watch-arm-omp")
    assert watcher_pid() == second, "repeat arm changed watcher"
    send("turn", "Reply READY only. Do not use tools.")
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        event = next_event(max(0.1, deadline - time.monotonic()))
        if event.get("type") == "agent_end":
            print("FIRST_TURN_ENDED", flush=True)
            break
    else:
        raise RuntimeError("OMP did not finish first turn")
    (PROJECT / "state/omp-e2e.meta").touch()
    (PROJECT / "state/omp-e2e.status").write_text("done: recovery live report\n")
    deadline = time.monotonic() + 35
    wake = False
    while time.monotonic() < deadline:
        event = next_event(max(0.1, deadline - time.monotonic()))
        if event.get("type") != "message_start":
            continue
        message = event.get("message", {})
        if message.get("role") != "user":
            continue
        text = "".join(part.get("text", "") for part in message.get("content", []) if isinstance(part, dict))
        if "FIRSTMATE WATCHER WAKE: signal:" in text:
            wake = True
            print("WAKE", text.split("FIRSTMATE WATCHER WAKE:", 1)[1].split("\\n", 1)[0], flush=True)
            break
    assert wake, "no actionable wake after recovered watcher"
    print("RESULT", json.dumps({"omp_responsive": PROCESS.poll() is None, "watcher_replaced": first != second, "repeat_preserved": True, "report_delivered": wake}), flush=True)
finally:
    cleanup()

#!/usr/bin/env python3
"""Smoke test for ambxst-robo.

Starts its own ambxst-robo (and kills only that PID), connects as a client,
calls a few commands, then feeds fake hook events through the real relay
binary (ambxst-robo-hook) and shows what comes out on both sides.

By default everything is isolated: a private XDG_RUNTIME_DIR, XDG_CONFIG_HOME
and XDG_DATA_HOME in a temp dir, so the real Claude Code sessions on this
machine never reach this daemon and the real settings/recap are not touched.
Secrets are still read (read-only) from the real Secret Service, and hooks /
agents status from the real ~/.claude etc. (read-only).

    --real-runtime   use the real $XDG_RUNTIME_DIR instead (sockets ambxst-robo.sock
                     and ambxst-robo-core.sock): real sessions' hook events then show
                     up too. Fake requests are told apart by their session_id;
                     real permission requests are never acknowledged, so they
                     are released to the terminal within the ack timeout.

Usage: python3 smoke.py [--real-runtime] [--daemon PATH] [--relay PATH]
"""

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SESSION = "smoke-%d" % os.getpid()


def log(*a):
    print(*a, flush=True)


class Client:
    def __init__(self, path, name):
        self.name = name
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.file = self.sock.makefile("rwb", buffering=0)
        self.next_id = 1
        self.replies = {}
        self.events = []
        self.cv = threading.Condition()
        self.closed = False
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for raw in self.file:
            msg = json.loads(raw)
            with self.cv:
                if "event" in msg:
                    self.events.append(msg)
                else:
                    self.replies[msg.get("id")] = msg
                self.cv.notify_all()
        with self.cv:
            self.closed = True
            self.cv.notify_all()

    def send(self, cmd, args=None):
        with self.cv:
            rid = self.next_id
            self.next_id += 1
        line = json.dumps({"id": rid, "cmd": cmd, "args": args or {}}) + "\n"
        self.file.write(line.encode())
        return rid

    def wait_reply(self, rid, timeout=20):
        with self.cv:
            self.cv.wait_for(lambda: rid in self.replies or self.closed, timeout)
            return self.replies.pop(rid, None)

    def call(self, cmd, args=None, timeout=20):
        return self.wait_reply(self.send(cmd, args), timeout)

    def wait_event(self, pred, timeout=5):
        deadline = time.time() + timeout
        with self.cv:
            while True:
                for i, ev in enumerate(self.events):
                    if pred(ev):
                        return self.events.pop(i)
                left = deadline - time.time()
                if left <= 0:
                    return None
                self.cv.wait(left)

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


def short(v, n=220):
    s = json.dumps(v, ensure_ascii=False)
    return s if len(s) <= n else s[:n] + "…"


def ours(ev):
    return (
        ev.get("event") == "hook"
        and isinstance(ev.get("payload"), dict)
        and ev["payload"].get("session_id") == SESSION
    )


class Relay:
    """Runs ambxst-robo-hook once with a JSON payload on stdin."""

    def __init__(self, relay, env, payload):
        self.started = time.time()
        self.proc = subprocess.Popen(
            [relay], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env
        )
        self.proc.stdin.write(json.dumps(payload).encode())
        self.proc.stdin.close()

    def result(self, timeout=15):
        out = self.proc.stdout.read().decode().strip()
        self.proc.wait(timeout)
        return out, time.time() - self.started


def payload(event, **extra):
    p = {"hook_event_name": event, "session_id": SESSION, "cwd": HERE}
    p.update(extra)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--real-runtime", action="store_true")
    ap.add_argument("--daemon", default=os.path.join(HERE, "target/release/ambxst-robo"))
    ap.add_argument("--relay", default=None)
    opts = ap.parse_args()

    # Default: the relay built from the same source in this workspace (hook/).
    # --relay ~/.local/share/ambxst-robo/bin/ambxst-robo-hook uses the installed one.
    relay = opts.relay or os.path.join(HERE, "target/release/ambxst-robo-hook")

    tmp = tempfile.mkdtemp(prefix="coucou-smoke-")
    os.chmod(tmp, 0o700)
    env = dict(os.environ)
    env["XDG_CONFIG_HOME"] = os.path.join(tmp, "config")
    env["XDG_DATA_HOME"] = os.path.join(tmp, "data")
    if not opts.real_runtime:
        rt = os.path.join(tmp, "run")
        os.mkdir(rt, 0o700)
        env["XDG_RUNTIME_DIR"] = rt
    rt = env["XDG_RUNTIME_DIR"]
    core_sock = os.path.join(rt, "ambxst-robo-core.sock")
    log("daemon :", opts.daemon)
    log("relay  :", relay)
    log("runtime:", rt, "(real)" if opts.real_runtime else "(private)")

    daemon = subprocess.Popen([opts.daemon], env=env, stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            if os.path.exists(core_sock):
                break
            time.sleep(0.05)
        else:
            raise SystemExit("daemon did not come up")
        time.sleep(0.2)
        log("daemon pid", daemon.pid, "socket mode", oct(os.stat(core_sock).st_mode & 0o777))

        run(opts, env, relay, core_sock)
    finally:
        daemon.send_signal(signal.SIGTERM)
        try:
            daemon.wait(5)
        except subprocess.TimeoutExpired:
            daemon.kill()
        log("\n== shutdown ==")
        log("daemon exit", daemon.returncode,
            "| core socket left:", os.path.exists(core_sock),
            "| relay socket left:", os.path.exists(os.path.join(rt, "ambxst-robo.sock")))
        if os.environ.get("SMOKE_KEEP"):
            log("kept", tmp)
        else:
            shutil.rmtree(tmp, ignore_errors=True)


def run(opts, env, relay, core_sock):
    a = Client(core_sock, "A")

    log("\n== commands ==")
    r = a.call("boot")
    res = r["result"]
    log("boot ->", "ok" if r["ok"] else r, "| version", res["version"], "| relaySocket", res["relaySocket"],
        "| hookPath", res["hookPath"], "| settings keys", len(res["settings"]), "| screen", res["screen"])
    r = a.call("hooks_status")
    log("hooks_status ->", short(r))
    r = a.call("secret_present", {"key": "anthropic-api-key"})
    log("secret_present(anthropic-api-key) ->", short(r))
    r = a.call("agent_hooks_list")
    log("agent_hooks_list ->", r["ok"], [(x["id"], x["installed"]) for x in r["result"]])
    log("agent_hooks_status ->", short(a.call("agent_hooks_status")))
    log("hooks_preview(install=true) ->", short(a.call("hooks_preview", {"install": True}), 160))
    log("shortcuts_status ->", short(a.call("shortcuts_status"), 160))
    log("desktop_mascot_info ->", short(a.call("desktop_mascot_info")))
    log("custom_sounds ->", short(a.call("custom_sounds", {"names": ["finish", "approval", "greet"]})))
    log("set_collapsed (dropped) ->", short(a.call("set_collapsed", {"collapsed": True})))
    log("phone_link_status (dropped) ->", short(a.call("phone_link_status")))
    log("nonsense ->", short(a.call("nonsense")))

    log("\n== concurrency: codex_plan_usage in flight, ping answers meanwhile ==")
    slow = a.send("codex_plan_usage")
    t0 = time.time()
    a.call("ping")
    log("ping answered in %.0f ms while codex_plan_usage is running" % ((time.time() - t0) * 1000))

    log("\n== fire-and-forget hook events through the relay ==")
    for ev in [
        payload("SessionStart", source="startup"),
        payload("UserPromptSubmit", prompt="smoke test prompt"),
        payload("PreToolUse", tool_name="Bash", tool_input={"command": "echo smoke"}),
    ]:
        out, dt = Relay(relay, env, ev).result()
        got = a.wait_event(lambda e, n=ev["hook_event_name"]: ours(e) and e["payload"]["hook_event_name"] == n)
        log("%-17s relay %.0f ms stdout=%r -> event %s" % (ev["hook_event_name"], dt * 1000, out, short(got, 160)))
    rc = a.wait_event(lambda e: e["event"] == "recap-check", 1)
    log("recap-check event ->", short(rc))

    log("\n== PermissionRequest answered via approval_decision ==")
    rel = Relay(relay, env, payload("PermissionRequest", tool_name="Bash", tool_input={"command": "rm -rf /tmp/nothing"}))
    ev = a.wait_event(ours)
    rid = ev["payload"]["request_id"]
    log("event:", short(ev, 200))
    log("approval_ack ->", short(a.call("approval_ack", {"requestId": rid})))
    time.sleep(1.2)  # past the 800 ms ack timeout: the ack holds the request
    log("approval_decision allow ->", short(a.call("approval_decision", {"requestId": rid, "decision": "allow"})))
    out, dt = rel.result()
    log("relay stdout after %.2f s: %s" % (dt, out))

    log("\n== AskUserQuestion answered via approval_answer ==")
    q = {"questions": [{"question": "Which colour?", "header": "Colour", "multiSelect": False,
                        "options": [{"label": "Red", "description": ""}, {"label": "Blue", "description": ""}]}]}
    rel = Relay(relay, env, payload("PermissionRequest", tool_name="AskUserQuestion", tool_input=q))
    ev = a.wait_event(ours)
    rid = ev["payload"]["request_id"]
    a.call("approval_ack", {"requestId": rid})
    log("approval_answer ->", short(a.call("approval_answer", {"requestId": rid, "answers": {"Which colour?": "Blue"}})))
    out, dt = rel.result()
    log("relay stdout after %.2f s: %s" % (dt, out))

    log("\n== PermissionRequest, client connected but never acks (released by ack timeout) ==")
    rel = Relay(relay, env, payload("PermissionRequest", tool_name="Bash", tool_input={"command": "true"}))
    ev = a.wait_event(ours)
    out, dt = rel.result()
    log("event seen (request_id %s), no ack -> relay done after %.2f s, stdout=%r (empty = terminal asks)"
        % (ev["payload"]["request_id"], dt, out))

    log("\n== PermissionRequest acked, then the client disconnects ==")
    b = Client(core_sock, "B")
    rel = Relay(relay, env, payload("PermissionRequest", tool_name="Bash", tool_input={"command": "true"}))
    ev = b.wait_event(ours)
    b.call("approval_ack", {"requestId": ev["payload"]["request_id"]})
    a.wait_event(ours, 1)  # A saw it too; A does nothing
    time.sleep(1.0)
    t_close = time.time()
    b.close()
    out, _ = rel.result()
    log("B acked then closed -> relay done %.0f ms after the close, stdout=%r" % ((time.time() - t_close) * 1000, out))

    log("\n== shortcut from the CLI (ambxst-robo --shortcut openChat) ==")
    cp = subprocess.run([opts.daemon, "--shortcut", "openChat"], env=env, capture_output=True, text=True)
    log("exit", cp.returncode, "-> event", short(a.wait_event(lambda e: e["event"] == "shortcut", 2)))

    log("\n== single instance ==")
    cp = subprocess.run([opts.daemon], env=env, capture_output=True, text=True, timeout=10)
    log("second daemon exit", cp.returncode, "stderr:", cp.stderr.strip())

    r = a.wait_reply(slow, 30)
    log("\ncodex_plan_usage finally ->", short(r, 160))

    with a.cv:
        foreign = [e["payload"].get("hook_event_name") for e in a.events
                   if e.get("event") == "hook" and not ours(e)]
    log("\nreal (non-smoke) hook events seen meanwhile:", foreign or "none")

    log("\n== PermissionRequest with NO client connected ==")
    a.close()
    time.sleep(0.3)
    out, dt = Relay(relay, env, payload("PermissionRequest", tool_name="Bash", tool_input={"command": "true"})).result()
    log("no client -> relay done after %.0f ms, stdout=%r (empty = terminal asks)" % (dt * 1000, out))


if __name__ == "__main__":
    main()

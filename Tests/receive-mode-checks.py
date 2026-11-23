"""Exercise the bundled daemon's receive modes on isolated mailboxes and a stub Codex CLI."""
import json
import os
from pathlib import Path
import sqlite3
import socket
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="rn-mode-", dir="/tmp") as root:
    home = Path(root)
    state = home / "network"
    state.mkdir()
    stub = home / "codex"
    stub.write_text("""#!/bin/sh
if [ "$1 $2" = "queue --help" ]; then
  test ! -f "$HOME/unsupported" || exit 2
  if [ -f "$HOME/old-cli" ]; then echo 'codex queue --thread ID --message TEXT'; exit 0; fi
  echo 'codex queue --resume --thread ID --message TEXT'
  exit 0
fi
test "$1" = queue && test "$2" = --resume && test "$3" = --thread && test "$4" = alpha && test "$5" = --message || exit 2
echo "$6" >> "$HOME/pushed"
if [ -f "$HOME/resume-failed" ]; then
  echo 'Warning: message was queued, but could not resume thread alpha' >&2
fi
""")
    stub.chmod(0o700)
    env = dict(HOME=root, PATH="/usr/bin:/bin", REASON_NETWORK_HOME=str(state),
               REASON_NETWORK_CODEX_BIN=str(stub), REASON_NETWORK_LOCAL_PARTICIPATION="1",
               REASON_NETWORK_NO_TRAY="1", REASON_NETWORK_NO_SERVICE="1")
    proc = None

    def request(op, **args):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(8)
            sock.connect(str(state / "network.sock"))
            sock.sendall(json.dumps(dict(id=1, op=op, **args)).encode() + b'\n')
            return json.loads(sock.makefile('rb').readline())

    def call(op, **args):
        reply = request(op, **args)
        assert reply["ok"], reply.get("error")
        return reply["result"]

    def start():
        global proc
        proc = subprocess.Popen([binary, "daemon"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            assert proc.poll() is None, "daemon exited early"
            try:
                capabilities = call("session_participation")
                assert capabilities["receive_modes"] and capabilities["codex_queue_resume"] and capabilities["connection_recovery"]
                return
            except OSError:
                time.sleep(.08)
        raise TimeoutError("daemon startup")

    def stop():
        if proc and proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)

    def hook(name, mail=False):
        return call("hook", agent="codex", event="stop", session_id=name, name=name, cwd=root, mail=mail)

    def mode(value):
        return call("set_receive_mode", key="codex:alpha", network=network, mode=value)["effective"]

    def tiers():
        return {s["name"]: s["tier"] for s in call("who", all=False)["sessions"]}

    def send(text, wake=True):
        return call("send", **{"from": "codex:beta", "to": address, "body": text, "wake": wake})

    try:
        start()
        call("create_team", name="sample", person="qa")
        with sqlite3.connect(state / "network.db") as db:
            network = db.execute("SELECT json_extract(value,'$.id') FROM kv WHERE key='team'").fetchone()[0]
        proc.wait(timeout=10)
        start()
        address = hook("alpha")["address"]
        hook("beta")
        before = tiers()["beta"]
        assert mode("pull") == "pull"
        send("manual sample")
        assert not hook("alpha", mail=True).get("ids")
        msgs = call("inbox", key="codex:alpha", wait_secs=0, peek=False)["messages"]
        assert [m["body"] for m in msgs] == ["manual sample"]
        assert tiers()["beta"] == before and tiers()["alpha"] == "pull"
        assert mode("turn") == "turn"
        send("turn sample")
        delivered = hook("alpha", mail=True)
        assert "turn sample" in delivered["text"]
        call("delivered", key="codex:alpha", ids=delivered["ids"])
        assert not (home / "pushed").exists()
        (home / "unsupported").touch()
        denied = request("set_receive_mode", key="codex:alpha", network=network, mode="push")
        assert not denied["ok"] and "Codex" in denied["error"] and tiers()["alpha"] == "turn"
        (home / "unsupported").unlink()
        (home / "old-cli").touch()
        assert not request("set_receive_mode", key="codex:alpha", network=network, mode="push")["ok"]
        assert tiers()["alpha"] == "turn"
        (home / "old-cli").unlink()
        assert mode("push") == "push"
        send("quiet sample", wake=False)
        quiet = hook("alpha", mail=True)
        assert "quiet sample" in quiet["text"]
        call("delivered", key="codex:alpha", ids=quiet["ids"])
        assert not (home / "pushed").exists()
        send("push sample")
        for _ in range(100):
            if (home / "pushed").exists() and "push sample" in (home / "pushed").read_text():
                break
            time.sleep(.05)
        else:
            raise AssertionError("push did not reach the native CLI")
        (home / "resume-failed").touch()
        send("warning sample")
        for _ in range(100):
            if "codex:alpha" in call("session_participation")["resume_pending"]:
                break
            time.sleep(.05)
        else:
            raise AssertionError("missing diagnostic for an acknowledged queue with failed resume")
        assert not hook("alpha", mail=True).get("ids")
        assert not call("inbox", key="codex:alpha", wait_secs=0, peek=True)["messages"]
        assert (home / "pushed").read_text().count("warning sample") == 1
        (home / "resume-failed").unlink()
        send("recovered sample")
        for _ in range(100):
            if not call("session_participation")["resume_pending"]:
                break
            time.sleep(.05)
        else:
            raise AssertionError("stale wake warning after successful resume")
        assert mode("pull") == "pull"
        assert not request("set_receive_mode", network="previous", key="codex:alpha", mode="turn")["ok"]
        stop()
        start()
        hook("alpha")
        hook("beta")
        assert tiers()["alpha"] == "pull" and tiers()["beta"] == before
        call("set_session_participation", key="codex:alpha", paused=True)
        def register(name):
            return request("register", session=dict(key="codex:" + name, agent="codex", cwd=root, tier="pull"))
        paused = register("alpha")
        assert not paused["ok"] and paused["error"] == "Your user turned Reason Network off for this folder"
        assert register("beta")["ok"]
        assert "codex:alpha" in call("session_participation")["paused"]
        print("PASS: paused registration compatible with stock MCP, sibling can register")
        print("PASS: effective mode, manual inbox, turn hook, native wake, FYI, failed resume without replay, diagnostic recovery, unavailable push preserves mode, sibling isolation, network guard, restart")
    finally:
        stop()

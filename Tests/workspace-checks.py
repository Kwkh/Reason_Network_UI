"""Exercise the stock local transport with two isolated, concurrently running networks."""
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
from contextlib import ExitStack
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from uuid import uuid4

binary = Path(sys.argv[1]).resolve()

def request(root, op, **args):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(15)
        sock.connect(str(root / "network.sock"))
        sock.sendall(json.dumps(dict(id=1, op=op, **args)).encode() + b"\n")
        return json.loads(sock.makefile("rb").readline())

def call(root, op, **args):
    reply = request(root, op, **args)
    assert reply["ok"], (op,reply)
    return reply.get("result")

def mcp_directory(home, root, agent, native_id):
    env = dict(HOME=str(home), PATH="/usr/bin:/bin", REASON_NETWORK_HOME=str(root),
               REASON_NETWORK_AGENT=agent, REASON_NETWORK_NO_SERVICE="1", REASON_NETWORK_NO_TRAY="1")
    if agent == "gemini":
        env["GEMINI_SESSION_ID"] = native_id
    elif agent == "claude-code":
        env["CLAUDE_CODE_SESSION_ID"] = native_id
    with subprocess.Popen([binary, "mcp"], env=env, cwd=home, stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0) as proc:
        def rpc(method, params, number=None):
            frame = dict(jsonrpc="2.0", method=method, params=params)
            if number is not None:
                frame["id"] = number
            proc.stdin.write(json.dumps(frame).encode() + b"\n")
            if number is None:
                return
            while select.select([proc.stdout], [], [], 12)[0]:
                line = proc.stdout.readline()
                assert line, "MCP server disconnected"
                response = json.loads(line)
                if response.get("id") == number:
                    assert "error" not in response, response
                    return response["result"]
            raise TimeoutError(method)
        try:
            rpc("initialize", dict(protocolVersion="2025-11-25", capabilities={},
                                   clientInfo=dict(name=agent, version="1")), 1)
            rpc("notifications/initialized", {})
            if agent == "dsh":
                missing = rpc("tools/call", dict(name="list_team", arguments={}), 3)
                assert missing.get("isError") and "session_id" in missing["content"][0]["text"], missing
            arguments = {"session_id": native_id} if agent == "dsh" else {}
            result = rpc("tools/call", dict(name="list_team", arguments=arguments), 2)
            assert not result.get("isError"), result
            return result["content"][0]["text"]
        finally:
            proc.terminate()

with tempfile.TemporaryDirectory(prefix="rn-ws-", dir="/tmp") as temp:
    home = Path(temp)
    a = home / ".reason/network"
    b = home / ".reason/workspaces/b"
    procs = []

    def start(root):
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        env = dict(HOME=temp, PATH="/usr/bin:/bin", REASON_NETWORK_HOME=str(root),
                   REASON_NETWORK_LOCAL_PARTICIPATION="1", REASON_NETWORK_NO_SERVICE="1", REASON_NETWORK_NO_TRAY="1")
        proc = subprocess.Popen([binary,"daemon"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs.append(proc)
        for _ in range(150):
            assert proc.poll() is None, "daemon exited"
            try:
                assert call(root,"session_participation")["harness_presence"]
                return proc
            except OSError:
                time.sleep(.05)
        raise TimeoutError("daemon did not start")

    def create(root,name):
        proc = start(root)
        call(root,"create_team",name=name,person="qa")
        proc.wait(timeout=12)
        start(root)
        with sqlite3.connect(root / "network.db") as db:
            return db.execute("SELECT json_extract(value,'$.id') FROM kv WHERE key='team'").fetchone()[0]

    def hook(root, name):
        return call(root,"hook",agent="codex",event="stop", pid=os.getpid(),session_id=name,name=name,cwd=temp,mail=False)

    def send(to, body, sender="alpha", **kwargs):
        return request(a,"send",**{"from":"codex:"+sender,"to":to,"body":body,"wake":False},**kwargs)

    try:
        team_a = create(a,"Orange")
        for name in ["alpha","beta"]:
            hook(a,name)
        call(a,"enable_workspaces")
        team_b = create(b,"Blue")
        assert team_a != team_b
        assert not request(b,"hook",agent="codex",event="stop", pid=os.getpid(),session_id="gamma",cwd=temp,mail=False)["ok"]
        assert not request(a,"hook",agent="codex",event="stop", pid=os.getpid(),session_id="gamma",cwd=temp,mail=False)["ok"]
        for name in ["alpha","beta"]:
            call(b,"set_session_participation",key="codex:"+name,paused=False)
            hook(b,name)
        assert not send("qa/beta","ambiguous")["ok"]
        for root,title,team in [(a,"Orange",team_a),(b,"Blue",team_b)]:
            assert call(root,"who",all=False)["team"] == title
            reply = send(team+"::qa/beta",title)
            assert reply["ok"],reply
            ids = reply["result"]["ids"]
            receipt = call(a,"delivery_status",**{"from":"codex:alpha","ids":ids})
            assert receipt[0]["stage"] != "unknown"

        directory = call(a,"who",me="codex:alpha",all=False)
        for team in [team_a,team_b]:
            assert any(s["name"] == team+"::qa/beta" for s in directory["sessions"])
        inbox = call(a,"inbox",key="codex:beta",wait_secs=0,peek=True)
        for (team,title) in [(team_a,"Orange"),(team_b,"Blue")]:
            assert 'network="'+title+'"' in inbox["text"], inbox["text"]
            msg = next(m for m in inbox["messages"] if m["body"]==title)
            raw = msg["id"].split("::")[-1]
            parent = team+"::"+raw
            assert parent in inbox["text"]
            assert send("qa/alpha","reply "+title,"beta",reply_to=parent)["ok"]
            other = team_a if team == team_b else team_b
            assert not send(other+"::qa/alpha","wrong","beta",reply_to=parent)["ok"]
        for root,team,title in [(a,team_a,"Orange"),(b,team_b,"Blue")]:
            with sqlite3.connect(root/"network.db") as db:
                records = db.execute("SELECT network,body FROM workspace_sent ORDER BY rowid").fetchall()
                assert records == [(team,title),(team,"reply "+title)],records
        call(b,"set_session_participation",key="codex:alpha",paused=True)
        assert not send(team_b+"::qa/beta","after-exit")["ok"]
        assert send(team_a+"::qa/beta","still here")["ok"]
        print("PASS: manual membership, isolated overview and histories, qualified directory and replies, ambiguous sends refused, independent exit")
        # An old desktop MCP client can outlive the daemon upgrade.
        host = dict(key="proc:12345", agent="dsh", cwd=temp, tier="pull", name="desktop-dsh")
        assert not request(a, "register", session=host)["ok"]
        with sqlite3.connect(a/"network.db") as db:
            db.execute("INSERT INTO sessions (key,name,agent,cwd,tier,last_seen) VALUES (?,?,?,?,?,?)",
                       (host["key"], host["name"], "dsh", temp, "pull", int(time.time()*1000)))
        assert not any(s["name"] == "desktop-dsh" for s in call(a, "who", all=True)["sessions"])
        # Different tools deliberately share one native ID. Only their full keys identify a mailbox.
        for agent in ["claude-code", "gemini", "dsh"]:
            key = agent + ":same-id"
            for root, team in [(a, team_a), (b, team_b)]:
                call(root, "set_session_participation", key=key, paused=False)
                call(root, "workspace_dispatch", network=team, request=dict(
                    op="hook", agent=agent, event="stop", pid=os.getpid(), session_id="same-id", name=agent, cwd=temp, mail=False))
                call(root, "set_receive_mode", key=key, network=team, mode="pull")
                assert send(team+"::qa/"+agent, team+"/"+agent, sender="beta")["ok"]
            directory = mcp_directory(home, a, agent, "same-id")
            assert team_a+"::qa/"+agent in directory and team_b+"::qa/"+agent in directory, directory
            # Closing a synthetic MCP client ends its own live registration. Re-open the local hook.
            call(a, "hook", agent=agent, event="stop", pid=os.getpid(), session_id="same-id", cwd=temp, mail=False)
            inbox = call(a, "inbox", key=key, wait_secs=0, peek=True)
            assert {m["body"] for m in inbox["messages"]} == {team_a+"/"+agent, team_b+"/"+agent}
            for row in inbox["messages"]:
                team = row["body"].split("/")[0]
                parent = team + "::" + row["id"].split("::")[-1]
                assert parent in inbox["text"]
                call(a, "send", **{"from":key, "to":"qa/beta", "body":"reply "+row["body"], "reply_to":parent, "wake":False})
                other = team_b if team == team_a else team_a
                assert not request(a, "send", **{"from":key, "to":other+"::qa/beta", "body":"wrong", "reply_to":parent, "wake":False})["ok"]
            assert not request(a, "send", **{"from":key,"to":"qa/beta","body":"ambiguous","wake":False})["ok"]
            call(b, "set_session_participation", key=key, paused=True)
            assert not request(a, "send", **{"from":key,"to":team_b+"::qa/beta","body":"paused","wake":False})["ok"]
            assert request(a, "send", **{"from":key,"to":team_a+"::qa/beta","body":"still here","wake":False})["ok"]
        print("PASS: mixed-tool inboxes, qualified replies, ambiguous address rejection and independent pauses")

        for agent in ("codex", "claude-code", "dsh"):
            name = "lifecycle-" + agent
            key = agent + ":" + name
            def event(kind, **fields):
                return dict(op="hook", agent=agent, session_id=name, event=kind,
                            cwd=temp, name=name, mail=False, **fields)
            def state(root):
                return next(row["status"] for row in call(root, "who", all=True)["sessions"] if row["name"] == name)
            for root, team in [(a, team_a), (b, team_b)]:
                call(root, "set_session_participation", key=key, paused=False)
                reply = call(root, "workspace_dispatch", network=team, request=event("app-join"))
                assert reply["address"] == "qa/" + name and state(root) == "offline"
            with subprocess.Popen(["/bin/sleep", "45"]) as original:
                call(a, **event("prompt", pid=original.pid))
                for root, team in [(a, team_a), (b, team_b)]:
                    assert state(root) == "busy"
                    call(root, "workspace_dispatch", network=team, request=event("app-join"))
                    assert state(root) == "busy"
                    call(root, "set_receive_mode", key=key, network=team, mode="pull")
                # Keep the MCP connection open while the actual originating process exits.
                with socket.socket(socket.AF_UNIX) as transport:
                    transport.connect(str(a / "network.sock"))
                    reg = dict(key=key, agent=agent, agent_session_id=name, cwd=temp, tier="pull", pid=original.pid)
                    transport.sendall(json.dumps(dict(id=1, op="register", session=reg)).encode()+b"\n")
                    assert json.loads(transport.makefile("rb").readline())["ok"]
                    original.terminate()
                    original.wait(timeout=5)
                    assert state(a) == state(b) == "offline"
                    for root in (a, b):
                        assert key not in call(root, "session_participation")["paused"]
                        with sqlite3.connect(root/"network.db") as db:
                            assert db.execute("SELECT value FROM kv WHERE key=?", ("receive-mode:"+key,)).fetchone() == ("pull",)
            # Reopening the same thread uses its previous address. An explicit disconnect stays scoped.
            call(b, "set_session_participation", key=key, paused=True)
            assert call(a, **event("prompt", pid=os.getpid()))["address"] == "qa/" + name
            assert state(a) == "busy"
            assert not any(row["name"] == name for row in call(b, "who", all=True)["sessions"])
            call(a, **event("end", pid=os.getpid()))
            assert state(a) == "offline"
        print("PASS: three harnesses, two Networks, manual offline join, live MCP surviving host exit, scoped reopen")

        # Manual join can discover a real host even before its first hook.
        for agent in ("claude-code", "dsh"):
            sid = str(uuid4())
            key = agent + ":" + sid
            name = "native-" + agent
            call(a, "set_session_participation", key=key, paused=False)
            with ExitStack() as cleanup, subprocess.Popen(["/bin/sleep", "20"]) as native:
                if agent == "claude-code":
                    reg = home / ".claude/sessions" / (str(native.pid) + ".json")
                    reg.parent.mkdir(parents=True, exist_ok=True)
                    reg.write_text(json.dumps(dict(sessionId=sid, pid=native.pid, cwd=temp)))
                else:
                    digest = hashlib.sha256(sid.encode()).hexdigest()[:32]
                    directory = Path("/tmp") / ("reason-dsh-" + str(os.getuid()))
                    directory.mkdir(mode=0o700, exist_ok=True)
                    path = directory / (digest + "-" + str(native.pid) + ".sock")
                    listener = cleanup.enter_context(socket.socket(socket.AF_UNIX))
                    listener.bind(str(path))
                    cleanup.callback(path.unlink, missing_ok=True)
                    listener.listen(1)
                reply = call(a, "hook", event="app-join", agent=agent, session_id=sid, name=name, cwd=temp)
                assert reply["address"] == "qa/"+name
                def status():
                    return next(row["status"] for row in call(a, "who", all=True)["sessions"] if row["name"] == name)
                assert status() != "offline"
                native.terminate()
                native.wait(timeout=5)
                assert status() == "offline"
        print("PASS: native Claude registry and dsh plugin endpoint follow the original host lifetime")

        # The native wake service survives its launcher. Its PID alone cannot make
        # an archived/closed desktop process appear online in this isolated profile.
        detached = home/"codex"
        shutil.copyfile("/bin/sleep", detached)
        detached.chmod(0o700)
        launcher = "import subprocess, sys; print(subprocess.Popen([sys.argv[1], '30'], stdout=subprocess.DEVNULL).pid)"
        pid = int(subprocess.check_output([sys.executable, "-c", launcher, str(detached)]))
        try:
            name = "detached-server"
            call(a, "set_session_participation", key="codex:"+name, paused=False)
            call(a, "hook", event="stop", agent="codex", session_id=name, name=name, cwd=temp, pid=pid)
            assert next(row["status"] for row in call(a, "who", all=True)["sessions"] if row["name"] == name) == "offline"
        finally:
            os.kill(pid, signal.SIGTERM)
        print("PASS: a detached Codex wake service alone cannot advertise an online conversation")



        with sqlite3.connect(b/"network.db") as db:
            history_count = db.execute("SELECT COUNT(*) FROM workspace_sent WHERE network=?", (team_b,)).fetchone()[0]
        assert call(a,"session_participation")["admin_network"] == team_a
        assert call(b,"session_participation")["admin_network"] == team_b
        assert not request(b,"dissolve_network",network=team_a)["ok"]
        call(b,"dissolve_network",network=team_b)
        procs[-1].wait(timeout=12)
        start(b)
        assert call(b,"session_participation")["admin_network"] is None
        with sqlite3.connect(b/"network.db") as db:
            assert not db.execute("SELECT 1 FROM kv WHERE key='team'").fetchone()
            marker = json.loads(db.execute("SELECT value FROM kv WHERE key=?",("dissolved:"+team_b,)).fetchone()[0])
            assert marker["dissolved"]["by"] == marker["founder"] and not marker.get("link")
            assert db.execute("SELECT COUNT(*) FROM workspace_sent WHERE network=?",(team_b,)).fetchone()[0] == history_count
        assert send(team_a+"::qa/beta","after other network dissolved")["ok"]
        print("PASS: dissolution is scoped, persists across restart, and preserves history")
    finally:
        for proc in procs:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=10)

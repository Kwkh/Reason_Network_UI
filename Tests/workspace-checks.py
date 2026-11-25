"""Exercise the stock local transport with two isolated, concurrently running networks."""
import hashlib
import json
import os
import re
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

def mcp_directory(home, root, agent, native_id, reply=None):
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
            if reply is not None:
                result = rpc("tools/call", dict(name="send_message", arguments={"to":reply, "message":"native MCP reply"}, _meta={"sessionId":native_id}), 2)
            else:
                result = rpc("tools/call", dict(name="list_team", arguments=arguments), 2)
            assert not result.get("isError"), result
            return result["content"][0]["text"]
        finally:
            proc.terminate()


def check_agent_join(home, a, b, team_a, team_b):
    def member(root, key):
        with sqlite3.connect(root/"network.db") as db:
            row = db.execute("SELECT value FROM kv WHERE key=?", ("workspace-member:"+key,)).fetchone()
            return row[0] if row else None

    blocked_folder = str(home / "blocked")
    legacy = dict(agent="codex", key="codex:legacy-new", cwd=str(home), tier="pull")
    def refused(root, registration, **fields):
        res = request(root, "register", session=registration, **fields)
        assert not res["ok"], res
        return res["error"]
    hint = refused(a, legacy)
    assert "has not joined" in hint and str(binary) in hint and "join-session" in hint, hint
    folder_error = "Your user turned Reason Network off for this folder"
    assert refused(a, dict(legacy, cwd=blocked_folder), replay=False) == folder_error
    # A shared MCP host may report the allowed parent while its native hook knows the real cwd.
    request(a, "hook", agent="codex", session_id="blocked-by-hook", event="start", cwd=blocked_folder, mail=False)
    assert refused(a, dict(legacy, key="codex:blocked-by-hook"), replay=False) == folder_error
    session = dict(legacy, agent_session_id="legacy-new", cwd=blocked_folder)
    for team in (team_a, team_b):
        blocked = request(a, "join_current_session", network=team, session=session)
        assert not blocked["ok"] and blocked["error"] == folder_error, blocked
    assert refused(a, legacy, replay=True) == folder_error
    assert not member(a, legacy["key"]) and not member(b, legacy["key"])

    for agent in ("codex", "claude-code", "gemini", "dsh"):
        ident = "agent-request-" + agent
        key = agent + ":" + ident
        env = dict(HOME=str(home), PATH="/usr/bin:/bin", REASON_NETWORK_HOME=str(a),
                   REASON_NETWORK_AGENT=agent, REASON_NETWORK_NO_SERVICE="1", REASON_NETWORK_NO_TRAY="1")
        with subprocess.Popen([binary, "mcp"], env=env, cwd=home, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0) as proc:
            def rpc(method, params, number=1):
                frame = dict(jsonrpc="2.0", method=method, params=params)
                if number is not None: frame["id"] = number
                proc.stdin.write(json.dumps(frame).encode()+b"\n")
                if number is None: return
                while select.select([proc.stdout], [], [], 12)[0]:
                    response = json.loads(proc.stdout.readline())
                    if response.get("id") == number: return response
                raise TimeoutError(method)
            def join(args, meta=None):
                params = dict(name="join_network", arguments=args)
                if meta is not None: params["_meta"] = meta
                resp = rpc("tools/call", params)
                if "error" in resp: return None
                result = resp["result"]
                if result.get("isError"): return None
                return json.loads(result["content"][0]["text"])
            try:
                rpc("initialize", dict(protocolVersion="2025-11-25", capabilities={}, clientInfo=dict(name=agent,version="1")))
                rpc("notifications/initialized", {}, None)
                assert "join_network" in [t["name"] for t in rpc("tools/list",{})["result"]["tools"]]
                if agent == "codex":
                    status = rpc("tools/call", dict(name="list_team", arguments={}, _meta={"sessionId":ident}))["result"]
                    assert status.get("isError"), status
                    message = status["content"][0]["text"]
                    assert "has not joined" in message and "join_network" in message and str(binary) in message, message
                choices = join({})
                assert {r["id"] for r in choices} == {team_a, team_b}
                assert join({"network":"missing"}, {"sessionId":ident}) is None
                assert join({"network":"Blue","session_id":"another-chat"}, {"sessionId":ident}) is None
                assert join({"network":"Blue"}) is None
                assert not member(a,key) and not member(b,key)
                result = join({"network":"Blue"}, {"sessionId":ident})
                assert result["network_id"] == team_b and result["address"].startswith("qa/") and isinstance(result["online"],bool)
                assert not member(a,key) and member(b,key) == team_b
                assert join({"network":team_b}, {"sessionId":ident})["address"] == result["address"]
                call(b,"set_session_participation",key=key,paused=True)
                registration = dict(agent=agent, key=key, agent_session_id=ident, cwd=str(home), tier="pull")
                assert "disconnected" in refused(b, registration, replay=False)
                assert refused(b, registration) == folder_error
                assert join({"network":team_b}, {"sessionId":ident})["address"] == result["address"]
                assert key not in call(b,"session_participation")["paused"]
                assert join({"network":team_a}, {"sessionId":ident})["network_id"] == team_a
                assert member(a,key) == team_a and member(b,key) == team_b
                if agent == "codex":
                    # A cached tools/list can still reach this command from the original shell.
                    shell_env = dict(env, CODEX_THREAD_ID="shell-only")
                    query = dict(name="list_team", arguments={}, _meta={"sessionId":"shell-only"})
                    first = rpc("tools/call", query)["result"]
                    assert first.get("isError") and "join-session" in first["content"][0]["text"]
                    cli = [str(binary), "join-session"]
                    choices = json.loads(subprocess.check_output(cli, env=shell_env, cwd=home))
                    assert {r["id"] for r in choices} == {team_a, team_b}
                    assert not member(a, "codex:shell-only") and not member(b, "codex:shell-only")
                    joined = json.loads(subprocess.check_output(cli + ["--network",team_b], env=shell_env, cwd=home))
                    assert joined["network_id"] == team_b and member(b, "codex:shell-only") == team_b
                    assert not member(a, "codex:shell-only") and not member(b, legacy["key"])
                    directory = rpc("tools/call", query)["result"]
                    assert not directory.get("isError"), directory
                if agent == "dsh":
                    shell_id = "shell-dsh"
                    before = subprocess.run([binary,"join-session","--network",team_b],env=env,cwd=home,capture_output=True)
                    assert before.returncode and not member(b,"dsh:"+shell_id)
                    env["DSH_SESSION_ID"] = shell_id
                    result = json.loads(subprocess.check_output([binary,"join-session","--network",team_b],env=env,cwd=home))
                    assert result["network_id"] == team_b and member(b,"dsh:"+shell_id) == team_b
                    assert not member(a,"dsh:"+shell_id)
                if agent == "gemini":
                    # Even a previously unjoined session's hook identifies its owner without granting participation.
                    sid = "gemini-from-hook"
                    request(a,"hook",agent=agent,event="start",session_id=sid,pid=os.getpid(),cwd=str(home),mail=False)
                    assert not member(b,agent+":"+sid)
                    assert join({"network":team_b})["network_id"] == team_b
                    assert member(b,agent+":"+sid) == team_b
            finally:
                proc.stdin.close()
                if proc.poll() is None: proc.terminate()
    print("PASS: four real MCP clients self-join only the chosen workspace, preserve address on retry and rejoin, reject unidentified calls, and support the dsh shell")

with tempfile.TemporaryDirectory(prefix="rn-ws-", dir="/tmp") as temp:
    home = Path(temp)
    a = home / ".reason/network"
    b = home / ".reason/workspaces/b"
    procs = []

    def start(root, search_path="/usr/bin:/bin", participation=True):
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        env = dict(HOME=temp, PATH=search_path, REASON_NETWORK_HOME=str(root),
                   REASON_NETWORK_LOCAL_PARTICIPATION="1", REASON_NETWORK_NO_SERVICE="1", REASON_NETWORK_NO_TRAY="1")
        if not participation:
            env.pop("REASON_NETWORK_LOCAL_PARTICIPATION")
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
        a.mkdir(parents=True, exist_ok=True)
        (a/"config.toml").write_text(f'[folders]\n{json.dumps(str(home / "blocked"))} = "off"\n')
        team_a = create(a,"Orange")
        for name in ["alpha","beta"]:
            hook(a,name)
        call(a,"enable_workspaces")
        team_b = create(b,"Blue")
        assert team_a != team_b
        check_agent_join(home, a, b, team_a, team_b)
        # Simulate two previously joined Networks with the same display name. No worker for
        # the duplicate is needed: the broker must disambiguate before dispatching anything.
        with tempfile.TemporaryDirectory(dir=b.parent) as shadow:
            with sqlite3.connect(Path(shadow)/"network.db") as clone, sqlite3.connect(b/"network.db") as source:
                clone.execute("CREATE TABLE kv(key TEXT PRIMARY KEY,value TEXT)")
                team = json.loads(source.execute("SELECT value FROM kv WHERE key='team'").fetchone()[0])
                team["id"] = "shadow-workspace"
                clone.execute("INSERT INTO kv VALUES('team',?)", (json.dumps(team),))
            candidate = dict(agent="codex",agent_session_id="ambiguous-target",key="codex:ambiguous-target",cwd=temp,tier="pull")
            refused = request(a,"join_current_session",network="Blue",session=candidate)
            assert not refused["ok"] and "unique ID" in refused["error"]
            with sqlite3.connect(b/"network.db") as db:
                assert not db.execute("SELECT 1 FROM kv WHERE key='workspace-member:codex:ambiguous-target'").fetchone()
            assert call(a,"join_current_session",network=team_b,session=candidate)["network_id"] == team_b
        print("PASS: duplicate Network names require a unique target ID before membership changes")

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
        # The same sender and same body in two workspaces. Read the actual native hook prompt,
        # then reply through the broker, as an existing MCP client would.
        references = []
        for root, team in [(a,team_a),(b,team_b)]:
            sent = send(team+"::qa/beta","same native prompt")
            parent = sent["result"]["ids"][0].split("::")[-1]
            hook_req = dict(op="hook",agent="codex",event="stop",pid=os.getpid(),session_id="beta",cwd=temp,mail=True)
            text = call(root,"workspace_dispatch",network=team,request=hook_req)["text"]
            ref = re.search(r'│ same native prompt\n\n↩ send_message\(to="(reply::[A-F0-9]{10})"',text).group(1)
            assert team not in text and parent not in text, text
            references.append((root,team,parent,ref))
        assert references[0][3] != references[1][3]
        for root,team,parent,ref in references:
            assert not send(ref,"wrong caller","alpha")["ok"]
            assert not send(ref,"wrong parent","beta",reply_to="other")["ok"]
            nonce = "compact-test-"+team
            result = send(ref,"compact reply","beta",idempotency_key=nonce)
            assert result["ok"],result
            retry = send(team+"::qa/alpha","compact reply","beta",reply_to=team+"::"+parent,idempotency_key=nonce)
            assert retry["ok"] and retry["result"]["ids"] == result["result"]["ids"],retry
            with sqlite3.connect(root/"network.db") as db:
                assert db.execute("SELECT reply_to,recipient FROM messages WHERE id=?", (result["result"]["ids"][0],)).fetchone() == (parent,"qa/alpha")
        assert not send("reply::00000","invalid","beta")["ok"]
        # An unavailable index falls back to the original, fully addressed prompt.
        index = a/"reply-refs.sqlite3"
        saved = a/"saved-refs"
        index.rename(saved)
        try:
            index.mkdir()
            assert send(team_b+"::qa/beta","fallback native prompt")["ok"]
            text = call(b,"workspace_dispatch",network=team_b,request=hook_req)["text"]
            assert "fallback native prompt" in text and team_b+"::" in text and "<reason-message" in text
            assert not send(references[0][3],"missing index","beta")["ok"]
        finally:
            index.rmdir()
            saved.rename(index)
        worker = next(p for p in procs if p.pid==int((b/"daemon.lock").read_text()))
        worker.terminate()
        worker.wait(timeout=12)
        start(b)
        for name in ["alpha","beta"]:
            hook(b,name)
        delayed = send(references[1][3],"reply after restart","beta")
        assert delayed["ok"],delayed
        text = mcp_directory(home, a, "codex", "beta", reply=references[1][3])
        assert "qa/alpha" in text and "message id " in text,text
        with sqlite3.connect(b/"network.db") as db:
            assert db.execute("SELECT reply_to FROM workspace_sent WHERE body='native MCP reply'").fetchone() == (references[1][2],)
        hook(a,"beta")
        hook(b,"beta")
        # Ask's original-message lookup remains bound to the requesting thread and workspace.
        # The synthetic sender is on the same machine: it must be refused before any dialog opens.
        ask = request(a,"ask",key="codex:beta",question="fixture",about=references[1][3])
        assert not ask["ok"] and references[1][2] in ask["error"],ask
        print("PASS: compact hook replies preserve exact parent across two Networks; wrong thread, conflicting parent and unavailable index are safe")
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

        # Two native conversations share one still-running process. Their sockets can
        # reopen independently of hooks, the MCP connection and workspace restarts.
        keys = [str(uuid4()) for _ in range(3)]
        labels = ["reopen-one", "reopen-two"]
        for sid, label in zip(keys, labels):
            for root, team in [(a, team_a), (b, team_b)]:
                call(root, "set_session_participation", key="dsh:"+sid, paused=False)
                call(root, "workspace_dispatch", network=team, request=dict(op="hook", event="app-join",
                     agent="dsh", session_id=sid, name=label, cwd=temp))
            call(a, "set_session_participation", key="dsh:"+sid, paused=True)
        def dsh_rows(root):
            return {row["name"]:row for row in call(root,"who",all=True)["sessions"] if row.get("agent")=="dsh"}
        def await_online(names):
            for _ in range(100):
                rows = dsh_rows(b)
                if all(label in rows and (rows[label]["status"]!="offline") == (label in names) for label in labels):
                    return rows
                time.sleep(.12)
            raise AssertionError([(n,r["status"]) for n,r in rows.items()])
        def listen(stack, sid):
            path = directory / (hashlib.sha256(sid.encode()).hexdigest()[:32] + "-" + str(os.getpid()) + ".sock")
            listener = stack.enter_context(socket.socket(socket.AF_UNIX))
            listener.bind(str(path))
            stack.callback(path.unlink, missing_ok=True)
            listener.listen(16)
            return listener
        with ExitStack() as open_sessions:
            second_channel = listen(open_sessions, keys[1])
            listen(open_sessions, keys[2])  # Never joined either Network.
            with ExitStack() as first:
                listen(first, keys[0])
                rows = await_online(labels)
                call(b,"set_receive_mode",key="dsh:"+keys[0],network=team_b,mode="pull")
                assert not set(labels).intersection(dsh_rows(a))
            await_online([labels[1]])
            message = "queued for the offline dsh conversation"
            assert send(team_b+"::qa/"+labels[0], message, sender="beta")["ok"]
            listen(open_sessions, keys[0])
            assert await_online(labels)[labels[0]]["tier"]=="pull"
            inbox = call(b, "inbox", key="dsh:"+keys[0], wait_secs=0, peek=True)
            assert [m["body"] for m in inbox["messages"]].count(message) == 1
            sibling = call(b, "inbox", key="dsh:"+keys[1], wait_secs=0, peek=True)
            assert all(m["body"] != message for m in sibling["messages"])
            worker = next(proc for proc in reversed(procs) if proc.poll() is None and proc.args[1]=="daemon"
                          and proc.pid==int((b/"daemon.lock").read_text().strip()))
            worker.terminate()
            worker.wait(timeout=12)
            # Folder metadata is optional. Simulate Git waiting for the user on
            # one original thread's Documents folder during the first restart.
            bin_dir = home/"git-fixture"
            bin_dir.mkdir()
            blocked = home/"private-project"
            blocked.mkdir()
            marker = home/"unexpected-git"
            git = bin_dir/"git"
            git.write_text(f'#!/bin/sh\nif [ "$2" = "{blocked}" ]; then touch "{marker}"; sleep 4; exit 1; fi\nexec /usr/bin/git "$@"\n')
            git.chmod(0o700)
            with sqlite3.connect(b/"network.db") as db:
                db.execute("UPDATE sessions SET cwd=? WHERE key=?", (str(blocked),"dsh:"+keys[0]))
            worker = start(b, search_path=str(bin_dir)+":/usr/bin:/bin")
            assert await_online(labels)[labels[0]]["tier"]=="pull"
            assert not marker.exists(), "dsh recovery or directory listing tried to read the native workspace"
            # A CLI may get to the managed workspace before launchd. Recovery also
            # runs in that process, without depending on its inherited environment.
            worker.terminate()
            worker.wait(timeout=12)
            start(b, participation=False)
            assert await_online(labels)[labels[0]]["tier"]=="pull"
            assert not set(labels).intersection(dsh_rows(a))
            assert call(b,"set_receive_mode",key="dsh:"+keys[1],network=team_b,mode="push")["effective"] == "push"
            call(b, "hook", agent="codex", event="stop", pid=os.getpid(), session_id="beta", cwd=temp, mail=False)
            sent = request(a, "send", **{"from":"codex:beta", "to":team_b+"::qa/"+labels[1],
                                         "body":"push after presence recovery", "wake":True})
            assert sent["ok"], sent
            second_channel.settimeout(6)
            while True:
                with second_channel.accept()[0] as connection:
                    data = connection.makefile("rb").readline()
                    if not data: continue  # Presence probes carry no message.
                    packet = json.loads(data)
                    assert packet["session"] == keys[1] and "push after presence recovery" in packet["text"]
                    short = re.search(r'to="(reply::[A-F0-9]{10})"',packet["text"]).group(1)
                    connection.sendall(b"accepted\n")
                    break
            assert request(a,"send",**{"from":"dsh:"+keys[1],"to":short,"body":"dsh compact reply","wake":False})["ok"]
            for root in (a,b):
                with sqlite3.connect(root/"network.db") as db:
                    assert not db.execute("SELECT 1 FROM sessions WHERE key=?",("dsh:"+keys[2],)).fetchone()
        await_online([])
        print("PASS: idle dsh endpoints recover separately after close, reopen and daemon restart; preserve pull and respect paused and never-joined siblings")

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
        cfg = home/".codex/config.toml"
        cfg.parent.mkdir(exist_ok=True)
        old = home/".local/bin/reason-network"
        cfg.write_text('[mcp_servers.reason-network]\ncommand = '+json.dumps(str(old))+'\nargs = ["mcp"]\ntool_timeout_sec = 123\n')
        old.parent.mkdir(parents=True, exist_ok=True)
        old.touch()
        env = dict(HOME=temp,PATH="/usr/bin:/bin",REASON_NETWORK_HOME=str(a),REASON_NETWORK_NO_SERVICE="1")
        # Exercise the same setup plus migration sequence the App uses on old installations.
        cfg.write_text(cfg.read_text()+'default_tools_approval_mode = "prompt"\nenv = { CUSTOM = "keep" }\n')
        subprocess.run([binary,"setup-app-agents","--cli",old,"--no-service"],env=env,check=True,capture_output=True)
        assert 'default_tools_approval_mode = "prompt"' in cfg.read_text() and 'CUSTOM = "keep"' in cfg.read_text()
        previous = home/"Library/Application Support/Reason Network UI/Backend/1234567890abcdef/reason-network"
        claude = home/".claude.json"
        generic = {"args":["mcp"],"env":{"EXAMPLE":"keep"}}
        claude.write_text(json.dumps({"keep":True,"mcpServers":{"reason-network": dict(command=str(previous),**generic)}}))
        gemini = home/".gemini/settings.json"
        gemini.parent.mkdir(exist_ok=True)
        custom = json.dumps({"mcpServers":{"reason-network":dict(command="/custom/agent-launcher",**generic)}})
        gemini.write_text(custom)
        env = dict(HOME=temp,PATH="/usr/bin:/bin",REASON_NETWORK_HOME=str(a),REASON_NETWORK_NO_SERVICE="1")
        setup = [binary,"setup-agent-join","--backend",binary]
        subprocess.run(setup,env=env,check=True)
        assert str(binary) in cfg.read_text() and "tool_timeout_sec = 123" in cfg.read_text()
        assert json.loads(claude.read_text())=={"keep":True,"mcpServers":{"reason-network":dict(command=str(binary),**generic)}}
        before = cfg.read_bytes(), claude.read_bytes()
        subprocess.run(setup,env=env,check=True)
        assert before == (cfg.read_bytes(),claude.read_bytes()) and gemini.read_text()==custom
        cfg.write_text('[mcp_servers.reason-network]\ncommand = "/custom/launcher"\nargs = ["run"]\n')
        custom_cfg = cfg.read_bytes()
        subprocess.run([binary,"setup-app-agents","--cli",old,"--no-service"],env=env,check=True,capture_output=True)
        subprocess.run(setup,env=env,check=True)
        assert cfg.read_bytes() == custom_cfg
        print("PASS: managed MCP commands upgrade without replacing client settings or custom launchers")

    finally:
        for proc in procs:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=10)

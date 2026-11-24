"""Exercise the stock local transport with two isolated, concurrently running networks."""
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

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
                assert call(root,"session_participation")["workspaces"]
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
        return call(root,"hook",agent="codex",event="stop",session_id=name,name=name,cwd=temp,mail=False)

    def send(to, body, sender="alpha", **kwargs):
        return request(a,"send",**{"from":"codex:"+sender,"to":to,"body":body,"wake":False},**kwargs)

    try:
        team_a = create(a,"Orange")
        for name in ["alpha","beta"]:
            hook(a,name)
        call(a,"enable_workspaces")
        team_b = create(b,"Blue")
        assert team_a != team_b
        assert not request(b,"hook",agent="codex",event="stop",session_id="gamma",cwd=temp,mail=False)["ok"]
        assert not request(a,"hook",agent="codex",event="stop",session_id="gamma",cwd=temp,mail=False)["ok"]
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
    finally:
        for proc in procs:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=10)

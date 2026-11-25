"""Deliver through the bundled backend and installed dsh adapter in a disposable home."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from uuid import uuid4

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(dir="/tmp", prefix="rn-wake-") as tmp:
    home = Path(tmp)
    state = home / ".reason/network"
    state.mkdir(parents=True)
    env = dict(HOME=tmp, PATH="/usr/bin:/bin", REASON_NETWORK_HOME=str(state),
               REASON_NETWORK_LOCAL_PARTICIPATION="1", REASON_NETWORK_NO_SERVICE="1",
               REASON_NETWORK_NO_TRAY="1")
    processes = []
    def request(op, **fields):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(5)
            s.connect(str(state / "network.sock"))
            s.sendall(json.dumps(dict(id=1, op=op, **fields)).encode() + b"\n")
            return json.loads(s.makefile("rb").readline())
    def call(op, **fields):
        reply = request(op, **fields)
        assert reply["ok"], reply
        return reply.get("result")
    def start():
        proc = subprocess.Popen([binary, "daemon"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        processes.append(proc)
        for _ in range(120):
            try:
                assert call("session_participation")["native_agent_wake"]
                return proc
            except OSError:
                time.sleep(.08)
        raise TimeoutError("daemon")
    def hook(agent, sid, name):
        return call("hook", agent=agent, session_id=sid, name=name, event="stop", pid=os.getpid(), cwd=tmp, mail=False)["address"]
    def send(to, body, wake=True):
        return call("send", **{"from":"codex:beta", "to":to, "body":body, "wake":wake})
    def pending(key):
        return [m["body"] for m in call("inbox", key=key, wait_secs=0, peek=True)["messages"]]
    try:
        proc = start()
        call("create_team", name="Wake tests", person="qa")
        proc.wait(timeout=12)
        start()
        (home / ".reason/workspaces").mkdir()
        with sqlite3.connect(state/"network.db") as db:
            team = json.loads(db.execute("SELECT value FROM kv WHERE key='team'").fetchone()[0])["id"]
        hook("codex", "beta", "beta")
        sid = str(uuid4())
        key = "dsh:" + sid
        addr = hook("dsh", sid, "deepseek")
        assert not request("set_receive_mode", key=key, network=team, mode="push")["ok"]
        dsh = home/".dsh"
        dsh.mkdir()
        subprocess.run([binary, "setup-native-wake"], env=env, check=True)
        assert "reason-network-wake.mjs" in (dsh/"cordis.patch.yml").read_text()
        # Use the plugin installed by setup; the stand-in records the actual followup invocation.
        fixture = home/"host.mjs"
        fixture.write_text("""import {apply} from './.dsh/reason-network-wake.mjs';
import { appendFileSync } from 'node:fs';
const id=process.argv[2], agent={id,session:{header:{id}},followup:m=>appendFileSync('received',JSON.stringify(m)+'\\n')};
let dispose;apply({agents:{get:k=>k===id?agent:null,list:()=>[agent]},on(){},logger:console,effect:f=>{dispose=f()}});
process.on('SIGTERM',()=>{dispose();process.exit()});""")
        host = subprocess.Popen([shutil.which("node"),fixture,sid], cwd=home, env=env)
        processes.append(host)
        for _ in range(100):
            if request("set_receive_mode", key=key, network=team, mode="push")["ok"]: break
            time.sleep(.05)
        else: raise TimeoutError("dsh adapter discovery")
        send(addr,"fyi",False)
        receipt=send(addr,"wake")
        for _ in range(100):
            if (home/"received").exists() and pending(key)==["fyi"]: break
            time.sleep(.05)
        else: raise AssertionError("original dsh agent did not accept the wake")
        text=json.loads((home/"received").read_text())["content"][0]["text"]
        assert "wake" in text and team in text and "fyi" not in text
        digest=hashlib.sha256(sid.encode()).hexdigest()[:32]
        with socket.socket(socket.AF_UNIX) as sock:
            sock.connect(f"/tmp/reason-dsh-{os.getuid()}/{digest}-{host.pid}.sock")
            raw=receipt["ids"][0].split("::")[-1]
            sock.sendall(json.dumps(dict(session=sid,delivery=team+"::"+raw,text=text)).encode()+b"\n")
            assert sock.recv(30)==b"accepted\n"
        assert len((home/"received").read_text().splitlines())==1
        call("set_receive_mode", key=key, network=team, mode="pull")
        send(addr,"manual")
        assert "manual" in pending(key)
        host.terminate();host.wait(timeout=5)
        assert not request("set_receive_mode", key=key, network=team, mode="push")["ok"]
        registry=home/".claude/sessions"
        registry.mkdir(parents=True)
        file=registry/(str(os.getpid())+".json")
        with socket.socket(socket.AF_UNIX) as server:
            path=str(home/"claude.sock")
            server.bind(path);server.listen(1);server.settimeout(3)
            def register(session):
                file.write_text(json.dumps(dict(pid=os.getpid(),sessionId=session,cwd=tmp,messagingSocketPath=path)))
            register(sid)
            peer=hook("claude-code",sid,"claude")
            call("set_receive_mode", key="claude-code:"+sid, network=team, mode="push")
            send(peer,"claude wake")
            conn,_=server.accept()
            with conn: assert "claude wake" in json.loads(conn.makefile("rb").readline())["message"]["content"]
            register("different-thread")
            send(peer,"must stay unread")
            assert "must stay unread" in pending("claude-code:"+sid)
            assert not request("set_receive_mode",key="claude-code:"+sid,network=team,mode="push")["ok"]
        print("PASS: Claude exact thread and PID reuse; dsh native input, ACK, deduplication, FYI, pull, missing host and setup")
    finally:
        for proc in reversed(processes):
            if proc.poll() is None: proc.terminate();proc.wait(timeout=10)

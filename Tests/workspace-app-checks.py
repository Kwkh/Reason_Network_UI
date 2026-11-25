"""Run the App's workspace form/controller against real services in a disposable home."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time

binary, checks = (Path(s).resolve() for s in sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="rn-app-", dir="/tmp") as temp:
    home = Path(temp)
    root = home/".reason/network"
    root.mkdir(parents=True)
    cli = home/".local/bin/reason-network"
    cli.parent.mkdir(parents=True)
    # launchd must be able to execute the fixture outside protected project folders.
    shutil.copy2(binary, cli)
    agents = home/"Library/LaunchAgents"
    agents.mkdir(parents=True)
    (agents/"com.reasonmachines.network.plist").write_bytes(plistlib.dumps({"ProgramArguments":[str(cli),"daemon","--service"]}))
    env = dict(HOME=temp, PATH="/usr/bin:/bin", REASON_NETWORK_HOME=str(root), REASON_NETWORK_LOCAL_PARTICIPATION="1",
               REASON_NETWORK_NO_SERVICE="1", REASON_NETWORK_NO_TRAY="1")
    codex = home/"codex-probe"
    codex.write_text("#!/bin/sh\n[ \"$1 $2\" = 'app-server daemon' ] && exit 0\ntest \"$1 $2\" = 'queue --help' || exit 1\necho 'queue --thread --message --resume'\n")
    codex.chmod(0o700)
    env["REASON_NETWORK_CODEX_BIN"] = str(codex)
    processes = []
    def start():
        proc = subprocess.Popen([binary,"daemon"],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        processes.append(proc)
        for _ in range(160):
            with socket.socket(socket.AF_UNIX) as s:
                try:
                    s.settimeout(12)
                    s.connect(str(root/"network.sock"))
                    s.sendall(b'{"id":1,"op":"session_participation"}\n')
                    assert json.loads(s.makefile("rb").readline())["result"]["workspaces"]
                    return proc
                except OSError:
                    time.sleep(.05)
        raise TimeoutError("primary did not start")
    try:
        proc = start()
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(str(root/"network.sock"))
            s.sendall(b'{"id":1,"op":"create_team","name":"Orange","person":"qa"}\n')
            assert json.loads(s.makefile("rb").readline())["ok"]
        proc.wait(timeout=12)
        start()
        subprocess.run([checks,home],env=env,check=True,timeout=150)
    finally:
        for plist in agents.glob("local.reasonnetwork.workspace.*.plist"):
            subprocess.run(["/bin/launchctl","bootout",f"gui/{os.getuid()}/{plist.stem}"],capture_output=True)
        for proc in processes:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=10)

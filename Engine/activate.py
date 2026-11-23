"""Activate an already built participation daemon for the current macOS user."""
import hashlib
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

def run(*args):
    subprocess.run(args, check=True)

def main(binary):
    home = Path.home()
    plist = home / "Library/LaunchAgents/com.reasonmachines.network.plist"
    old = plist.read_bytes()
    job = plistlib.loads(old)
    args = job["ProgramArguments"]
    if job["Label"] != "com.reasonmachines.network" or args[1:] != ["daemon", "--service"]:
        raise ValueError("Unexpected Reason service definition")
    run("codesign", "--verify", "--strict", binary)
    expected = "reason-network 0.12.17"
    for executable in (binary, args[0]):
        if subprocess.check_output([executable, "--version"], text=True).strip() != expected:
            raise ValueError("This patch requires the 0.12.17 engine")
    root = home / "Library/Application Support/Reason Network UI/Backend"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    candidate = root / ("reason-network-" + digest[:16])
    if not candidate.exists():
        shutil.copy2(binary, candidate)
    if hashlib.sha256(candidate.read_bytes()).hexdigest() != digest:
        raise ValueError("Installed daemon checksum mismatch")
    domain = "gui/" + str(os.getuid())
    service = domain + "/" + job["Label"]
    with tempfile.NamedTemporaryFile(dir=root, prefix="launch-agent-", suffix=".plist", delete=False) as backup:
        backup.write(old)
    print("LaunchAgent backup:", backup.name, flush=True)
    args[0] = str(candidate)
    job.setdefault("EnvironmentVariables", {})["REASON_NETWORK_LOCAL_PARTICIPATION"] = "1"
    def replace_plist(data):
        with tempfile.NamedTemporaryFile(dir=plist.parent, delete=False) as f:
            f.write(data)
        os.replace(f.name, plist)
    def bootstrap():
        # launchd may still be removing the previous job after bootout returns.
        for attempt in range(12):
            result = subprocess.run(["launchctl", "bootstrap", domain, str(plist)],
                                    capture_output=True, text=True)
            if result.returncode == 0:
                return
            if result.returncode != 5 or attempt == 11:
                raise RuntimeError(result.stderr.strip() or "launchctl bootstrap failed")
            time.sleep(0.5)
    run("launchctl", "bootout", service)
    try:
        replace_plist(plistlib.dumps(job))
        bootstrap()
        for _ in range(40):
            try:
                with socket.socket(socket.AF_UNIX) as sock:
                    sock.settimeout(2)
                    sock.connect(str(home / ".reason/network/network.sock"))
                    sock.sendall(b'{"op":"session_participation","id":1}\n')
                    reply = json.loads(sock.makefile("rb").readline(1024 * 1024))
                    if reply.get("ok") and reply["result"]["version"] == 1:
                        print("Session participation v1 is available.")
                        return
            except (OSError, ValueError):
                pass
            time.sleep(0.5)
        raise RuntimeError("Daemon did not advertise session participation v1")
    except BaseException:
        subprocess.run(["launchctl", "bootout", service], check=False)
        replace_plist(old)
        bootstrap()
        raise

if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(strict=True))

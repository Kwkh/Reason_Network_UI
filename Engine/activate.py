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
import struct
import tempfile
import time
import uuid

def run(*args):
    subprocess.run(args, check=True)

def main(binary):
    home = Path.home()
    run("codesign", "--verify", "--strict", binary)
    expected = "reason-network 0.12.17"
    if subprocess.check_output([binary, "--version"], text=True).strip() != expected:
        raise ValueError("This patch requires the 0.12.17 engine")
    root = home / "Library/Application Support/Reason Network UI/Backend"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    build = root / digest[:16]
    build.mkdir(mode=0o700, exist_ok=True)
    candidate = build / "reason-network"
    if not candidate.exists():
        with tempfile.TemporaryDirectory(dir=build) as staging:
            copy = Path(staging) / "reason-network"
            shutil.copy2(binary, copy)
            os.replace(copy, candidate)
    if hashlib.sha256(candidate.read_bytes()).hexdigest() != digest:
        raise ValueError("Installed daemon checksum mismatch")
    agents = home / "Library/LaunchAgents"
    activate(agents / "com.reasonmachines.network.plist", candidate, root, home / ".reason/network", primary=True)
    prefix = "local.reasonnetwork.workspace."
    for plist in sorted(agents.glob(prefix + "*.plist")):
        suffix = plist.stem[len(prefix):]
        try:
            uuid.UUID(suffix)
        except ValueError:
            continue
        activate(plist, candidate, root, home / ".reason/workspaces" / suffix, primary=False)

    run(candidate, "setup-agent-join", "--backend", candidate)


def activate(plist, candidate, root, state, primary):
    old = plist.read_bytes()
    job = plistlib.loads(old)
    args = job["ProgramArguments"]
    env = job.get("EnvironmentVariables", {})
    if job["Label"] != plist.stem or args[1:] != ["daemon", "--service"]:
        raise ValueError("Unexpected Reason service definition")
    if not primary and (env.get("REASON_NETWORK_HOME") != str(state) or env.get("REASON_NETWORK_LOCAL_PARTICIPATION") != "1"):
        raise ValueError("Unexpected workspace service definition")
    if subprocess.check_output([args[0], "--version"], text=True).strip() != "reason-network 0.12.17":
        raise ValueError("This patch requires the 0.12.17 engine")
    domain = "gui/" + str(os.getuid())
    service = domain + "/" + job["Label"]
    loaded = subprocess.run(["launchctl", "print", service], capture_output=True).returncode == 0
    if args[0] == str(candidate) and env.get("REASON_NETWORK_LOCAL_PARTICIPATION") == "1" and (loaded or not primary):
        return
    prefix = "launch-agent-" if primary else "workspace-" + plist.stem + "-"
    with tempfile.NamedTemporaryFile(dir=root, prefix=prefix, suffix=".plist", delete=False) as backup:
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
    if loaded:
        run("launchctl", "bootout", service)
    try:
        replace_plist(plistlib.dumps(job))
        if not loaded and not primary:
            return
        bootstrap()
        # A stock MCP may have started a standalone daemon while the service was unloaded.
        cli_paths = {(Path.home() / folder / "reason-network").resolve() for folder in (".local/bin", ".reason/bin")} if primary else set()
        handed_off = False
        path = state / "network.sock"
        if len(os.fsencode(path)) >= 100:
            digest = 0xcbf29ce484222325
            for byte in os.fsencode(path):
                digest = ((digest ^ byte) * 0x100000001b3) & 0xffffffffffffffff
            path = Path(f"/tmp/reason-network-{os.getuid()}/{digest:016x}.sock")
        for _ in range(40):
            try:
                with socket.socket(socket.AF_UNIX) as sock:
                    sock.settimeout(2)
                    sock.connect(str(path))
                    sock.sendall(b'{"op":"session_participation","id":1}\n')
                    with sock.makefile("rb") as reader:
                        reply = json.loads(reader.readline(1024 * 1024))
                        pid, = struct.unpack("i", sock.getsockopt(0, 2, struct.calcsize("i")))
                        process = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
                        peer = Path(process.stdout.strip()).resolve() if process.returncode == 0 else None
                        if peer == candidate and reply.get("ok") and reply["result"].get("agent_join_setup"):
                            print(plist.stem, "is running", candidate.name)
                            return
                        if not handed_off and peer in cli_paths:
                            sock.sendall(b'{"op":"shutdown","id":2}\n')
                            handed_off = json.loads(reader.readline(1024 * 1024)).get("ok") is True
            except (OSError, ValueError):
                pass
            time.sleep(0.5)
        raise RuntimeError("Daemon did not advertise harness presence tracking")
    except BaseException:
        subprocess.run(["launchctl", "bootout", service], check=False)
        replace_plist(old)
        if loaded:
            bootstrap()
        raise

if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(strict=True))

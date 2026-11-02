#!/usr/bin/env python3
"""SIGTERM test for omnigent-browser-host: the host exits 0, removes host.json and leaves no
child process behind (CEF helpers, the network service, the encoder).

    shutdown_test.py --host build/host/omnigent-browser-host [--encoder PATH]
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rb_client import AttachClient, ControlClient

PAGE = Path(__file__).resolve().parent.parent / "tests" / "pages" / "smoke.html"


def descendants(root: int) -> set[int]:
    """Live descendants of `root`, from `ps`."""
    output = subprocess.run(
        ["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True, check=True
    ).stdout
    children: dict[int, list[int]] = {}
    for line in output.splitlines():
        pid, parent = (int(value) for value in line.split())
        children.setdefault(parent, []).append(pid)
    found: set[int] = set()
    pending = [root]
    while pending:
        for child in children.get(pending.pop(), []):
            if child not in found:
                found.add(child)
                pending.append(child)
    return found


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # Reused by another user's process; not ours.
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--host", required=True)
    parser.add_argument("--encoder")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="rb-term-"))
    profile_dir = work / "p"
    socket_path = work / "s"
    command = [args.host, "--profile-dir", str(profile_dir), "--socket", str(socket_path)]
    if args.encoder:
        command += ["--encoder", args.encoder]
    log = (work / "host.log").open("wb")
    host = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    failures: list[str] = []
    try:
        deadline = time.monotonic() + 60
        while not (profile_dir / "host.json").exists():
            if host.poll() is not None or time.monotonic() > deadline:
                print(f"FAIL: host did not start (log {work / 'host.log'})")
                return 1
            time.sleep(0.1)
        control = ControlClient(str(socket_path))
        tab = control.request(
            "tabs.create", {"session_id": "term", "url": PAGE.as_uri(), "created_by": "user"}
        )
        viewer = AttachClient(str(socket_path), tab["id"], mode="view")
        viewer.wait_for(lambda state: len(state.frames) >= 1, 20, "a frame (encoder running)")
        children = descendants(host.pid)
        print(f"host {host.pid} has {len(children)} descendant processes before SIGTERM")
        if len(children) < 2:
            failures.append(f"expected CEF helpers and an encoder, found {sorted(children)}")
        host.send_signal(signal.SIGTERM)
        try:
            host.wait(timeout=30)
        except subprocess.TimeoutExpired:
            failures.append("the host did not exit within 30 s of SIGTERM")
            host.kill()
            host.wait()
        if host.returncode != 0:
            failures.append(f"the host exited with {host.returncode}")
        if (profile_dir / "host.json").exists():
            failures.append("host.json was left behind")
        time.sleep(1)
        survivors = sorted(pid for pid in children if alive(pid))
        if survivors:
            failures.append(f"child processes survived the host: {survivors}")
            for pid in survivors:
                os.kill(pid, signal.SIGKILL)
    finally:
        if host.poll() is None:
            host.kill()
        log.close()
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        print(f"host log: {work / 'host.log'}")
        return 1
    shutil.rmtree(work)
    print("PASS: SIGTERM exits 0, removes host.json and leaves no child processes")
    return 0


if __name__ == "__main__":
    sys.exit(main())

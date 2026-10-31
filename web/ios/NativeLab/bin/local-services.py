#!/usr/bin/env python3
"""Manage only this checkout's two NativeLab user launch agents."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import plistlib
import pwd
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
BASE_URL = "http://127.0.0.1:6767"
LABELS = {kind: f"ai.omnigent.native-lab.{kind}" for kind in ("api", "host")}
SCRIPTS = {"api": "local-server.sh", "host": "local-host.sh"}


class ServiceError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ARG002
        raise ServiceError(f"Local API redirected ({code}); refusing {newurl}")


def get_json(path):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(BASE_URL + path, timeout=2) as response:
        return json.load(response)


def check_api():
    if get_json("/health").get("status") != "ok":
        raise ServiceError("API health is not ok")
    info = get_json("/v1/info")
    if info.get("single_user") is not True or info.get("accounts_enabled") is not False:
        raise ServiceError("Port 6767 is not the expected single-user API")
    if get_json("/v1/me").get("user_id") != "local":
        raise ServiceError("Unexpected API identity (expected local)")


def wait_for(check, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return check()
        except (OSError, ValueError, ServiceError) as exc:
            if time.monotonic() >= deadline:
                raise ServiceError(f"Readiness timed out after {timeout:g}s: {exc}") from exc
            time.sleep(1)


def check_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", 6767))
        except OSError as exc:
            raise ServiceError(
                f"Cannot bind 127.0.0.1:6767: {exc}. No process was stopped. "
                "Inspect with /usr/sbin/lsof -nP -iTCP:6767 -sTCP:LISTEN; "
                "stop the port owner explicitly before starting NativeLab."
            ) from exc


def wait_api(timeout):
    # At login both jobs can load together; never register against a port squatter.
    check = (
        Services().api_ready if os.environ.get("XPC_SERVICE_NAME") == LABELS["host"] else check_api
    )
    wait_for(check, timeout)


def host_identity(repo, create=False):
    # The CLI's default identity path ignores OMNIGENT_CONFIG_HOME.
    import yaml

    from omnigent.host.identity import HostIdentity, load_or_create_host_identity

    path = repo / ".native-lab-server/host-config/config.yaml"
    if create:
        return load_or_create_host_identity(path)
    if not path.exists():
        raise ServiceError("NativeLab host identity has not been created yet")
    data = yaml.safe_load(path.read_text()) or {}
    host = data.get("host", {})
    if not host.get("host_id") or not host.get("name"):
        raise ServiceError(f"Invalid NativeLab host identity in {path}")
    return HostIdentity(host_id=host["host_id"].removeprefix("host_"), name=host["name"])


class Services:
    def __init__(self, repo=REPO, home=None):
        self.repo = repo.resolve()
        self.home = home or Path(pwd.getpwuid(os.getuid()).pw_dir)
        self.runtime = self.repo / ".native-lab-server"
        self.staged = self.runtime / "launchd"
        self.installed = self.home / "Library/LaunchAgents"
        self.logs = self.runtime / "service-logs"
        self.domain = f"gui/{os.getuid()}"

    def target(self, kind):
        return f"{self.domain}/{LABELS[kind]}"

    def plist_path(self, kind, installed=True):
        return (self.installed if installed else self.staged) / f"{LABELS[kind]}.plist"

    def launchctl(self, *args, check=True):
        result = subprocess.run(
            ["/bin/launchctl", *args], capture_output=True, text=True, timeout=30
        )
        if check and result.returncode:
            raise ServiceError(f"launchctl {' '.join(args)}: {result.stderr.strip()}")
        return result

    def job(self, kind):
        result = self.launchctl("print", self.target(kind), check=False)
        if result.returncode:
            if "Could not find service" in result.stderr:
                return None
            raise ServiceError(
                f"Cannot inspect {self.target(kind)}: {result.stderr.strip()}. "
                "Run in the logged-in user's GUI session (outside the agent sandbox)."
            )
        output = result.stdout
        script = str(self.repo / "web/ios/NativeLab/bin" / SCRIPTS[kind])
        if not any(line.strip() == script for line in output.splitlines()):
            raise ServiceError(f"{LABELS[kind]} belongs to another checkout; leaving it alone")
        pid = re.search(r"^\s*pid = (\d+)$", output, re.MULTILINE)
        state = re.search(r"^\s*state = (.+)$", output, re.MULTILINE)
        return {"pid": int(pid[1]) if pid else None, "state": state[1] if state else "unknown"}

    def definition(self, kind):
        # Capture executable directories, never shell credentials or a session CODEX_HOME.
        dirs = [str(self.repo / ".venv/bin")]
        for binary in ("codex", "claude", "node", "tmux"):
            found = shutil.which(binary)
            if found and Path(found).is_absolute():
                dirs.append(str(Path(found).parent))
        dirs.extend(
            [
                str(self.home / ".local/bin"),
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            ]
        )
        return {
            "Label": LABELS[kind],
            "ProgramArguments": [
                "/bin/bash",
                str(self.repo / "web/ios/NativeLab/bin" / SCRIPTS[kind]),
            ],
            "WorkingDirectory": str(self.repo),
            "EnvironmentVariables": {
                "HOME": str(self.home),
                "PATH": ":".join(dict.fromkeys(dirs)),
                "PYTHONUNBUFFERED": "1",
            },
            "RunAtLoad": True,
            "KeepAlive": True,
            "ThrottleInterval": 10,
            "ExitTimeOut": 30,
            "LimitLoadToSessionType": "Aqua",
            "Umask": 0o077,
            "StandardOutPath": str(self.logs / f"{kind}.stdout.log"),
            "StandardErrorPath": str(self.logs / f"{kind}.stderr.log"),
        }

    def assert_owned_file(self, kind, path):
        if path.is_symlink():
            raise ServiceError(f"Refusing to replace or remove symlink: {path}")
        if not path.exists():
            return
        with path.open("rb") as stream:
            value = plistlib.load(stream)
        expected = self.definition(kind)
        for key in ("Label", "ProgramArguments", "WorkingDirectory"):
            if value.get(key) != expected[key]:
                raise ServiceError(f"{path} belongs to another installation; leaving it alone")

    def preflight(self):
        for kind in LABELS:
            self.assert_owned_file(kind, self.plist_path(kind))
            self.assert_owned_file(kind, self.plist_path(kind, installed=False))
            self.job(kind)

    def install(self):
        self.preflight()
        if not os.access(self.repo / ".venv/bin/omnigent", os.X_OK):
            raise ServiceError("Install the repo's .venv dependencies before installing services")
        self.installed.mkdir(parents=True, exist_ok=True)
        self.staged.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.logs.mkdir(parents=True, exist_ok=True, mode=0o700)
        for kind in LABELS:
            content = plistlib.dumps(self.definition(kind), sort_keys=False)
            for path in (self.plist_path(kind, False), self.plist_path(kind)):
                if path.exists() and path.read_bytes() == content:
                    continue
                with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
                    temp = Path(stream.name)
                    stream.write(content)
                try:
                    temp.chmod(0o600)
                    temp.replace(path)
                finally:
                    temp.unlink(missing_ok=True)
            for suffix in ("stdout", "stderr"):
                path = self.logs / f"{kind}.{suffix}.log"
                path.touch(mode=0o600, exist_ok=True)
                path.chmod(0o600)
            self.launchctl("enable", self.target(kind))
        print("Installed for automatic start at user login; existing jobs were not restarted.")
        print(
            "Run local-services.sh start to start now. Changed definitions apply after stop/start."
        )

    def check_listener(self, expected_pid):
        result = subprocess.run(
            ["/usr/sbin/lsof", "-nP", "-a", "-iTCP:6767", "-sTCP:LISTEN", "-Fpn"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        owners = {int(line[1:]) for line in result.stdout.splitlines() if line.startswith("p")}
        addresses = {line[1:] for line in result.stdout.splitlines() if line.startswith("n")}
        if owners != {expected_pid} or addresses != {"127.0.0.1:6767"}:
            raise ServiceError(
                f"Expected only launchd API pid={expected_pid} on 127.0.0.1:6767; "
                f"found pids={sorted(owners)}, listeners={sorted(addresses)}. "
                "No process was stopped."
            )

    def api_ready(self):
        job = self.job("api")
        if not job or not job["pid"]:
            raise ServiceError("API job is not running")
        self.check_listener(job["pid"])
        check_api()

    def host_ready(self):
        job = self.job("host")
        if not job or not job["pid"]:
            raise ServiceError("Host job is not running")
        identity = host_identity(self.repo)
        hosts = get_json("/v1/hosts").get("hosts", [])
        host = next((row for row in hosts if row.get("host_id") == identity.host_id), None)
        if not host or host.get("status") != "online":
            raise ServiceError(f"NativeLab host {identity.host_id} is not online")
        return {
            "host_id": identity.host_id,
            "status": host["status"],
            "codex_native": host.get("configured_harnesses", {}).get("codex-native"),
        }

    def start(self, timeout):
        self.preflight()
        for kind in LABELS:
            if not self.plist_path(kind).exists():
                raise ServiceError(
                    "Services are not installed. Run local-services.sh install first"
                )
        if not self.job("api"):
            check_port()
        for kind, check in (("api", self.api_ready), ("host", self.host_ready)):
            self.launchctl("enable", self.target(kind))
            if not self.job(kind):
                self.launchctl("bootstrap", self.domain, str(self.plist_path(kind)))
            # Never kickstart -k: repeated start must preserve live streaming turns.
            wait_for(check, timeout)
        return self.status()

    def status(self):
        report = {"url": BASE_URL, "logs": str(self.logs), "healthy": False, "jobs": {}}
        for kind in LABELS:
            report["jobs"][kind] = {
                "installed": self.plist_path(kind).exists(),
                "launchd": self.job(kind),
            }
        try:
            self.api_ready()
            report["identity"] = "local"
            report["host"] = self.host_ready()
            report["healthy"] = True
        except (OSError, ValueError, ServiceError) as exc:
            report["error"] = str(exc)
        print(json.dumps(report, indent=2))
        return 0 if report["healthy"] else 1

    def stop(self):
        self.preflight()
        for kind in ("host", "api"):
            # disable persists the explicit stop across the next login too.
            self.launchctl("disable", self.target(kind))
            if self.job(kind):
                self.launchctl("bootout", self.target(kind))
        print("Stopped only NativeLab; data and provider login preserved. Use start to re-enable.")

    def uninstall(self):
        self.stop()
        for kind in LABELS:
            self.plist_path(kind).unlink(missing_ok=True)
            self.plist_path(kind, False).unlink(missing_ok=True)
        print("Removed NativeLab launch agents; config, data, artifacts and logs preserved.")

    @contextlib.contextmanager
    def lock(self):
        self.staged.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.staged / "control.lock").open("a") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise ServiceError("Another NativeLab lifecycle command is running") from exc
            yield


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=(
            "install",
            "start",
            "status",
            "stop",
            "uninstall",
            "check-port",
            "wait-api",
            "host-id",
        ),
    )
    parser.add_argument("--timeout", type=float, default=60, help="Readiness timeout in seconds")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    os.umask(0o077)
    try:
        if args.command == "check-port":
            check_port()
        elif args.command == "wait-api":
            wait_api(args.timeout)
        elif args.command == "host-id":
            print(host_identity(REPO, create=True).host_id)
        else:
            if sys.platform != "darwin" or os.getuid() == 0:
                raise ServiceError("Run as your regular logged-in macOS user, without sudo")
            services = Services()
            if args.command == "status":
                return services.status()
            with services.lock():
                if args.command == "start":
                    return services.start(args.timeout)
                getattr(services, args.command)()
    except (OSError, ValueError, ServiceError, subprocess.TimeoutExpired) as exc:
        print(
            f"NativeLab: {exc}\nLogs: {REPO / '.native-lab-server/service-logs'}", file=sys.stderr
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

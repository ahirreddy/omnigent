"""Lifecycle regression checks; live launchd validation is recorded separately."""

import importlib.util
import io
import os
import plistlib
import socket
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "local_services", Path(__file__).with_name("local-services.py")
)
services = importlib.util.module_from_spec(spec)
spec.loader.exec_module(services)


class FakeLaunchd(services.Services):
    def __init__(self, repo, home):
        super().__init__(repo, home)
        self.calls = []
        self.loaded = {}

    def launchctl(self, *args, check=True):
        self.calls.append(args)
        output = ""
        error = ""
        code = 0
        if args[0] == "print":
            kind = args[1].rsplit(".", 1)[1]
            if kind not in self.loaded:
                code, error = 113, "Could not find service"
            else:
                script = self.repo / "web/ios/NativeLab/bin" / services.SCRIPTS[kind]
                output = f"arguments = {{\n\t/bin/bash\n\t{script}\n}}\n"
                output += f"state = running\npid = {self.loaded[kind]}\n"
        elif args[0] == "bootstrap":
            with Path(args[2]).open("rb") as stream:
                label = plistlib.load(stream)["Label"]
            self.loaded[label.rsplit(".", 1)[1]] = 100 + len(self.loaded)
        elif args[0] == "bootout":
            self.loaded.pop(args[1].rsplit(".", 1)[1], None)
        elif args[0] not in ("enable", "disable"):
            raise AssertionError(f"Unexpected launchctl mutation: {args}")
        if check and code:
            raise services.ServiceError(error)
        return subprocess.CompletedProcess(args, code, stdout=output, stderr=error)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="native lab tests ")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.manager = FakeLaunchd(root / "checkout", root / "home")
        binary = self.manager.repo / ".venv/bin/omnigent"
        binary.parent.mkdir(parents=True)
        binary.touch(mode=0o700)
        self.sentinel = self.manager.runtime / "data/chat.db"
        self.sentinel.parent.mkdir(parents=True)
        self.sentinel.write_bytes(b"existing database")
        self.output = self.enterContext(redirect_stdout(io.StringIO()))

    def install(self):
        self.manager.install()

    def test_install_is_repeatable_and_keeps_private_state(self):
        self.install()
        paths = [self.manager.plist_path(kind) for kind in services.LABELS]
        stats = [path.stat().st_mtime_ns for path in paths]
        self.install()
        self.assertEqual(stats, [path.stat().st_mtime_ns for path in paths])
        self.assertEqual(self.sentinel.read_bytes(), b"existing database")
        for path in paths:
            definition = plistlib.loads(path.read_bytes())
            self.assertEqual(definition["EnvironmentVariables"]["HOME"], str(self.manager.home))
            self.assertNotIn("CODEX_HOME", definition["EnvironmentVariables"])
            self.assertTrue(definition["KeepAlive"])
            self.assertTrue(definition["RunAtLoad"])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(definition["ProgramArguments"][0], "/bin/bash")
        self.assertFalse(any(call[0] == "bootstrap" for call in self.manager.calls))

    def test_start_twice_never_restarts_or_bootstraps_twice(self):
        self.install()
        with (
            patch.object(services, "check_port") as port,
            patch.object(self.manager, "api_ready"),
            patch.object(self.manager, "host_ready", return_value={"status": "online"}),
        ):
            self.assertEqual(self.manager.start(1), 0)
            pids = self.manager.loaded.copy()
            self.assertEqual(self.manager.start(1), 0)
        self.assertEqual(self.manager.loaded, pids)
        port.assert_called_once()
        self.assertEqual(sum(call[0] == "bootstrap" for call in self.manager.calls), 2)
        self.assertFalse(any(call[0] in ("bootout", "kickstart") for call in self.manager.calls))

    def test_busy_port_does_not_start_jobs_or_kill_owner(self):
        self.install()
        with (
            patch.object(services, "check_port", side_effect=services.ServiceError("busy")),
            self.assertRaisesRegex(services.ServiceError, "busy"),
        ):
            self.manager.start(1)
        self.assertFalse(self.manager.loaded)
        self.assertFalse(any(call[0] == "bootstrap" for call in self.manager.calls))

    def test_api_readiness_failure_does_not_bootstrap_host(self):
        self.install()
        with (
            patch.object(services, "check_port"),
            patch.object(services, "wait_for", side_effect=services.ServiceError("API not ready")),
            self.assertRaisesRegex(services.ServiceError, "API not ready"),
        ):
            self.manager.start(1)
        self.assertEqual(set(self.manager.loaded), {"api"})

    def test_stop_uninstall_repeatable_and_leave_data_and_other_jobs(self):
        self.install()
        other = self.manager.installed / "com.example.other.plist"
        other.write_bytes(b"untouched")
        self.manager.loaded = {"api": 100, "host": 101}
        self.manager.stop()
        self.manager.stop()
        self.manager.uninstall()
        self.manager.uninstall()
        self.assertEqual(self.sentinel.read_bytes(), b"existing database")
        self.assertEqual(other.read_bytes(), b"untouched")
        self.assertTrue((self.manager.logs / "api.stdout.log").exists())
        bootouts = [call[1] for call in self.manager.calls if call[0] == "bootout"]
        self.assertEqual(bootouts, [self.manager.target("host"), self.manager.target("api")])
        self.assertFalse(any(self.manager.plist_path(kind).exists() for kind in services.LABELS))

    def test_foreign_definition_refused_before_any_install_mutation(self):
        self.manager.installed.mkdir(parents=True)
        path = self.manager.plist_path("host")
        definition = self.manager.definition("host")
        definition["WorkingDirectory"] = "/another/checkout"
        path.write_bytes(plistlib.dumps(definition))
        with self.assertRaisesRegex(services.ServiceError, "another installation"):
            self.install()
        self.assertFalse(self.manager.plist_path("api").exists())
        self.assertFalse(any(call[0] in ("enable", "bootstrap") for call in self.manager.calls))

    def test_symlink_not_removed(self):
        self.manager.installed.mkdir(parents=True)
        self.manager.plist_path("api").symlink_to(self.sentinel)
        with self.assertRaisesRegex(services.ServiceError, "symlink"):
            self.manager.uninstall()
        self.assertEqual(self.sentinel.read_bytes(), b"existing database")

    def test_sandbox_error_is_not_treated_as_unloaded(self):
        result = subprocess.CompletedProcess([], 1, "", "Not privileged")
        with (
            patch.object(self.manager, "launchctl", return_value=result),
            self.assertRaisesRegex(services.ServiceError, "Cannot inspect"),
        ):
            self.manager.job("api")

    def test_foreign_loaded_job_refused(self):
        result = subprocess.CompletedProcess([], 0, "arguments = {\n/elsewhere/server.sh\n}", "")
        with (
            patch.object(self.manager, "launchctl", return_value=result),
            self.assertRaisesRegex(services.ServiceError, "another checkout"),
        ):
            self.manager.stop()

    def test_wildcard_or_foreign_listener_fails_even_when_http_healthy(self):
        for text in ("p100\nn*:6767\n", "p999\nn127.0.0.1:6767\n", ""):
            with self.subTest(text=text):
                result = subprocess.CompletedProcess([], 0, text, "")
                with (
                    patch.object(services.subprocess, "run", return_value=result),
                    self.assertRaisesRegex(services.ServiceError, "Expected only"),
                ):
                    self.manager.check_listener(100)

    def test_other_online_host_is_not_readiness(self):
        self.manager.loaded = {"host": 101}
        with (
            patch.object(services, "host_identity", return_value=SimpleNamespace(host_id="ours")),
            patch.object(
                services,
                "get_json",
                return_value={"hosts": [{"host_id": "other", "status": "online"}]},
            ),
            self.assertRaisesRegex(services.ServiceError, "ours is not online"),
        ):
            self.manager.host_ready()

    def test_status_never_creates_host_identity(self):
        path = self.manager.runtime / "host-config/config.yaml"
        with self.assertRaisesRegex(services.ServiceError, "not been created"):
            services.host_identity(self.manager.repo)
        self.assertFalse(path.exists())

    def test_identity_read_ignores_other_host_environment(self):
        path = self.manager.runtime / "host-config/config.yaml"
        path.parent.mkdir()
        path.write_text("host:\n  host_id: local-id\n  name: local-name\n")
        with patch.dict(os.environ, {"OMNIGENT_HOST_ID": "other", "OMNIGENT_HOST_NAME": "other"}):
            self.assertEqual(services.host_identity(self.manager.repo).host_id, "local-id")

    def test_controller_lock_prevents_overlapping_lifecycle_commands(self):
        with (
            self.manager.lock(),
            self.assertRaisesRegex(services.ServiceError, "Another NativeLab"),
            self.manager.lock(),
        ):
            self.fail("second lock unexpectedly acquired")


class EndpointTests(unittest.TestCase):
    def test_supervised_host_checks_launchd_api_ownership_before_connecting(self):
        with (
            patch.dict(os.environ, {"XPC_SERVICE_NAME": services.LABELS["host"]}),
            patch.object(services.Services, "api_ready") as ready,
            patch.object(services, "check_api") as http_only,
        ):
            services.wait_api(1)
        ready.assert_called_once()
        http_only.assert_not_called()

    def test_foreground_host_can_wait_for_foreground_api(self):
        with (
            patch.dict(os.environ, {"XPC_SERVICE_NAME": "0"}),
            patch.object(services.Services, "api_ready") as launchd,
            patch.object(services, "check_api") as ready,
        ):
            services.wait_api(1)
        ready.assert_called_once()
        launchd.assert_not_called()

    def test_wrong_identity_rejected(self):
        with (
            patch.object(
                services,
                "get_json",
                side_effect=[
                    {"status": "ok"},
                    {"single_user": True, "accounts_enabled": False},
                    {"user_id": "someone-else"},
                ],
            ),
            self.assertRaisesRegex(services.ServiceError, "Unexpected API identity"),
        ):
            services.check_api()

    def test_redirect_refused(self):
        with self.assertRaisesRegex(services.ServiceError, "redirected"):
            services.NoRedirect().redirect_request(None, None, 302, "", {}, "https://elsewhere")

    def test_port_error_explains_conflict_without_stopping_anything(self):
        with patch.object(services.socket, "socket") as constructor:
            constructor.return_value.__enter__.return_value.bind.side_effect = OSError("in use")
            with self.assertRaisesRegex(services.ServiceError, "No process was stopped"):
                services.check_port()
            constructor.assert_called_once_with(socket.AF_INET, socket.SOCK_STREAM)


if __name__ == "__main__":
    unittest.main()

"""Runner side of the runner/host contract: framing, discovery and host lifecycle."""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import signal
from collections.abc import AsyncIterator, Iterator
from pathlib import Path

import pytest

from omnigent.runner.browser_host import (
    BrowserHostError,
    BrowserHostManager,
    BrowserHostSettings,
    HostFrameKind,
    HostFrameTooLargeError,
    HostProtocolError,
    check_availability,
    decode_close_payload,
    encode_close_payload,
    encode_host_frame,
    encode_text_frame,
    host_request,
    read_host_frame,
)
from tests._helpers.fake_browser_host import install_fake_browser_host, stop_fake_browser_hosts

_FIXTURES = Path(__file__).resolve().parents[2] / "client-core" / "fixtures" / "remote_browser"


def _fixture_json(relative: str) -> dict[str, object]:
    return json.loads((_FIXTURES / relative).read_text(encoding="utf-8"))


def _reader_for(data: bytes) -> asyncio.StreamReader:
    reader = asyncio.StreamReader()
    reader.feed_data(data)
    reader.feed_eof()
    return reader


async def test_frames_round_trip_the_unix_socket_fixtures() -> None:
    index = _fixture_json("unix_socket/index.json")
    frames = index["frames"]
    assert isinstance(frames, list)
    for entry in frames:
        raw = (_FIXTURES / "unix_socket" / entry["file"]).read_bytes()
        frame = await read_host_frame(_reader_for(raw))
        assert frame is not None
        assert frame.kind == entry["kind"]
        assert len(frame.payload) == entry["payload_length"]
        assert encode_host_frame(frame.kind, frame.payload) == raw
    attach = _fixture_json("runner_host/attach.json")
    assert (
        encode_text_frame(attach) == (_FIXTURES / "unix_socket" / "text_attach.bin").read_bytes()
    )
    close = await read_host_frame(
        _reader_for((_FIXTURES / "unix_socket" / "close_4404.bin").read_bytes())
    )
    assert close is not None
    assert decode_close_payload(close.payload) == (4404, "tab closed")
    assert encode_close_payload(1000, "") == (1000).to_bytes(2, "little")


async def test_read_frame_end_of_stream_and_framing_errors() -> None:
    assert await read_host_frame(_reader_for(b"")) is None
    with pytest.raises(HostProtocolError, match="mid frame prefix"):
        await read_host_frame(_reader_for(b"\x01\x00"))
    with pytest.raises(HostProtocolError, match="mid frame payload"):
        await read_host_frame(_reader_for(b"\x05\x00\x00\x00\x01ab"))
    with pytest.raises(HostProtocolError, match="unknown host frame kind"):
        await read_host_frame(_reader_for(b"\x00\x00\x00\x00\x09"))
    oversized = (16 * 1024 * 1024 + 1).to_bytes(4, "little") + b"\x02"
    with pytest.raises(HostFrameTooLargeError):
        await read_host_frame(_reader_for(oversized))
    with pytest.raises(HostProtocolError, match="missing its code"):
        decode_close_payload(b"\x01")


@pytest.mark.parametrize(
    ("op", "args", "request_fixture", "response_fixture"),
    [
        ("health", {}, "request_health.json", "response_health.json"),
        (
            "tabs.list",
            {"session_id": "conv_a"},
            "request_tabs_list.json",
            "response_tabs_list.json",
        ),
        (
            "tabs.create",
            {
                "session_id": "conv_a",
                "url": "https://github.com/login",
                "created_by": "user",
                "width": 1280,
                "height": 800,
                "dpr": 1,
            },
            "request_tabs_create.json",
            "response_tabs_create.json",
        ),
        (
            "tabs.close",
            {"tab_id": "btab_7f3a9c2e"},
            "request_tabs_close.json",
            "response_tabs_close.json",
        ),
        (
            "tabs.close_session",
            {"session_id": "conv_a"},
            "request_tabs_close_session.json",
            "response_tabs_close_session.json",
        ),
    ],
)
async def test_host_request_speaks_the_fixture_wire_shape(
    short_socket_dir: Path,
    op: str,
    args: dict[str, object],
    request_fixture: str,
    response_fixture: str,
) -> None:
    """The runner sends the fixture preamble and request; the fixture response parses."""
    received: list[dict[str, object]] = []
    response = _fixture_json(f"runner_host/{response_fixture}")

    async def serve(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        for _ in range(2):
            frame = await read_host_frame(reader)
            assert frame is not None and frame.kind is HostFrameKind.TEXT
            received.append(json.loads(frame.payload))
        writer.write(encode_text_frame({**response, "id": received[1]["id"]}))
        await writer.drain()
        writer.close()

    socket_path = short_socket_dir / "h.sock"
    server = await asyncio.start_unix_server(serve, path=str(socket_path))
    async with server:
        result = await host_request(socket_path, op, args)
    expected_request = _fixture_json(f"runner_host/{request_fixture}")
    assert received[0] == _fixture_json("runner_host/control_preamble.json")
    assert {**received[1], "id": expected_request["id"]} == expected_request
    assert result == response["result"]


@pytest.mark.parametrize(
    ("response_fixture", "code"),
    [("response_not_found.json", "not_found"), ("response_unavailable.json", "unavailable")],
)
async def test_host_request_raises_the_host_error_code(
    short_socket_dir: Path, response_fixture: str, code: str
) -> None:
    response = _fixture_json(f"runner_host/{response_fixture}")

    async def serve(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await read_host_frame(reader)
        frame = await read_host_frame(reader)
        assert frame is not None
        writer.write(encode_text_frame({**response, "id": json.loads(frame.payload)["id"]}))
        await writer.drain()
        writer.close()

    socket_path = short_socket_dir / "h.sock"
    server = await asyncio.start_unix_server(serve, path=str(socket_path))
    async with server:
        with pytest.raises(BrowserHostError) as raised:
            await host_request(socket_path, "tabs.close", {"tab_id": "btab_missing"})
    assert raised.value.code == code
    assert raised.value.message == response["error"]["message"]  # type: ignore[index]


async def test_host_request_reports_an_unreachable_socket(short_socket_dir: Path) -> None:
    with pytest.raises(BrowserHostError) as raised:
        await host_request(short_socket_dir / "missing.sock", "health")
    assert raised.value.code == "unavailable"


def test_settings_from_env(tmp_path: Path) -> None:
    settings = BrowserHostSettings.from_env(
        {
            "OMNIGENT_REMOTE_BROWSER": "1",
            "OMNIGENT_DATA_DIR": str(tmp_path),
            "OMNIGENT_BROWSER_HOST_BIN": str(tmp_path / "bin" / "host"),
            "OMNIGENT_BROWSER_ENCODER": str(tmp_path / "x264"),
            "OMNIGENT_BROWSER_HOST_ARGS": "--no-sandbox --headless-mode xvfb",
            "OMNIGENT_BROWSER_HOST_START_TIMEOUT_S": "5",
        }
    )
    assert settings.enabled is True
    assert settings.browser_dir == tmp_path / "browser"
    assert settings.binary == tmp_path / "bin" / "host"
    assert settings.extra_args == ("--no-sandbox", "--headless-mode", "xvfb")
    assert settings.start_timeout_s == 5.0
    assert BrowserHostSettings.from_env({"OMNIGENT_DATA_DIR": str(tmp_path)}).enabled is False
    with pytest.raises(ValueError, match="must be positive"):
        BrowserHostSettings.from_env({"OMNIGENT_BROWSER_HOST_START_TIMEOUT_S": "0"})


def test_availability_reports_each_missing_piece(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    binary, encoder = install_fake_browser_host(tmp_path / "bin")
    # An empty PATH keeps a system x264/ffmpeg out of the encoder search.
    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    disabled = BrowserHostSettings(enabled=False, data_dir=tmp_path)
    assert check_availability(disabled).status == "disabled"
    missing_binary = BrowserHostSettings(enabled=True, data_dir=tmp_path)
    assert check_availability(missing_binary).status == "not_installed"
    no_encoder = BrowserHostSettings(enabled=True, data_dir=tmp_path, binary=binary)
    result = check_availability(no_encoder)
    assert result.status == "encoder_missing"
    assert "x264" in result.message
    available = BrowserHostSettings(
        enabled=True, data_dir=tmp_path, binary=binary, encoder=encoder
    )
    result = check_availability(available)
    assert result.status == "available"
    assert result.encoder is not None and result.encoder.kind == "x264"
    runtime = BrowserHostSettings(enabled=True, data_dir=tmp_path, runtime_dir=binary.parent)
    assert check_availability(runtime).binary == binary


def test_ffmpeg_without_libx264_is_not_an_encoder(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    binary, _encoder = install_fake_browser_host(tmp_path / "bin")
    tools = tmp_path / "tools"
    tools.mkdir()
    ffmpeg = tools / "ffmpeg"
    ffmpeg.write_text("#!/bin/sh\necho ' V..... libx265 H.265'\n")
    ffmpeg.chmod(0o755)
    monkeypatch.setenv("PATH", str(tools))
    settings = BrowserHostSettings(enabled=True, data_dir=tmp_path, binary=binary)
    assert check_availability(settings).status == "encoder_missing"
    ffmpeg.write_text("#!/bin/sh\necho ' V..... libx264 H.264'\n")
    result = check_availability(settings)
    assert result.encoder is not None and result.encoder.kind == "ffmpeg"


def test_socket_path_falls_back_when_too_long(tmp_path: Path) -> None:
    short = BrowserHostManager(BrowserHostSettings(enabled=True, data_dir=Path("/d")))
    assert short.socket_path("work") == Path("/d/browser/profiles/work/host.sock")
    deep = tmp_path / ("x" * 120)
    fallback = BrowserHostManager(BrowserHostSettings(enabled=True, data_dir=deep))
    path = fallback.socket_path("work")
    assert len(os.fsencode(path)) <= 100
    assert path.name.endswith("-work.sock")


@pytest.fixture
def short_socket_dir(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Path]:
    """A directory short enough for ``sun_path`` on macOS."""
    import tempfile

    with tempfile.TemporaryDirectory(prefix="rb-", dir="/tmp") as directory:
        yield Path(directory)


@pytest.fixture
async def fake_manager(tmp_path: Path) -> AsyncIterator[BrowserHostManager]:
    binary, encoder = install_fake_browser_host(tmp_path / "bin")
    manager = BrowserHostManager(
        BrowserHostSettings(
            enabled=True,
            data_dir=tmp_path / "data",
            binary=binary,
            encoder=encoder,
            extra_args=("--idle-exit-seconds", "60"),
            start_timeout_s=20,
        )
    )
    try:
        yield manager
    finally:
        await asyncio.to_thread(stop_fake_browser_hosts, manager.settings.browser_dir)


async def test_host_starts_on_demand_and_is_reused(fake_manager: BrowserHostManager) -> None:
    assert await fake_manager.list_tabs("conv_a") == []
    assert await fake_manager.running_hosts() == []
    tab = await fake_manager.create_tab("conv_a", url="https://example.com/")
    state = fake_manager.read_state("default")
    assert state is not None
    profile_dir = fake_manager.profile_dir("default")
    assert profile_dir.stat().st_mode & 0o777 == 0o700
    second = await fake_manager.create_tab("conv_a", profile="default")
    assert fake_manager.read_state("default") == state
    listed = await fake_manager.list_tabs("conv_a")
    assert [item["id"] for item in listed] == [tab["id"], second["id"]]
    assert await fake_manager.list_tabs("conv_b") == []
    profiles = await fake_manager.list_profiles()
    assert profiles == [{"name": "default", "default": True, "running": True}]


async def test_profiles_get_separate_hosts(fake_manager: BrowserHostManager) -> None:
    default_tab = await fake_manager.create_tab("conv_a")
    work_tab = await fake_manager.create_tab("conv_a", profile="work")
    default_state = fake_manager.read_state("default")
    work_state = fake_manager.read_state("work")
    assert default_state is not None and work_state is not None
    assert default_state.pid != work_state.pid
    assert default_state.socket != work_state.socket
    assert work_tab["profile"] == "work"
    resolved = await fake_manager.resolve_tab("conv_a", str(work_tab["id"]))
    assert resolved is not None and resolved[0].profile == "work"
    assert await fake_manager.resolve_tab("conv_other", str(default_tab["id"])) is None
    with pytest.raises(BrowserHostError) as raised:
        await fake_manager.create_tab("conv_a", profile="Bad Name")
    assert raised.value.code == "invalid_input"


async def test_crashed_host_is_restarted(fake_manager: BrowserHostManager) -> None:
    await fake_manager.create_tab("conv_a")
    crashed = fake_manager.read_state("default")
    assert crashed is not None
    os.kill(crashed.pid, signal.SIGKILL)
    while True:
        try:
            os.kill(crashed.pid, 0)
        except ProcessLookupError:
            break
        await asyncio.sleep(0.02)
    # The dead host's tabs are gone with it; listing does not start a new one.
    assert await fake_manager.list_tabs("conv_a") == []
    await fake_manager.create_tab("conv_a")
    restarted = fake_manager.read_state("default")
    assert restarted is not None and restarted.pid != crashed.pid


async def test_close_tab_and_session_cleanup(fake_manager: BrowserHostManager) -> None:
    first = await fake_manager.create_tab("conv_a")
    await fake_manager.create_tab("conv_a", profile="work")
    other = await fake_manager.create_tab("conv_b")
    assert await fake_manager.close_tab("conv_a", str(first["id"])) is True
    assert await fake_manager.close_tab("conv_a", str(first["id"])) is False
    assert await fake_manager.close_tab("conv_a", str(other["id"])) is False
    closed = await fake_manager.close_session_tabs("conv_a")
    assert len(closed) == 1
    assert await fake_manager.list_tabs("conv_a") == []
    assert [tab["id"] for tab in await fake_manager.list_tabs("conv_b")] == [other["id"]]


async def test_start_failure_reports_the_host_log(
    fake_manager: BrowserHostManager, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("FAKE_BROWSER_HOST_EXIT_CODE", "7")
    with pytest.raises(BrowserHostError) as raised:
        await fake_manager.create_tab("conv_a")
    assert raised.value.code == "unavailable"
    assert "exited with code 7" in raised.value.message
    assert "told to fail at startup" in raised.value.message


async def test_unavailable_host_refuses_to_start(tmp_path: Path) -> None:
    manager = BrowserHostManager(BrowserHostSettings(enabled=False, data_dir=tmp_path))
    with pytest.raises(BrowserHostError) as raised:
        await manager.create_tab("conv_a")
    assert raised.value.code == "unavailable"
    assert "OMNIGENT_REMOTE_BROWSER" in raised.value.message


def _detached(argv: list[str]) -> int:
    """Start *argv* reparented away from this test process (no zombie on exit)."""
    import subprocess

    launcher = subprocess.run(
        ["sh", "-c", 'exec "$@" >/dev/null 2>&1 & echo $!', "sh", *argv],
        capture_output=True,
        text=True,
        check=True,
    )
    return int(launcher.stdout.strip())


async def test_stale_host_json_reaps_only_that_profiles_helpers(
    fake_manager: BrowserHostManager,
) -> None:
    """A dead host's leftover helpers are terminated; a sibling profile's are not."""
    import sys

    profile_dir = fake_manager.profile_dir("work")
    sibling_dir = fake_manager.profile_dir("work2")
    for directory in (profile_dir, sibling_dir):
        directory.mkdir(parents=True)
    sleeper = [sys.executable, "-c", "import time; time.sleep(60)"]
    orphan = _detached([*sleeper, "--type=utility", f"--user-data-dir={profile_dir}"])
    sibling = _detached([*sleeper, "--type=utility", f"--user-data-dir={sibling_dir}"])
    dead_pid = _detached(["true"])
    (profile_dir / "host.json").write_text(
        json.dumps({"pid": dead_pid, "socket": "/nonexistent.sock", "profile": "work"})
    )
    try:
        while True:
            try:
                os.kill(dead_pid, 0)
            except ProcessLookupError:
                break
            await asyncio.sleep(0.02)
        assert await fake_manager.running_hosts() == []
        assert not (profile_dir / "host.json").exists()
        with pytest.raises(ProcessLookupError):
            os.kill(orphan, 0)
        os.kill(sibling, 0)
    finally:
        for pid in (orphan, sibling):
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGKILL)


@pytest.mark.parametrize("enabled", [True, False])
async def test_runner_hello_advertises_remote_browser_when_available(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, enabled: bool
) -> None:
    from omnigent.runner import browser_host
    from omnigent.runner.transports.ws_tunnel.serve import _send_hello

    binary, encoder = install_fake_browser_host(tmp_path / "bin")
    monkeypatch.setenv("OMNIGENT_REMOTE_BROWSER", "1" if enabled else "0")
    monkeypatch.setenv("OMNIGENT_BROWSER_HOST_BIN", str(binary))
    monkeypatch.setenv("OMNIGENT_BROWSER_ENCODER", str(encoder))
    monkeypatch.setattr(browser_host, "_hello_capabilities_cache", None)
    sent: list[str] = []

    async def send_text(text: str) -> None:
        sent.append(text)

    await _send_hello(send_text, "0.0.0")
    capabilities = json.loads(sent[0])["capabilities"]
    assert ("remote_browser" in capabilities) is enabled

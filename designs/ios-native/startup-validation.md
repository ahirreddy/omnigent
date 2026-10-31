# NativeLab persistent startup validation

Validated 2026-10-31 in the shared checkout. No commits or resets.

## Streaming handoff

The dedicated API and host are **healthy and left running**. Streaming validation
can use `http://127.0.0.1:6767` now. No restart will be performed after this handoff
without coordinating the streaming test.

- API launchd PID: `61849`; host launchd PID: `61884`.
- `GET /health`: `status=ok`.
- `GET /v1/info`: `single_user=true`, `accounts_enabled=false`.
- `GET /v1/me`: `user_id=local`.
- `GET /v1/hosts`: isolated host `cb7cc819661b4d93a5e4f640c57ee296`
  is `online`, `configured_harnesses.codex-native=true`.
- Listener ownership check: only API PID `61849`, only `127.0.0.1:6767`.

These are checks against the running services, not fixture-based startup claims.
They do not prove a model turn or incremental streaming; item 4 owns that proof.
The session-message tool rejected the attempted parent coordination message;
the healthy status was delivered in commentary, including after the parent's
status request. This document records the same handoff.

## Usage

Run from the repository root, as the logged-in macOS user:

```sh
bash web/ios/NativeLab/bin/local-services.sh install
bash web/ios/NativeLab/bin/local-services.sh start
bash web/ios/NativeLab/bin/local-services.sh status
```

`install` writes private plists to `~/Library/LaunchAgents`, with copies under
`.native-lab-server/launchd`, and enables the two labels. It does not restart
loaded jobs. `start` loads missing jobs, checks API ownership/identity, then
waits for this isolated host to report online. Repeated `start` leaves running
PIDs unchanged. `status` returns JSON and exit 0 only when both are healthy.

```sh
bash web/ios/NativeLab/bin/local-services.sh stop
bash web/ios/NativeLab/bin/local-services.sh uninstall
```

Coordinate with active chat/streaming tests before these commands. `stop`
disables both jobs, including at subsequent logins, and unloads host before API.
`start` enables them again. `uninstall` stops the jobs and removes only their
installed/staged plists. Both preserve config, database, artifacts, workspace,
provider login and logs. Commands never call global `omnigent host stop`, kill a
port owner, or operate on other launchd labels. Definitions belonging to another
checkout are refused. Moving the checkout requires reinstalling from its new
location after uninstalling the old installation.

## Supervision and isolation

Labels: `ai.omnigent.native-lab.api` and `ai.omnigent.native-lab.host`, in
`gui/502` on this machine. Both use `RunAtLoad`, `KeepAlive`, a ten-second restart
throttle and restrictive umask. User LaunchAgents load at GUI login, including
login after reboot. They stop at logout; they do not run while nobody is logged
in. Installation persists across logout/reboot.

HOME is the actual user's home so provider CLI login stays available. PATH is
explicit, includes the checkout venv, discovered provider/tool directories and
Homebrew/system locations; no shell startup file is required. Shell credentials
and the calling session's CODEX_HOME are not copied into plists. The launchers
clear inherited deployment settings and pin separate API and host config/data.
The API runs from its runtime directory to avoid project-level configuration.

The host now keeps its identity in
`.native-lab-server/host-config/config.yaml` and passes it explicitly. This
avoids the host CLI's default global identity path. Old local sessions bound to
the prior global host ID retain their data but are not silently rebound; create
or reuse a session on the new online isolated host for streaming validation.

Launchd stdout/stderr append to `.native-lab-server/service-logs/`. Application
logs remain under the isolated `data/logs` and `host-data/logs` directories.
Launchd logs are not automatically rotated by this command.

If another process owns port 6767, startup fails with a diagnostic and leaves
that process alone. Inspect it with:

```sh
/usr/sbin/lsof -nP -iTCP:6767 -sTCP:LISTEN
```

The server always binds literal `127.0.0.1`; no LAN listener is installed.
At login the host waits for the dedicated launchd API to own that listener,
so it cannot register against an unrelated process that takes the port first.

## Verification

- 19 focused Python regression tests pass: idempotency, private installation,
  foreign job/file protection, port refusal, matching host identity, listener
  ownership, supervised startup ordering, redirects and lifecycle command locking.
- Ruff lint/format and `bash -n` pass for the changed scripts.
- Actual macOS install twice, stop twice, uninstall twice, then reinstall passed
  **before** starting these services. The stop checks exercised unloaded jobs;
  stopping active jobs was not attempted after the healthy handoff.
- A real socket occupied `127.0.0.1:6767`; `start` rejected it and the original
  socket remained open. No NativeLab jobs were started during that check.
- Actual launchd bootstrap and API/host readiness passed as reported above.
- Repeated live `start` preserved API PID `61849` and host PID `61884`.
  Both processes have parent PID 1 and launchd reports `runs=1`,
  `keepalive | runatload`. The unrelated hosted host remained PID `32270`.
- Both installed plists pass `plutil -lint`, are mode `0600`, and point at this
  checkout with explicit HOME/PATH. The supervised host readiness preflight
  also passes against the live API without restarting any service.
- Machine-readable pre-start, endpoint and final status evidence:
  `.native-lab-server/launchd/startup-validation.json`.

Reproduce the nondisruptive checks:

```sh
.venv/bin/python -m unittest discover -s web/ios/NativeLab/bin -p test_local_services.py -v
.venv/bin/ruff check web/ios/NativeLab/bin/local-services.py web/ios/NativeLab/bin/test_local_services.py
.venv/bin/ruff format --check web/ios/NativeLab/bin/local-services.py web/ios/NativeLab/bin/test_local_services.py
bash -n web/ios/NativeLab/bin/local-server.sh web/ios/NativeLab/bin/local-host.sh web/ios/NativeLab/bin/local-services.sh
bash web/ios/NativeLab/bin/local-services.sh status
curl --noproxy '*' -fsS http://127.0.0.1:6767/v1/me
```

## Remaining validation

Actual logout/reboot and a forced process crash have not been exercised; doing
so would interrupt the shared desktop or active streaming work. Persistent
installation and launchd restart policy are verified, with real initial startup.
Provider readiness is reported online/configured; the separate real-turn test
must establish provider execution and streaming.

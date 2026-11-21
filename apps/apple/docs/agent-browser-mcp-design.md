# Agent browser through Chrome DevTools MCP: design and plan

Status: accepted with the user decisions in 1.1, 2026-11-20. Phase 1 (shared proxy, injection,
remote host directory) in progress.

Agents in an Omnigent session get Google's `chrome-devtools-mcp` with every tool it ships:
pages and tabs, navigation, snapshots, click/fill/fill_form/hover/drag/press_key/upload,
dialogs, `evaluate_script`, console, network, performance traces and insights, CPU and
network emulation, resize and waits. The same server runs unchanged against two browsers:

- **Local:** the Mac app's in-app Chromium (CEF in `Omnigent Web Host.app`). It carries the
  user's own logins, 2FA and passkeys.
- **Remote:** the streamed CEF host (`browser-host/`) next to the runner. It works with the
  laptop closed; the user watches and takes over through the H.264 stream.

We run the real `chrome-devtools-mcp` and put an Omnigent CDP proxy in front of each browser.
We do not reimplement its tools.

## 1. Decisions at a glance

| Topic | Decision |
|---|---|
| MCP server | `chrome-devtools-mcp@1.12.0` (published 2026-10-22, outside the 7-day cooldown), launched with `npx -y` on the runner machine, `--wsEndpoint` pointing at the proxy |
| How harnesses get it | A per-session stdio `MCPServerConfig` named `chrome_devtools`, added by the runner to the session's resolved spec. Omnigent's existing MCP path offers it to every SDK harness and, through the relay MCP surface, to every native harness |
| CDP endpoint | **One scoped CDP proxy per runner process**, on `127.0.0.1`, with a per-session token in the path. Each agent connection gets its own upstream browser connection |
| Scoping | The proxy presents a *virtual browser* that contains only the session's tabs. It emulates the browser-level `Target` domain, attaches to allowed pages itself, and never forwards browser-level auto-attach |
| New pages | `Target.createTarget` becomes a real tab: an app tab in the session's tab group locally, a host tab (`tabs.create`, `created_by: agent`) remotely |
| User control | While the user holds a tab, the proxy refuses actuating methods (`Input.*`, navigation, dialogs, uploads, emulation, close) with an error that tells the agent to wait |
| Local browser endpoint | No DevTools port: the Web Host serves DevTools over `--remote-debugging-pipe` to the app alone, and the app opens a loopback WebSocket gate with a per-session secret on an owner's `attach` (section 3.4), behind the setting *Let agents use this Mac's browser* (on by default). Tab directory over an owner-only server relay |
| Remote browser endpoint | The profile host's existing loopback CDP port (`host.json` `cdp_port`); tab directory over `host.sock` |
| Which browser | Label `omnigent.browser_target` = `auto` (default), `local` or `remote`. `auto` decides at connection time and asks once only when both are plausible. A chip in the session UI switches with one click |
| Existing `browser_*` tools | Hidden for a session that gets DevTools MCP; kept unchanged everywhere else (web and Electron panes, flag off) |
| Indicator | One agent state per tab for both browsers: `idle`, `active`, `user` (you're in control), `needs_you` (handoff). Badge in the tab strip and the session's tab list, banner with **Stop** and **Take over** on the page |
| Background operation (local) | Agent-held tabs render offscreen (`WebView.rendersOffscreen`), so CEF never sees them hidden; input only through CDP `Input.*`; focus emulation per agent page session; screenshots through `Page.captureScreenshot`; page and session stream pinned while held |
| Security | Local browser is owner-only and deny-by-default for shared sessions and viewers; profile-wide CDP methods (cookie jars, cache, downloads, extensions, WebAuthn, browser close) are refused for both browsers |

### 1.1 User decisions (2026-11-20)

- *Let agents use this Mac's browser* is **on by default**. Shared sessions and viewers still
  cannot use the local browser.
- **Stop keeps the agent's tabs open.** It takes over the tab and interrupts the turn; nothing
  is closed.
- **Unattended runs prefer the remote browser.** For scheduled automations and other runs with
  nobody watching, `auto` picks the remote browser when it is usable. A hand-off can still be
  requested.

## 2. What exists today (grounding)

- **Built-in browser tools.** `omnigent/tools/builtins/browser.py` (`BROWSER_TOOL_NAMES`),
  `browser_advanced.py`, `omnigent/tools/browser_agent_tools.py` (header
  `x-omnigent-browser-agent-tools`, label `omnigent.browser_agent_tools`). The runner's
  `_BROWSER_TOOLS` branch (`omnigent/runner/tool_dispatch.py`) POSTs
  `/v1/sessions/{id}/browser/action_request`; `routes_browser.py` publishes
  `browser.action_request` on the session stream, any subscribed renderer claims it
  (2 s claim grace, 30 s result, `LEVEL_EDIT`), and posts the result. The Mac app performs
  them in `BrowserActionStore` + `AgentBrowserController` in an **ephemeral** `agent:<conv>`
  profile: no user identity, no CDP.
- **MCP plumbing.** `MCPServerConfig` (`omnigent/spec/types.py`) supports stdio. Every harness
  reaches spec MCP tools through the server (`/v1/sessions/{id}/mcp`, policy) and the runner's
  `RunnerMcpManager`, which spawns stdio servers on the runner machine and **shares one process
  between sessions whose server configs hash equal**. Native harnesses see them through the
  relay MCP surface (`_ensure_comment_relay_started` appends `ProxyMcpManager.schemas_for`).
  pi-native does not append spec MCP schemas today (gap, fixed in phase 1).
- **Spec resolution.** `spec_resolver(agent_id, session_id)` in `omnigent/runner/_entry.py`
  extracts a fresh bundle per call and applies server headers (`selected_mcp_spec`,
  `without_memory_tools`, ...). Each session therefore holds its own `AgentSpec` object.
- **Feature flags.** `omnigent/server/feature_flags.py` (`Feature`, `FEATURE_DEFINITIONS`),
  served in `/v1/info` `features`.
- **Remote host.** `browser-host/` is built (M0, M1). Each profile host sets CEF
  `remote_debugging_port` to a free loopback port and publishes it in `host.json`. The runner's
  `BrowserHostManager` (`omnigent/runner/browser_host.py`) has `ensure_host`, `list_tabs`,
  `create_tab(created_by=...)`, `close_tab`; tab records carry `target_id`, `session_id`,
  `owner` (`agent`/`user`). Nothing uses the CDP port yet. Browsers that Chromium creates for
  raw `Target.createTarget` arrive through `GetDefaultClient` as non-painting tabs with no
  session (remote design §6), so they must never be created that way.
- **Local Web Host.** One `Omnigent Web Host.app` process for all tabs, windowless (OSR). The
  app talks to it over OWL (Mach ports). `remoteDebuggingPort` exists end to end
  (`SessionConfiguration` → HelloAck → `CefSettings.remote_debugging_port`) but is 0 in the
  shipping app. `callDevToolsMethod` runs `ExecuteDevToolsMethod` on the host's own DevTools
  session and forwards no events. A tab that is unselected, in a minimized or covered window,
  or out of the view hierarchy gets `WasHidden(true)`, and hidden widgets drop input; the escape
  hatch is `WebView.rendersOffscreen`. Pages live in `BrowserTabHost.models` until closed, but
  `TabStore+KeepAlive` never keeps browser views in the hierarchy.
- **Server relay for streams.** `_RUNNER_PATH_RE` lets only terminal and browser attach paths
  through the runner tunnel; CDP is deliberately not routable through the server today.

## 3. Architecture

```
 Runner machine                                              Mac app (owner)
 ┌───────────────────────────────────────────────┐          ┌──────────────────────────────┐
 │ harness (any) ── MCP tools ──> server policy   │          │ Swift BrowserDevToolsStore   │
 │      ▲                           │             │  owner-  │  tab directory, agent state, │
 │      │ chrome_devtools__*        ▼             │  only    │  banner / badge, Stop, Take  │
 │ RunnerMcpManager ── stdio ──> npx chrome-      │  relay   │  over                        │
 │                              devtools-mcp      │ <──────> │        │ OWL                 │
 │                                  │ ws (token)  │ (server) │ Omnigent Web Host (CEF)      │
 │                                  ▼             │          │  remote_debugging_port       │
 │ runner: ScopedCdpProxy (virtual browser) ──────┼── ws ──> │  127.0.0.1 (same Mac)        │
 │   policy, target emulation, activity           │ loopback └──────────────────────────────┘
 │      │ directory          │ upstream ws        │
 │      ▼                    ▼                    │
 │ BrowserHostManager ── omnigent-browser-host (CEF, per profile, loopback CDP port)        │
 └───────────────────────────────────────────────┘
```

### 3.1 Launch and injection

- Server: new feature `agent_browser_devtools` (default off until phase 2 ships). When on,
  `/v1/sessions/{id}/agent/contents` adds `X-Omnigent-Browser-Devtools: 1` for agents whose
  `tool_groups.browser` is true and whose session carries no `omnigent.browser_agent_tools`
  label (the web/Electron pane keeps its relay tools).
- Runner: `spec_resolver` (it has the session id) applies `with_browser_devtools(spec,
  endpoint)` when the header is present and the proxy listener runs. That adds
  `MCPServerConfig(name="chrome_devtools", transport="stdio", command=<runner python>,
  args=["-I", "-m", "omnigent.runner.browser_devtools.mcp_launcher", "--ws-endpoint", <url>])`
  and turns `tool_groups.browser` off so the five `browser_*` tools and their prompt line
  disappear.
- The launcher finds Node.js the way Omnigent finds other CLIs (`PATH`, Homebrew,
  `~/.local/bin`, mise shims, nvm, or `OMNIGENT_NODE_PATH`), installs the pinned release once
  into `<data dir>/browser/chrome-devtools-mcp/1.12.0` with the machine's own npm
  configuration (`~/.npmrc`, `npm_config_registry`), and then execs
  `node .../chrome-devtools-mcp.js --wsEndpoint <url> --no-usage-statistics
  --no-performance-crux`. Env: `CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1`,
  `CHROME_DEVTOOLS_MCP_NO_CONFIG_DISCOVERY=1`, `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1`. No
  registry is hardcoded: a runner behind a mirror configures npm as usual.
- When Node is missing or too old, or npm cannot fetch the package, the launcher serves a
  one-tool MCP server (`chrome_devtools__browser_unavailable`) whose description and result
  say what to install or configure, so the agent tells the user instead of silently having no
  browser.
- The token is `<session_id>.<hmac>` where the HMAC uses a per-runner-process secret. It is a
  pure function of (secret, port, session id), so the spec loader can compute it in its worker
  thread, and it makes the server config differ per session: `RunnerMcpManager` never shares
  one chrome-devtools-mcp process between sessions.
- Tool timeout 180 s (performance traces), which also bounds the first launch's install.
- `chrome-devtools-mcp` reconnects lazily when its browser disconnects
  (`BrowserManager.ensureBrowser` checks `browser.connected`). Switching browsers is therefore a
  proxy-side close; the next tool call reconnects to the new target.

### 3.2 The scoped CDP proxy (`omnigent/runner/browser_devtools/`)

One `ScopedCdpSession` per accepted agent WebSocket, over a fresh upstream browser WebSocket.
The proxy turns on discovery upstream for itself and keeps the full target map, but the client
sees only *allowed* targets: page targets the directory lists for the session, plus popups whose
`openerId` is allowed.

Browser-level (no `sessionId`):

| Method | Handling |
|---|---|
| `Target.setDiscoverTargets` | Emulated: `targetCreated` for each allowed page, then later created/changed/destroyed for allowed pages only |
| `Target.setAutoAttach` (flatten) | Emulated: the proxy calls `Target.attachToTarget {flatten: true}` for each allowed page now and for each page that becomes allowed later; Chrome's `attachedToTarget` reaches the client. Non-flatten is refused |
| `Target.getTargets`, `getTargetInfo`, `attachToTarget`, `detachFromTarget`, `activateTarget` | Filtered or refused for non-allowed ids; `activateTarget` is swallowed (no focus stealing) |
| `Target.createTarget` | `directory.create_tab(url)`; the new target id joins the allowed set, is announced/attached, and returned |
| `Target.closeTarget` | `directory.close_tab(target)` for allowed ids |
| `Target.getBrowserContexts`, `Browser.getVersion` | Forwarded |
| `Browser.getWindowForTarget/getWindowBounds/setWindowBounds/setContentsSize` | Emulated virtual windows; `setContentsSize` becomes `Emulation.setDeviceMetricsOverride` on the page, so an agent resize never moves the user's window |
| Everything else (contexts, `Browser.close`, permissions, downloads, `attachToBrowserTarget`, `exposeDevToolsProtocol`, `Tethering.*`, ...) | Refused |

Session-level (`sessionId` of an allowed page or one of its children):

- Child sessions (OOPIFs, workers) are learned from `Target.attachedToTarget` events inside an
  allowed session; unknown session ids are refused.
- Refused everywhere: profile-wide data and control (`Network.getAllCookies`,
  `Network.clearBrowserCookies/Cache`, `Network.deleteCookies/setCookie(s)`, `Storage.*Cookies`,
  `Storage.clearData*`, `Browser.*` except the emulated window calls, `Extensions.*`, `PWA.*`,
  `WebAuthn.*`, `Autofill.*`, `Page.setDownloadBehavior`).
- `Page.bringToFront` is swallowed; `Page.close` on a root page becomes `directory.close_tab`.
- Actuating methods are refused while the tab's owner is `user` (section 5).
- After each attach the proxy sends `Emulation.setFocusEmulationEnabled {enabled: true}` so
  focus, keyboard and `document.hasFocus()` behave with the window in the background.

Activity: an actuating method marks the tab `active` in the directory (debounced, at most one
report per tab per 2 s); 10 s without one reports `idle`; a closed client releases its tabs.

Directory refresh: on connect, on a timer (host 1 s, app 2 s), and before an actuating method
when the cached owner is older than 1 s.

### 3.3 Browser backends

`BrowserBackend = (upstream browser WebSocket URL, TabDirectory)`.

`TabDirectory` (Python protocol): `list_tabs() -> [ScopedTab(tab_id, target_id, url, title,
owner)]`, `create_tab(url)`, `close_tab(target_id)`, `report_activity(target_id, state)`.

- **Remote** (`HostTabDirectory`): `BrowserHostManager.ensure_host(profile)`; upstream from
  `GET http://127.0.0.1:<cdp_port>/json/version`; `tabs.list {session_id}`,
  `tabs.create {created_by: agent}`, `tabs.close`; owner from the tab record; activity through a
  new host op `tabs.agent_state {tab_id, state}` that the host reflects in the tab record and in
  `control_state.agent` so viewers see the same badge.
- **Local** (`AppTabDirectory`): a new owner-only relay, `POST /v1/sessions/{id}/browser/devtools_request`,
  published as `browser.devtools_request`. Unlike `action_request`, only a renderer that
  advertises the CDP capability may claim it, the claimant must hold `LEVEL_OWNER`, and the
  event is also published on the owner's session-list updates stream so the app answers for
  sessions it has not opened. Ops: `attach` (returns `{port, browser_id, owner}` or a reason),
  `tabs.list`, `tabs.create`, `tabs.close`, `tabs.agent_state`. The proxy accepts the local
  endpoint only when `GET http://127.0.0.1:<port>/json/version` on the runner returns the same
  `browser_id`: that proves the runner shares the Mac. Otherwise the session needs the phase 4
  tunnel.

### 3.4 Local app pieces

- **Web Host endpoint:** the app never opens CEF's `remoteDebuggingPort`. That port is
  unauthenticated, and any local process could read every signed-in site's cookies through
  it (the reason Chrome refuses remote debugging on the default profile). Instead:
  - `HostProcess` spawns the Web Host with `posix_spawn` and `POSIX_SPAWN_CLOEXEC_DEFAULT`,
    handing it two pipes as fds 3 and 4 and nothing else; `--owl-devtools-pipe` makes the host
    add `--remote-debugging-pipe` (CEF 156 honours it; a VM probe answered
    `Browser.getVersion`, `Target.getTargets` and `Target.createTarget` with no TCP listener).
  - Nothing listens until an owner's `attach`, and only while the server advertises
    `agent_browser_devtools` and the setting is on. Then `DevToolsGate` opens a loopback
    WebSocket whose path carries the session's 256-bit secret
    (`/devtools/browser/<secret>`); it refuses other paths, any `Origin` (web pages) and
    other `Host` names before upgrading, and closes after 60 s without a connection. The
    secret travels only in the relay answer and is never logged; endpoints print without it.
  - `DevToolsMultiplexer` shares the one pipe: it renumbers ids, gives each CDP session to the
    connection that attached it, runs discovery itself, shows each connection only its
    session's tabs and their popups, refuses attaching to anything else, and refuses the same
    profile-wide methods as the proxy. A leaked secret is worth one session's tabs.
  - The runner connects in `app_backend`, so a runner on another machine (nothing answers, or
    another listener refuses the secret) falls through to the next browser.
  - Each page's target id comes from `Target.getTargetInfo` over the page's own DevTools
    session (`BrowserAgentInput.devToolsTargetID()`); listings and new tabs set the
    session's scope at the gate.
- **Swift:** `BrowserActionStore` routes `devtools.<op>` actions to `BrowserDevToolsPerformer`
  (app target), which answers from `BrowserTabHost+DevTools`: the session group's browser tabs
  in every window (pages the session never showed are built), background agent tabs in the
  session's `TabStore` in the user's default profile, closing, and the agent state. The Rust
  core turns `browser.devtools_request` into those actions without a transcript row.
- **Holding a tab:** `BrowserTabModel.setAgentControl` sets the page's
  `holdForAgent` (`WebView.rendersOffscreen`) while any agent state is set, so CEF never hides
  it; releasing returns the page to what its view last reported. Pages live in
  `BrowserTabHost.models` whatever the window or session.
- **Pinned while held:** a session whose browser tab an agent holds (any agent state) stays
  in the window's live sessions (`SessionTabGroups.agentHeldSessions`), so its stream, which
  carries the directory requests, stays open until the agent lets go.
- **Chromium for agents:** an agent's new tab is pinned to Chromium
  (`BrowserController.pinnedEngine`, saved with the tab) under a WebKit preference too; the
  user choosing an engine for that tab unpins it.

## 4. Choosing and switching the browser

- Label `omnigent.browser_target`: `auto` (absent), `local`, `remote`. Writing `local` is
  owner-only.
- `auto`, evaluated when an agent connection arrives:
  1. Local usable = the owner's app claims `attach`, the setting is on, the session is not
     shared, and the same-machine check passes (phase 4 drops the last condition).
  2. Remote usable = the runner advertises `remote_browser` and the host starts.
  3. Only one usable → use it. Both usable and the run is unattended (a scheduled automation,
     or no subscriber on the session stream) → remote. Both usable otherwise → local when the
     runner is on the same Mac (the user is there and the agent gets the user's logins), else
     ask once.
  4. Asking is an elicitation, "Which browser should the agent use? This Mac (your logins) /
     Agent's machine (works while your Mac sleeps)"; the answer is written to the label.
- The session header shows a chip, *Browser: This Mac* / *Browser: Agent machine*, with a menu
  to switch. A switch closes the session's proxy connections; tabs stay open in the old
  browser; the next tool call lands in the new one. Cookies and logins do not carry over, and
  the menu, the tool result and the prompt say so.
- Agent-facing builtins: `browser_switch(target, reason)` (switching to `local` needs the
  owner's approval through an elicitation) and `browser_request_human(reason, page?)`
  (section 5). Both are Omnigent tools, not part of chrome-devtools-mcp.
- Framework prompt (`omnigent/runtime/prompt.py`, `BROWSER_DEVTOOLS_INSTRUCTION`): which
  browser is in use, that new pages open as tabs the user sees, never to ask for credentials in
  chat, to call `browser_request_human` for logins, 2FA, CAPTCHAs and payments, and to wait
  and re-snapshot after a refusal that says the user is in control.

## 5. Indicator, Stop, Take over, hand-off

- States per tab, same for both browsers: `idle` (agent attached, nothing recent), `active`
  (agent acted in the last 10 s), `user` (user holds it, agent input refused), `needs_you`
  (a `browser_request_human` is pending for this tab).
- Tab strip: a small agent glyph (SF Symbol `cursorarrow.rays`, accent tint while `active`,
  secondary while `idle`; `person.fill` for `user`; the existing `.needsYou` mark for
  `needs_you`) on the tab icon, with an accessibility label ("Agent is controlling this tab").
  The session's tab list and overview use the same `TabItemState` field.
- Page: a thin banner above the page (`BrowserTabContentView`, modelled on
  `RemoteBrowserControlStrip`): "Agent is browsing · Take over · Stop"; "You're in control ·
  Hand back"; "Agent needs you: <reason> · Done · I can't". The page gets a 2 pt accent border
  while `active`.
- **Take over** sets the owner to `user`: the proxy refuses actuating methods with
  `user_in_control`. chrome-devtools-mcp turns such refusals into its own retry and timeout
  errors, so the proxy also shows the tab's agent pages an open `alert` dialog
  (`Page.javascriptDialogOpening`) whose text is the reason. chrome-devtools-mcp refuses input,
  snapshot and script tools on a page with an open dialog and quotes it, and a click already
  under way ends on it. The agent's answer to that dialog never reaches the page and it opens
  again 0.5 s later; a refused actuating call reopens it at once. **Hand back** returns the owner
  to `agent` and sends `Page.javascriptDialogClosed`. **Stop** does the same as Take over
  and also interrupts the session's current turn. It closes nothing: the agent's tabs stay open.
- Remote tabs: the host already has owner `agent`/`user` with a 60 s grace; `tabs.agent_state`
  adds `idle`/`active`, and the Swift remote tab reads both into the same `TabItemState`.
- Hand-off: `browser_request_human` creates an elicitation with `browser_handoff {backend,
  tab_id, url, title}` and blocks until the user finishes (`completed`), declines or it times
  out. Locally the user acts in the tab directly; remotely the first click takes control.

## 6. Background operation (local)

The agent's tab may be unselected, in another session's tab set, in a minimized or non-key
window, or the app may be inactive. Requirements and mechanism:

| Concern | Mechanism |
|---|---|
| Renderer hidden → timers, rAF and painting throttle; hidden widgets drop input | Held tabs set `WebView.rendersOffscreen`, so the host never calls `WasHidden(true)` for them |
| View leaves the hierarchy on a session switch | The page lives in `BrowserTabHost.models`; `rendersOffscreen` keeps CEF visible without a window |
| Input | Only CDP `Input.*` through the remote debugging session; no AppKit events, no key window needed |
| Focus | Proxy enables focus emulation on every agent page session |
| Screenshots and snapshots | `Page.captureScreenshot` and accessibility/DOM domains; no window capture |
| App Nap | Chromium sets `NSAppSleepDisabled` in the host (Web Host design doc); verified again in the app test |
| Session stream closed by keep-alive | `ConnectionStore` pins conversations with held tabs |
| Existing `browser_*` relay | Already renders its agent pages offscreen; covered by the same background test |

## 7. Cross-machine transport (phase 4)

- Remote runner or sandbox using the local Mac browser: a new tunnel path
  `/v1/sessions/{sid}/resources/browser-devtools/attach` (owner-only, added to
  `_RUNNER_PATH_RE` deliberately) carries the proxy's upstream WebSocket. The app opens it
  (the app dials out; the Mac needs no inbound port) and splices it to its loopback CDP port.
  The proxy still runs on the runner, so scoping and policy do not move.
- A runner using a host on another machine is out of scope: hosts are local to their runner by
  design (remote design §3).
- File and `chrome:` URLs are refused for the local browser when the agent is on another
  machine.

## 8. Security

- Local browser: owner-only relay claims, owner-only `local` label, never `auto`-selected for a
  shared session, refused for viewers. The app double-checks the owner before answering.
- Local CDP: no raw DevTools port in the app (see 3.4). The server refuses
  `browser.devtools_request` while `agent_browser_devtools` is off, so no request ever
  reaches the app then. The remote host's loopback port stays unauthenticated to local
  processes on the agent's machine, as remote design §10 records.
- Proxy tokens: per-runner-process secret, HMAC per session, loopback only, compared in
  constant time.
- Profile-wide CDP methods are refused (section 3.2) for both browsers.
- Control is visible: badge and banner on every agent tab, Stop always one click away.

## 9. Phases

| Phase | Scope | Exit criteria |
|---|---|---|
| **1 Shared core** | Proxy, policy, endpoint tokens, runner listener, `chrome_devtools` injection, feature flag and header, prompt, `browser_*` hiding, remote `HostTabDirectory`, pi-native relay gap | Unit tests for scoping and policy; real chrome-devtools-mcp drives the real browser-host through the proxy on a VM (list, new page, navigate, snapshot, click, fill, evaluate, console, network, screenshot); another session's tab stays invisible |
| **2 (a) Local, same Mac** | Web Host port setting and target ids, owner-only `devtools_request` relay, Rust event and claim, `BrowserDevToolsStore`, background operation, indicator (badge, banner, Stop, Take over) | Agent drives an app tab with the window in the background and the tab unselected; badge and banner visible; Take over refuses agent input; native tests and a Mac UI flow |
| **3 (b) Remote polish** | `tabs.agent_state` host op, `control_state.agent`, remote tab badge, host tabs in the session tab list | Same badge states on remote tabs |
| **4 (c) Selection** | `omnigent.browser_target`, auto policy and ask-once elicitation, chip and menu, `browser_switch` | Switching moves the next tool call; owner-only `local` |
| **5 (d) Tunnel** | Owner-only CDP tunnel path through the server to the app | A sandbox runner drives the local Mac browser |
| **6 (e) Hand-off and hardening** | `browser_request_human`, `needs_you` | Login hand-off round trip on both browsers |

### Status (2026-11-20)

- **Local endpoint:** the pipe and the gated loopback endpoint (3.4).
- **Done:** phase 1; phase 2; from phase 3, the host's
  `tabs.agent_state` op and `agent_state` in tab records and resources; from phase 4,
  `omnigent.browser_target` with `auto` preferring the remote browser for scheduled runs, and
  closing a connection the label no longer allows.
- **Remote tabs in the app** show the agent's activity too: `tabs.agent_state` sets
  `control_state.agent` (`active`/`idle`), which the host broadcasts with reason
  `agent_activity`, and the Rust core and FFI carry to the tab's badge.
- **Take over reaches the agent** within one directory refresh (2 s for the app, 1 s for a
  host) as the user-control dialog (section 5).
- **Choosing the browser:** the server checks `omnigent.browser_target` writes (known values;
  `local` only from the owner of an unshared session; empty deletes the label, so it reads as
  `auto`). The core and FFI read and write it directly (`browser_target`,
  `set_browser_target`).
- **Not started:** the chip and menu in the apps, `browser_switch`, the ask-once elicitation,
  phase 5 and phase 6.

## 10. Test plan

- Unit (Python, `tests/runner/`): proxy against a scripted fake browser (allowed and foreign
  targets, discovery and auto-attach emulation, child sessions, popups by opener, create and
  close through the directory, refusal tables, user-control gating, virtual windows, activity
  debounce); token derivation; spec injection and `browser_*` hiding; feature header; prompt.
- Integration (`tests/integration/`, explicit target, needs Node and
  `OMNIGENT_TEST_BROWSER_HOST_BIN`): the real chrome-devtools-mcp over stdio JSON-RPC through
  the proxy against the real host, with a stub encoder; runs on a VM.
- Server (`tests/server/`): `devtools_request` claim rules (capability, owner, shared session).
- Native: `BrowserDevToolsStore` with fakes; `TabAdapter` badge states; banner actions; a Mac
  UI flow that opens an agent tab in a background session and checks the badge and banner.

## 11. Risks and open questions

- **Puppeteer without tab targets.** The proxy attaches to pages directly instead of exposing
  Chrome's `tab` targets. Puppeteer supports both shapes; the integration test pins it.
- **Emulated resize** changes the layout viewport, not the OSR view size; screenshots follow the
  emulated size. Acceptable; remote viewers keep the host's size.
- **Shared DevTools state.** The agent's remote-debugging session is separate from the Web
  Host's own DevTools session, so `Runtime.disable` by the agent cannot break the host bridges.
- **Mirror lag.** The pin must stay older than the cooldown; bump deliberately.
- **Node on runners.** Managed sandboxes need Node 20.19+; the tool list shows the failure.
- The earlier open questions (local setting default, what Stop closes, unattended runs) are
  answered in 1.1.

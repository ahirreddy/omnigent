# Client wire contract for the Rust core

This is the server contract that `omnigent-protocol` and `omnigent-core` implement. It
merges three sources:

- NativeLab's Swift client: `apps/apple/Reference/NativeLab/Sources/NativeLabCore/`;
- the web/ios auth code: `web/ios/Omnigent/`;
- the current server source in this repo, which is the **ground truth**. Where a doc and the
  source disagree, the source wins. Disagreements are listed under "Divergences" at the end.

Checked against this worktree on 2026-10-31:

- `omnigent/server/schemas.py`: `ServerStreamEvent` at line 5118, `SessionListItem`,
  `SessionResponse`, `SessionEventInput`, `ElicitationResult`, `UpdateSessionRequest`,
  `SessionCreateRequest`;
- `omnigent/entities/conversation.py`: `ItemData` at line 791;
- the routes in `omnigent/server/routes/sessions/`, plus `routes/auth.py`, `routes/accounts_auth.py`,
  `routes/hosts.py` and `app.py`.

Real captures from a local server are in `client-core/fixtures/{sse,items,sessions}/recorded-*`.

Paths below are relative to the API root:

- local: `http://127.0.0.1:<port>`;
- hosted and Databricks: the API mount, for example `/api/2.0/omnigent`. Databricks also sends
  `X-Databricks-Org-Id` and never puts `o=` on API requests.

Auth applies to every REST, SSE and WS request in one of three forms:
- `Authorization: Bearer <token>` (accounts, OIDC native token);
- a cookie (`__Host-ap_session` on https, `ap_session` on http);
- none (loopback single-user, or a trusted proxy).

## 1. Discovery and auth

| Method | Path | Request | Response | Notes |
|---|---|---|---|---|
| GET | `/.well-known/omnigent.json` | none | `{manifest_version, server_version, min_desktop_version, server_name, ui:{server_picker}, auth:{mode: "oidc"\|"accounts"\|"header"\|"custom"\|"none", session_cookie, native_redirect_uris}}` | Redirects are not followed. A 404, HTML, malformed JSON or a non-numeric version means the baseline (pre-manifest) server. Fixture: `sessions/recorded-well-known-manifest.json`; `fixtures/manifest/` belongs to the scaffold. |
| GET | `/v1/info` | none (unauthenticated at the Omnigent layer) | `ServerInfoResponse`: `accounts_enabled`, `single_user`, `login_url?`, `needs_setup?`, `server_version`, `durable_initial_input`, `sharing_mode`, ... | NativeLab derives the mode from this. Databricks org → proxy; `accounts_enabled` → accounts; `login_url == "/auth/login"` → oidc; `single_user` on loopback with no `login_url` → local; anything else → proxy. Fixture: `sessions/recorded-v1-info.json`. |
| GET | `/v1/me` | auth | `{user_id, is_admin?}` | In header mode it can return 200 with `user_id: null`, so a 200 does not prove the caller is authenticated. A 401 carries `login_url`. |
| POST | `/auth/login` (accounts) | `{"username","password"}` | `{token, expires_in, user:{id}}` and Set-Cookie | No refresh. Re-authenticate when the token expires. |
| POST | `/auth/cli-login` (OIDC ticket) | **JSON `{code_challenge, code_challenge_method:"S256"}` is now required** | `{ticket, login_url: "/auth/login?ticket=<t>", user_code?}` | An empty body returns 200 `{ticket:"upgrade-required", login_url:"/auth/cli-upgrade", error}`. See divergence D1. |
| GET | `/auth/cli-poll?ticket=<t>` | header `X-Omnigent-Code-Verifier: <verifier>` (or `?code_verifier=`) | 202 pending; 200 `{token, user_id, expires_in}`; 410 expired or unknown; 400 missing or invalid verifier; 403 verifier mismatch | |
| GET | `/auth/login?native_redirect_uri=…&native_state=…&code_challenge=…&code_challenge_method=S256` | browser | redirects to the native callback with `code` | This is the web/ios (OIDC native) flow. |
| POST | `/auth/native-token` | form `code, redirect_uri, code_verifier` | `{token, user_id, expires_in, refresh_token?}` | |
| POST | `/oauth/token` | form `grant_type=refresh_token, refresh_token` | `{access_token, refresh_token, expires_in}` | 400 `invalid_grant` → grant rejected; 400 `expired_token` → grant expired. |
| POST | `/oauth/revoke` | form `refresh_token` | 200 | |

Databricks endpoints (WP7) are the workspace's own OIDC endpoints, not Omnigent routes:

- `{issuer}/.well-known/openid-configuration`;
- `/oidc/v1/authorize`;
- `{issuer}/v1/token`;
- `{workspace}/auth/session/create?next_url=…`, which turns a bearer into the `DBAUTH` cookie for page loads.

The workspace probe sends `HEAD /` and expects the response header `server: databricks`. The web/ios
checklist rows give the exact parameters.

## 2. Sessions REST

| Method | Path | Query / body | Response | Used by |
|---|---|---|---|---|
| GET | `/v1/sessions` | `limit` (1–1000, default 20), `after`, `before`, `order=asc\|desc` (default desc), `sort_by=created_at\|updated_at` (default created_at), `search_query`, `search_scope=all\|title\|content`, `include_archived` (default false), `kind=default\|sub_agent\|any`, `project`, `pinned`, `visibility=all\|mine\|shared\|archived`, `agent_id`, `agent_name` | `SessionList` `{object:"list", data:[SessionListItem], first_id, last_id, has_more}`. A 400 with `error.code == "stale_cursor"` means restart without a cursor. | NativeLab sends `limit, after, order=desc, sort_by=updated_at, include_archived=true, kind=any`. Fixture: `sessions/recorded-sessions-list.json`. |
| GET | `/v1/sessions/{id}` | `include_items` (default true), `include_liveness`, `include_usage`, `include_live_status`, `refresh_state` | `SessionResponse` (the snapshot) | Hydration and reconnect. NativeLab uses `include_items=false` and pages `/items`. Fixtures: `items/recorded-session-snapshot-after-turn.json`, `sessions/recorded-session-get-no-items.json`. |
| GET | `/v1/sessions/{id}/items` | `limit` (1–1000, default 100), `after`, `before`, `order` (default **asc**) | `{object, data:[item], first_id, last_id, has_more}`. The cursor is an opaque item id; `stale_cursor` 400 as above. | NativeLab pages `order=desc` from the newest item. Fixtures: `items/recorded-items-page-{1,2,3}.json`, `recorded-items-desc-page-1.json`. |
| PATCH | `/v1/sessions/{id}` | `UpdateSessionRequest` (extra fields **forbidden**): `runner_id, title, labels, reasoning_effort, model_override, collaboration_mode, permission_mode, approval_mode, cost_control_mode_override, subagent_routing_override, share_workspace_files, external_session_id, terminal_launch_args, archived, project_id, delete_worktree, silent` | `SessionResponse` | `model_override` and `reasoning_effort` accept the clear aliases `default\|off\|reset`. For `cost_control_mode_override` and `subagent_routing_override`, an explicit `null` clears. Unknown keys are a 422. Fixture: `sessions/recorded-session-bind-runner.json`. |
| POST | `/v1/sessions/{id}/switch-agent` | `{agent_id}` | `SessionResponse` | Hidden from openapi (`include_in_schema=False`). |
| DELETE | `/v1/sessions/{id}` | `delete_branch?` | `{id, object:"conversation.deleted", deleted:true}` | Fixture: `sessions/recorded-session-delete.json`. |
| POST | `/v1/sessions` | JSON `SessionCreateRequest`: `agent_id` (required), `host_type` (for example `"external"`), `host_id`, `workspace`, `title?`, `labels?`, `model_override?`, `reasoning_effort?`, `initial_input?` (when `/v1/info.durable_initial_input`), `initial_items?`, `harness_override?`, `terminal_launch_args?`, ... A `multipart/form-data` body with `metadata` + `bundle` is the bundled-create path. | JSON → 201 `SessionResponse`; multipart → 201 `{session_id, agent_id, agent_name}` | NativeLab sends `{agent_id, host_id, host_type:"external", workspace, title?, model_override?, labels:{"omnigent.ui":"terminal","omnigent.wrapper":<w>}}`. Fixture: `sessions/recorded-session-create-bundle.json`. |
| GET | `/v1/agents` | `after` | `{data:[{id,name,harness,builtin?}], has_more, last_id}` | creation |
| GET | `/v1/hosts` | none | `{hosts:[{host_id, name, status, sandbox_provider?, configured_harnesses:{harness: bool\|string}}]}` | creation |
| GET | `/v1/hosts/{host_id}/filesystem` | `after` (path cursor) | `{data:[{name, path, type:"directory"\|"file"}], has_more}` | creation (workspace picker) |
| GET | `/v1/hosts/{host_id}/harnesses/{harness}/model-options` | none | `{models:[{id, model?, hidden?, displayName?, isDefault?, supportedReasoningEfforts?:[{reasoningEffort}]}]}` | configuration |
| GET | `/v1/sessions/{id}/resources/environments/{env}/changes` | none | `{entries:[{path, status}]}` | Fetched on `session.changed_files.invalidated`. |
| POST | `/v1/sessions/{id}/resources/files` | multipart part `file` (escape the filename) | 201 `{id, metadata:{filename, bytes}}` (older servers: `{id, name, session_id}`) | Uploads. The file id is then referenced by an `input_image`/`input_file` part. |
| GET | `/v1/sessions/{id}/resources/files/{file_id}/content` | none | bytes with `Content-Type`/`Content-Length` | The client enforces a 10 MiB cap. |

### 2.1 `POST /v1/sessions/{id}/events` (hidden from openapi)

- **Body:** `SessionEventInput` `{type, data:{}, model_override?, tools?, created_by?}`, or an array of
  up to 100 of them. A batch is processed in order and is not atomic.
- **Status:** 202, with one acknowledgement per event.
- **Client-relevant `type`s:**
  - `message`: `data: {role:"user", content:[{type:"input_text", text} | {type:"input_image"|"input_file", file_id, filename}]}`.
  - `interrupt`: `data: {}`. Cancels the active task. The stream then emits `response.incomplete`
    (reason `user_interrupt`), `session.interrupted` and `session.status: idle`.
  - `stop_session`: owner only. Stops the live process; the next message relaunches it.
  - `retry_session`: reconnects or relaunches the runner and retries a failed saved startup input.
  - `approval`: resolves an elicitation in-band. NativeLab uses the dedicated resolve route below instead.
- **Acknowledgement shapes:**
  - `{queued:true, item_id}`: persisted. The same id arrives later in `session.input.consumed`.
  - `{queued:true, pending_id}`: a native-terminal session (or a pending startup input). The bubble is
    dropped when `session.input.consumed.data.cleared_pending_id` matches.
  - `{queued:false}`: a control event.
  - `{queued:false, denied:true, reason}`: policy denial. The input is **not** persisted, but the
    denial explanation is.
  - `{queued:false, recovered, recovery}`: `retry_session`.
  - `{queued:false, elicitation_id}`.
- **Errors:** 400 for an unknown type or bad data, 404 for an unknown session, 422 for a validation failure.
- **No idempotency key:** if the POST fails ambiguously, the client must not retry it automatically.
  The ledger (WP4) records it as *uncertain*. Fixture: `sessions/recorded-post-event-message.json`.

### 2.2 Elicitations (hidden from openapi)

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/v1/sessions/{session_id}/elicitations/{elicitation_id}/resolve` | `ElicitationResult` `{action:"accept"\|"decline"\|"cancel", content?: {key: str\|int\|float\|bool\|[str]\|null}, _meta?}` | 202 `{queued:false}` |
| GET | `/v1/sessions/{session_id}/elicitations/{elicitation_id}` | none | status, message, phase, policy name, content preview. **No full schema**: rebuild full cards from `SessionResponse.pending_elicitations` or the SSE request. |

- **Permission:** resolving needs *edit* permission, not owner.
- **Child sessions:** a card mirrored from a child must post to
  `params.target_session_id`, not the stream's own session.
- **`content`:** it is flat. Question ids map directly to answers, with lists for multi-select.
  Permission cards use `allow_all_edits`, `remember`, `feedback` and `execpolicy_amendment`.

### 2.3 Not on the server

`GET`/`DELETE /v1/notifications/devices/{installation_id}`, which NativeLab's push registration
calls, comes from NativeLab's own server patch (`mobile_notifications.py`). The current server has no
such route; see divergence D7.

## 3. SSE: `GET /v1/sessions/{id}/stream`

- **Query and headers:** `Accept: text/event-stream`. The `idle` query flag is presence-only.
- **Framing:** each frame is `event: <type>` plus `data: <json>`, with `data.type == event`.
  - There are **no `id:` lines** and no comment frames.
  - `sequence_number` is sometimes `null` and sometimes a number. Do not rely on it.
  - Intentional close sends `data: [DONE]`. Shutdown or subscriber overflow ends **without** `[DONE]`;
    reconnect in that case.
  - A turn going idle does not close the stream (see `sse/recorded-turn-text-tool-completion.jsonl`).
- **On connect, before the live tail:** a ready `session.heartbeat`; an in-flight assistant-text
  snapshot if a turn is streaming; resource and presence snapshots (`session.changed_files.invalidated`,
  `session.presence`).
- **Keepalive:** an idle `session.heartbeat` every 15 s (`_SESSION_STREAM_HEARTBEAT_INTERVAL_S`).
- **Errors:** 401 or 403 stop reconnecting and ask for sign-in again; 404 is retried a bounded
  number of times; any other EOF or error is reconnected.

### 3.1 Event types (the `ServerStreamEvent` union, 56 types)

Every event type the server can emit is listed below. ✓ means NativeLab handles the type.

**Session (`session.*`), flat shape `{type, conversation_id, …}` unless noted:**

| type | fields | NativeLab |
|---|---|---|
| `session.status` | `status: idle\|launching\|running\|waiting\|failed`, `response_id?`, `error?: ErrorDetail`, `background_task_count?`, `background_tasks?`, `blocked_on?` (flat, **not** under `data`) | ✓ |
| `session.usage` | `context_tokens?, context_window?, total_cost_usd?, usage_by_model?` | ✓ |
| `session.model` | `model` | ✓ |
| `session.title` | `title` | **missing** |
| `session.reasoning_effort` | `reasoning_effort?` | ✓ |
| `session.collaboration_mode` | `mode` | ✓ |
| `session.permission_mode` | `permission_mode` | **missing** |
| `session.codex_approval_mode` | `approval_mode: ask-for-approval\|approve-for-me\|full-access\|read-only` | **missing** |
| `session.agent_changed` | `agent_id, agent_name` | ✓ |
| `session.todos` | `todos: [obj]` | ✓ |
| `session.terminal_pending` | `pending: bool` | ✓ |
| `session.sandbox_status` | `stage: provisioning\|action_required\|cloning\|starting\|connecting\|ready\|failed`, `error?, provider?, details?` | ✓ |
| `session.mcp_startup` | `servers: {name: McpServerStartup}` | ✓ |
| `session.model_options` | `conversation_id` (refetch) | ✓ |
| `session.input.consumed` | **nested** `data: {item_id, type, data, created_by?, cleared_pending_id?}` | ✓ |
| `session.interrupted` | **nested** `data: {requested_at, response_id?}` | ✓ |
| `session.created` | `child_session_id, agent_id?, parent_session_id?` (on the parent's stream) | ✓ |
| `session.superseded` | `target_conversation_id, reason?: "clear"` | ✓ |
| `session.btw_sidechat` | `question, answer, truncated?` | **missing** |
| `session.presence` | `viewers: [PresenceViewer]` | ✓ |
| `session.resource.created` | `resource: obj` (no conversation_id) | ✓ |
| `session.resource.deleted` | `resource_id, resource_type, session_id` | ✓ |
| `session.child_session.updated` | `child_session_id, child: obj` | ✓ |
| `session.changed_files.invalidated` | `session_id, environment_id?` | ✓ |
| `session.terminal.activity` | `session_id, terminal_id` | ✓ |
| `session.heartbeat` | `server_time?` | ✓ (stream ready) |

**Response (`response.*`):**

| type | fields | NativeLab |
|---|---|---|
| `response.created` / `queued` / `in_progress` / `completed` / `cancelled` / `incomplete` | `response: ResponseObject {id, status, model, created_at, output[], usage?, error?, incomplete_details?, …}` | ✓ (all of them, including `queued`) |
| `response.failed` | `source?: llm\|execution\|tool\|harness`, `response: ResponseObject\|FailedResponseObject` | ✓ |
| `response.output_text.delta` | `delta, message_id?, index?, final?` | ✓ |
| `response.function_call_output.delta` | `call_id, delta` | ✓ |
| `response.reasoning.started` | none | ✓ |
| `response.reasoning_text.delta`, `response.reasoning_summary_text.delta` | `delta` | ✓ |
| `response.output_item.done` | `item: {id, type, …ItemData}`, the persisted item | ✓ |
| `response.output_file.done` | `file_id, filename?, content_type?` | ✓ |
| `response.heartbeat` | `server_time?, last_event_seq?` | ✓ |
| `response.elicitation_request` | `elicitation_id, method?: "elicitation/create", params: {mode?: form\|url, message, requestedSchema?, url?, phase?, policy_name?, content_preview?, target_session_id?, …extra allowed}` | ✓ |
| `response.elicitation_resolved` | `elicitation_id, action?: accept\|decline\|cancel, reason?: "unanswered"` | ✓ |
| `response.policy_denied` | `conversation_id, reason?, phase?` | ✓ |
| `response.retry` | `source: llm\|tool, tool_name?, attempt, max_attempts, delay_seconds, error:{code,message,detail?}` | ✓ |
| `response.error` | `source, tool_name?, error:{code,message,detail?}` | ✓ |
| `response.compaction.in_progress` / `completed` / `failed` | `started_at?` / `total_tokens?, summary?, summary_model?, compacted_messages?` / none | ✓ |
| `response.client_task.cancel` | `task_id, call_id?` | ✓ |

**Other families:**

| type | fields | NativeLab |
|---|---|---|
| `browser.action_request` | `action_id, action, args` | ✓ (displayed only) |
| `ui.open_file` | `path` | **missing** |
| `turn.started` / `turn.completed` / `turn.cancelled` | `session_id` | **missing** |
| `turn.failed` | `session_id, error?` | **missing** |

Every event model uses `extra="ignore"`, so the Rust models must also tolerate unknown fields. An
unknown `type` decodes to `Unknown{type, raw}`, shown as a bounded, sanitised placeholder. Never
drop an unknown type silently.

### 3.2 Item types (`ItemData`, the `type` of `response.output_item.done.item` and of `/items` rows)

| type | fields (inside the item, alongside `id`, `type`, `status?`, `response_id?`) |
|---|---|
| `message` | `role: user\|assistant`, `content: [part]`, `agent?`, `is_meta?`, `user_authored?`, `subagent_return_id?`, `interrupted?`, `stream_message_id?`, `phase?`, `startup_options?` |
| `function_call` | `agent, name, arguments` (a JSON string), `call_id, namespace?` |
| `function_call_output` | `call_id, output` (a string, often JSON: `{stdout, stderr, exit_code, timed_out, shell, cwd}`), `subagent_return_id?` |
| `error` | `source: llm\|execution\|tool\|harness, code, message, level?: error\|info, title?, cause?, remediation?` |
| `reasoning` | `agent, summary:[{…}], content?, encrypted_content?` (never display `encrypted_content`) |
| `compaction` | `summary, last_item_id, model?, token_count, compacted_messages?, window_id?` |
| `native_tool` | `item: obj`, an inner OpenAI item: `web_search_call`, `file_search_call`, `code_interpreter_call`, `computer_call`, `image_generation_call`, `mcp_call`, `mcp_list_tools` |
| `resource_event` | `event_type, resource_id, resource_type, resource?` |
| `routing_decision` | `model, applied, rationale, agent?, harness?, scope?: session\|turn\|child_session\|native_subagent, decision_id?, raw_model?, attempted_override?, router_source?, task_description?` |
| `slash_command` | `agent` (serialised as `model`), `kind: skill\|command, name, arguments, output?, startup_options?` |
| `terminal_command` | `kind: input\|output, input?, stdout?, stderr?` |

The context-free types are `compaction`, `error`, `resource_event`, `routing_decision`,
`slash_command` and `terminal_command`. The UI may show them, but they are not model context.

Content parts the clients see are `input_text`, `input_image`, `input_file`, `input_audio`,
`output_text`, `refusal`, `reasoning_text`, `thinking`, `redacted_thinking` and `text`.
`thinking` and `redacted_thinking` are private and are never shown as content cards.

## 4. WebSocket: `/v1/sessions/updates`

- **Handshake:** authenticated. With permissions enabled, an unauthenticated socket is closed with 1008.
- **Client → server:** `{"type":"watch","session_ids":[...]}`. Send it on connect and whenever the visible
  set changes. Each message **replaces** the previous watch set. The server de-dupes the ids and caps
  the set at **500** (`_SESSION_UPDATES_MAX_WATCHED`); ids beyond the cap are silently dropped server-side
  (NativeLab throws `watchLimitExceeded` client-side instead). Unknown frames are ignored.
- **Server → client:**

  | message | when |
  |---|---|
  | `{"type":"snapshot","items":[SessionListItem]}` | once per `watch` |
  | `{"type":"changed","items":[SessionListItem]}` | a changed watched row, or a session discovered by push |
  | `{"type":"removed","ids":[...]}` | a watched id lost access or was deleted |
  | `{"type":"hosts_changed"}` | host inventory changed |
  | `{"type":"heartbeat"}` | after 30 s without sending |

  - `changed` rows are pushed for sessions *not* in the watch set when they are created or shared
    elsewhere. NativeLab adds them to its watch set.
  - On `hosts_changed`, refetch `/v1/hosts`.
  - Watched rows are re-read every 4 s (`_SESSION_UPDATES_RESCAN_INTERVAL_S`).
  - Rows are full `SessionListItem` dumps with explicit nulls, so a null clears the field.
  - Frames may carry trace-context keys; ignore them.
- **Client watchdog:** reconnect after 70 s of silence. On reconnect, re-send `watch` and refetch the
  list, because discovery pushes are not replayed. Fixture: `sessions/recorded-updates-ws.jsonl`.

## 5. Resume and reconciliation rules

These rules come from `omnigent/server/API.md` ("Reconnect Contract", around line 1466),
`designs/ios-native/server-contracts.md` ("Streaming, recovery, and state transitions") and
the NativeLab reducer.

1. **No replay.** The stream is a live tail; there is no durable cursor and `Last-Event-ID` is ignored.
   The recorded reconnect (`sse/recorded-reconnect-last-event-id-turn2.jsonl`) confirms this.
   Each subscriber's queue holds 1024 events; on overflow the server closes the stream without `[DONE]`.
2. **Subscribe first, then the snapshot.** Open `GET …/stream`, buffer its events, and then
   `GET /v1/sessions/{id}?include_items=false` plus the newest `/items` page. The web client starts
   with 20 items and pages back (up to 8 windows) to cover two user prompts. Apply the snapshot, then
   replay the buffered events.
3. **Dedupe by item id** at every commit boundary. `response.output_item.done` with an id already in
   history replaces it and is never appended twice. Live text deltas are keyed by
   `message_id` and `index`. A delta whose `index` was already applied is a no-op. A committed
   message (`stream_message_id` / `response_id`) retires its live preview.
4. **Inputs settle on `session.input.consumed`.**
   - Match `data.item_id` against the POST acknowledgement's `item_id`, or `data.cleared_pending_id`
     against its `pending_id`.
   - Shell-mode `terminal_command` input settles when its input item is persisted, and no consumed
     event is sent for it.
   - Never auto-retry an uncertain POST.
5. **Interruption.**
   - `session.interrupted` (with `data.response_id`) seals only the matching live turn.
   - Late deltas for a sealed turn are rejected.
   - The next turn streams normally.
   - A wrapper turn's `response.completed` (`output: []`) must not seal native text that is still
     streaming under a different id.
6. **Status.**
   - `session.status` carries `launching`, `running`, `waiting`, `idle` or `failed`. List and
     snapshot status omits `launching`.
   - `waiting` (background work) is not idle.
   - Host and runner liveness (`runner_online`, `host_online`, `host_resumable`) is separate from
     turn status.
   - A completed turn missed while disconnected must clear the spinner on reconcile.
   - A turn that is still running must get its streaming state back.
7. **Decisions.**
   - Merge pending elicitations by id from `SessionResponse.pending_elicitations` and from the stream.
   - `response.elicitation_resolved` with the **exact** id retires a card. Tool output never resolves one.
   - On reconnect, retire cards that are absent from the new snapshot, but do not overwrite newer live state.
   - Never re-approve automatically.
8. **Generation tokens.** All async work (hydration, page loads, uploads) carries the session id and a
   stream generation. Results from a session the user has switched away from are dropped.
9. **Backoff and watchdogs.**
   - SSE: retry a healthy-stream drop immediately; retry failed opens with jittered backoff from
     250 ms to 5 s (`web/src/lib/reconnectBackoff.ts`); treat 45 s without a byte as a stall.
     Server heartbeats arrive every 15 s.
   - WS: 70 s silence watchdog.
   - On 401 or 403, stop and ask for sign-in again.
10. **Foreground.** On returning to the foreground, reopen the stream and run steps 2–7 again, even
    if the previous connection ended cleanly with `[DONE]`.

## 6. Divergences: NativeLab vs the current server

NativeLab was built against an older server (`designs/ios-native/server-contracts.md` cites base
`76281b94`). The Rust port follows the current server.

| # | Area | NativeLab | Current server | Action for Rust |
|---|---|---|---|---|
| D1 | OIDC ticket login | `POST /auth/cli-login` with an **empty body**. Polls with no verifier. Rejects any `login_url` other than `/auth/login?ticket=…`. | An empty body returns the `upgrade-required` sentinel (`login_url: "/auth/cli-upgrade"`). PKCE `code_challenge` (S256) is required. Poll needs `X-Omnigent-Code-Verifier`; mismatch → 403, missing → 400. | Send the PKCE challenge, send the verifier header, and map the upgrade sentinel and 400/403 to typed errors. The NativeLab `HostedServerAuthenticationTests` browser-login cases (inline payloads) encode the old flow, so port them with the PKCE request. web/ios `OidcLoginManagerTests::testTicketAndPollSendMatchingPKCEProof` already matches the current server. |
| D2 | Event types missing from NativeLab | Not handled: `session.title`, `session.permission_mode`, `session.codex_approval_mode`, `session.btw_sidechat`, `ui.open_file`, `turn.started`, `turn.completed`, `turn.failed`, `turn.cancelled`. | All 9 are in `ServerStreamEvent`. | Model all 56. At minimum, `session.title` updates the title, `permission_mode` and `codex_approval_mode` update config state, `btw_sidechat` is an activity row, `turn.*` are lifecycle edges, and `ui.open_file` is an ignorable UI hint. None of them may become a transcript item or end a response. |
| D3 | Types NativeLab handles that the server lacks | `response.started`, `session.skills` | Not in the union. Skills come from snapshot overlays (`refresh_state`). | Decode them as `Unknown` or as aliases. Do not rely on them. |
| D4 | Stream termination | Treats `[DONE]` as the only stop. Every other end reconnects. | `[DONE]` comes only on intentional close; idle sessions keep the stream open. API.md's example ("terminates with `[DONE]`") overstates this. | Keep the NativeLab behaviour; the recorded capture confirms it. |
| D5 | Reconnect backoff and watchdogs | `0.25 s × 2^(n-1)`, capped at **8 s**, no jitter. No byte-stall watchdog (60 s request timeout only). No WS silence watchdog. | (client policy) | Follow the plan: jittered 250 ms–5 s, a 45 s SSE stall watchdog and a 70 s WS watchdog. Port the NativeLab tests for their semantics, not their timing constants. |
| D6 | `hosts_changed` WS frame | Falls into `default: break` and is ignored. | Sent on host inventory change. | Emit `HostsChanged` and refetch `/v1/hosts`. |
| D7 | Push device registration | `GET`/`DELETE /v1/notifications/devices/{installation_id}` | No such route; it came from NativeLab's unported server patch. | Gate it on capability. Treat 404 as unsupported, not as an error to retry. The plan requires the app to work without it. |
| D8 | API.md drift (doc only) | n/a | API.md shows `session.input.consumed` as `{queued_item_id, type, data, position}` and `session.status` as `data:{status}`. The source and the recording use `{item_id, type, data, created_by?, cleared_pending_id?}` and a flat `status`. NativeLab matches the source. | Follow `schemas.py`. |
| D9 | Error item shape | Tests use both a nested `data.{source,code,message}` and a top-level `code/message/source`. | `ErrorData` is flat inside the item. | Accept both on decode. |
| D10 | Session list vs snapshot fields | `SessionWire` reads `model_override`, `llm_model`, `model_options`, `last_task_error`, `host_resumable`, `pending_elicitations` and `cost_control_mode_override` from any session payload. | `SessionListItem` (list and WS) has only `pending_elicitations_count` and omits those fields; they exist only on `SessionResponse`. | Two models. A list row must never clear snapshot-only fields; NativeLab's `presentFields` tracks this, so keep that rule. |
| D11 | `session.status` values | Handles `running`, `waiting` and `launching` as busy. | Same, plus `failed` with `error: ErrorDetail{code,message,title?,cause?,remediation?,undelivered?}`. | Surface `failed` and its `error`. |
| D12 | Upload response | Accepts both `{id, metadata:{filename,bytes}}` and `{id,name,session_id}`. | Current route returns 201. Fixtures cover both shapes. | Keep both. |
| D13 | Elicitation resolve `action` | Posts `accept` and `decline`. | Also accepts `cancel`. `elicitation_resolved` may carry `reason:"unanswered"`, or neither field, which means it was answered in the native terminal. | Model `cancel` and the three resolved variants. |

`ServerStreamEvent` events not observed in the recording (all mock-driven):
- `response.created`, `queued`, `failed`, `heartbeat`;
- `response.reasoning*`;
- `response.elicitation_*`;
- `session.interrupted`;
- streaming tool-argument deltas.

Their shapes come from `schemas.py` and the extracted NativeLab fixtures in `fixtures/events/`.

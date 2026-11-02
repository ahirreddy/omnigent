# Phone supervision

Roadmap items 16 and 18 (Phase 3), and review 3's top-10 item 10: answer what needs you from the
phone. The first slice ships in the apps without server changes. The server half, APNs push,
is designed here and tracked in [follow-ups.md](follow-ups.md).

## What ships now (no server changes)

### Actionable notifications

| Request | Category | Actions |
|---|---|---|
| Approval | `omnigent.approval` | Approve, Deny |
| Approval that takes feedback | `omnigent.approval.reply` | Approve, Deny, Reply (declines with the feedback) |
| Choice, or a form with one free-text field | `omnigent.question` | Reply (an option by its text or number, or the field's answer) |
| Anything else, turn finished or failed | `omnigent.update` | none; a tap opens the session |

- **Approve** requires device authentication: `UNNotificationActionOptions.authenticationRequired`
  on iOS, and `LAContext` device-owner authentication on the Mac before acting.
- **Re-check before acting.** Every action re-reads the session's pending decisions through the
  core (`ClientCore.pendingDecisions`, a fresh `GET /v1/sessions/{id}`). It acts only when the
  notified decision is still pending and still a kind that offers the button. The core then
  re-reads once more before it posts to the resolve route. A stale request posts "This request
  was already answered." (`SupervisionActionRouter`, `OmnigentStores/Supervision`.)
- **No sensitive text.** The title is the session's title, truncated to 80 characters. The body is
  a fixed line per kind ("Waiting for your approval"). The request's text, tool input, commands
  and paths are never shown. The payload carries identifiers only (`SupervisionPayload`).
- **Grouping.** One notification per request (`<server>/d/<decision>`), threaded per session
  (`thread-id` = server and session). A sub-agent's request is read through its parent, which
  mirrors it, so it groups under and opens the parent (`ChildNotificationRollup` does the same for
  the core's notifications).
- **Per-type toggles.** On iPhone and iPad: Settings › Notifications (server menu ›
  Notifications…) has Approval requests, Questions, Finished turns and Failed turns. The Mac keeps
  its existing Notifications tab (A turn finishes, An agent asks for input, A runner goes offline).

Sources of notifications, without push:

1. **Live.** The core's `AttentionNotification` events (`NotificationsStore`) while the app runs.
   For an input request the app reads the session's pending decisions and posts one actionable
   notification per request. On the Mac, `DesktopAttention` posts them through
   `DesktopNotificationCenter`, which keeps its policy (toggles, viewed-session suppression).
2. **On backgrounding (iOS).** The scene sweeps every session that needs you, then keeps its
   streams for about 25 s of background time so new requests still notify live.
3. **`BGAppRefreshTask` (iOS).** `ai.omnigent.attention-refresh`, requested every 15 minutes at
   the earliest. It refreshes the session list through the core and sweeps it. iOS decides when it
   actually runs, so this is a safety net, not real time.

A ledger of notified requests (512 entries, in `UserDefaults`) makes each request notify once,
whichever source saw it first.

Actions on iOS run in the background. They use the scene's connection when there is one;
otherwise they open a connection with the saved sign-in. While the device is locked the
Keychain can't be read, so an action taken from the Lock Screen without unlocking posts "Not
signed in to this server. Open Omnigent to answer." Approve always unlocks first.

### QR pairing

- **Mac:** Settings › Phone shows a QR code for a connected or recent server. It warns when the
  server is loopback, which the phone can't reach.
- **iPhone:** the Connect screen has Scan Pairing Code (`DataScannerViewController`, with a paste
  field where the camera can't scan). The system Camera also works, because the code uses the
  `omnigent:` scheme the app registers.
- **Code format:** `omnigent:pair?v=1&server=<percent-encoded server URL>`. It has no `//`
  authority, so the `omnigent://` deep-link parsers reject it instead of reading `pair` as a
  host. Unknown query items are ignored, so v1 readers accept a later token.
- **Never auto-trusted:** the URL goes through the core's `ServerURLValidator`. The phone shows
  the host prominently and the full URL, and connects only after the user taps Connect. The code
  carries no credential, so the phone signs in normally.

## Server half: APNs push (not implemented)

Without push the phone can't hear about a request while the app is suspended, except at
refresh-task times. The starting point is Ankit's NativeLab prototype on
`ankit-db/omnigent` `feature/mobile-native-core`: `omnigent/server/mobile_notifications.py`,
`omnigent/server/mobile_apns.py` and `omnigent/server/routes/mobile_notifications.py`. The client
core already has the matching request builders (`omnigent_core::notifications::push`), where a 404
means "unsupported".

### Device registration

From the prototype, mounted under `/v1/notifications`:

- `GET capabilities` returns `available`, `environment` (`sandbox` or `production`), `topic` and
  `server_url`.
- `PUT devices` takes `installation_id`, `device_token` (hex), `environment`, `topic`, and
  `session_ids` (at most 500). It returns 204 and replaces the device's session list. Identity
  comes from authentication; the body never carries a user id.
- `DELETE devices/{installation_id}` returns 204.
- Errors: 401 means sign in again, 403 an unowned session, 409 an environment or topic mismatch,
  or a token held by another account, and 503 not configured.
- Registrations expire after 30 days. The app re-registers on launch and when the session list
  changes, and unregisters on sign-out. If the server can't be reached, the app says so instead
  of claiming the device was revoked.

Change from the prototype: the app should subscribe to "every session I own" rather than an
explicit list, so new sessions notify without re-registering. Keep the explicit list as an
opt-in filter.

### Payload

```json
{
  "aps": {
    "alert": { "title": "Omnigent", "body": "Waiting for your approval" },
    "sound": "default",
    "thread-id": "<opaque hash of server, account and session>",
    "category": "omnigent.approval",
    "mutable-content": 1
  },
  "omnigent": {
    "version": 1,
    "server_url": "https://host/api/2.0/omnigent",
    "session_id": "<session carrying the request>",
    "open_session_id": "<parent, for a sub-agent>",
    "decision_id": "<elicitation id>",
    "kind": "approval"
  }
}
```

- This is the shape `SupervisionPayload` already reads, so taps and actions work unchanged.
- Titles only, and on the wire not even the session title: the alert text is generic. A
  Notification Service Extension (`mutable-content`) can swap in the session title from the
  app's own cached list (App Group) without a network call.
- Never sent: prompts, messages, tool names or input, commands, paths, file names, diffs, or
  user and workspace ids in the clear. The prototype sent `user_id` and `workspace_id`; replace
  them with an opaque account hash for multi-account routing.
- `decision_id` is an opaque server id and authorizes nothing by itself. Every answer goes through
  the authenticated resolve route after the fresh re-check above.
- The category is presentation only. The app decides which actions apply after its re-check. When
  the server can't tell a question's shape, it sends `omnigent.update`.
- `apns-collapse-id` is the decision id for requests, and session plus "turn" for turn ends.
  `apns-push-type: alert`, priority 10 for requests and 5 for turn ends, and `apns-expiration`
  about one hour.

### Delivery

As in the prototype: an observer on the session event stream feeds an outbox. A request
notifies at once. A turn end waits a 10 s settle, cancelled by new activity, and is suppressed
while requests are outstanding or background tasks run. The outbox dedupes on account,
installation and event, retries on 429 and 5xx with backoff (at most 5 attempts), and deletes the
device on 410, `BadDeviceToken` or `DeviceTokenNotForTopic`. Provider auth is an ES256 JWT,
cached for 50 minutes and reset on `ExpiredProviderToken`.

The prototype's outbox is a single-process SQLite file, and its event queue drops events on
overflow. For replicas, move both to the server database and the shared event bus, and treat a
dropped event as a missed notification to reconcile on the next status change.

### Security model

- **Registration:** an authenticated, owned session only. Ownership is checked at registration
  and again at delivery, walking parents for sub-agents. Archived or no-longer-owned sessions
  never notify.
- **Isolation:** every row is keyed by server, workspace and user. A token registered by another
  account is a 409, never silently moved.
- **The push channel never carries authority.** Actions use the device's own credential on the
  normal API. Approve requires device authentication. The client checks that the payload's
  server matches the connection it acts on.
- **Credentials at rest:** the APNs key stays outside the repository and is readable only by the
  server account. Response bodies and device tokens are never logged.
- **Lock Screen:** the hidden-previews placeholder is "Omnigent request". Deny and Reply don't
  require unlocking today, but they need the Keychain credential, which a locked device can't
  read. Revisit if the credential's accessibility changes.

### Pairing tokens (v2)

When the server's auth mode supports it (accounts or OIDC, not a single-user local server):

1. The signed-in Mac mints a short-lived, single-use device-link token (about 5 minutes) with
   `POST /v1/auth/device-links`. It is added to the code as `&token=`.
2. The phone redeems it with `POST /v1/auth/device-links/{token}/redeem` for its own credential,
   bound to the phone and revocable separately. The Mac shows "iPhone connected".
3. Until then, the code is the URL alone and the phone signs in normally.

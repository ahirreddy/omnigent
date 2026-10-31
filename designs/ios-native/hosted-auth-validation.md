# Native hosted authentication: core transport validation

Implemented 2026-10-31 in the shared checkout, without commits or resets. This
record covers the core networking work for audit item 2. App presentation,
Keychain, startup services, and live provider streaming belong to the coordinator
and other workers. No real credential was put in source, test data, or this file.

## Public integration surface

```swift
let endpoint = try ServerEndpoint(baseURL: apiURL)
let auth = try ServerAuthenticationClient(baseURL: endpoint.baseURL)
let discovery = try await auth.discover()
// mode: .localSingleUser, .accounts, .oidc, or .proxy; also needsSetup

let credential = try await auth.login(username: username, password: password)
// token, userID, expiresAt; store token only in Keychain

let ticket = try await auth.beginBrowserLogin()
// Present ticket.loginURL in a browser. Never log the URL: it contains a ticket.
let pendingOrCredential = try await auth.pollBrowserLogin(ticket)
// nil while pending; browserLoginExpired means start a new ticket.

let client = try LocalServerSessionClient(
  baseURL: endpoint.baseURL,
  bearerToken: credential.token,
  expectedUserID: credential.userID)
let identity = try await client.connect()
// identity.scope is the canonical API URL + confirmed user ID.
await client.disconnect()
```

The old `LocalServerSessionClient(baseURL:session:)` call remains valid. An HTTP
literal loopback root selects explicit local single-user mode and must pass both
`single_user=true` discovery and `/v1/me` identity `local`. Credentials cannot be
sent over that HTTP mode. HTTPS selects hosted mode, requires a bearer token,
and rejects an anonymous local-single-user fallback. Hosted identity must be
nonempty and match the optional saved identity. Once confirmed, a client's
identity is pinned across reconnects; create a new client to change accounts.

API roots retain their mount: `https://example.invalid/api/2.0/omnigent` maps
`/v1/sessions` to `/api/2.0/omnigent/v1/sessions`. REST, SSE, WSS, uploads,
attachments, configuration, creation, and notifications use this mapping and
bearer header. The UI URL is not inferred. No trusted identity header is injected.
Databricks HTTPS workspace subdomains of `databricks.com` and
`azuredatabricks.net` additionally accept exactly one literal numeric `?o=`
selector. The canonical identity URL retains it; requests strip it from the
endpoint query and carry `X-Databricks-Org-Id` on REST, SSE, WSS, uploads and
notifications. Other hosts, duplicate selectors, encoded selectors and other
base-URL query items are rejected. No arbitrary additional headers are supported.
Org-scoped password/browser login is explicitly rejected: these connections use
proxy bearer authentication, without reusing standalone OIDC callback routing.

Credential-free discovery can fail with 401 on a protected proxy. The UI should
still permit explicit bearer entry; a discovery failure never means local mode.
Current discovery decoding requires `single_user` and `accounts_enabled` rather
than treating an unknown response as a compatible server.

## Source contracts and protections

- `omnigent/server/routes/accounts_auth.py`, `POST /auth/login`: request
  `username/password`; response `token`, `expires_in`, `user.id`.
- `omnigent/server/routes/auth.py`, `POST /auth/cli-login`: `ticket` and logical
  `/auth/login?ticket=...`; `GET /auth/cli-poll`: 202 pending, 200 with `token`,
  `expires_in`, **`user_id`**, or 410 expired. Ticket TTL is 300 seconds. The
  browser URL must exactly match the returned ticket's logical login route;
  it is mapped into the same deployment mount. Polling rejects a ticket from
  another API root. The client uses ticket creation time as a conservative
  expiry baseline because the token can predate polling.
- `omnigent/server/app.py`, `/v1/info` and `/v1/me`: explicit mode discovery and
  confirmed identity. `accounts_enabled=false` alone does not grant access.
- `omnigent/server/routes/sessions/routes_core.py`, `/sessions/updates`: missing
  authentication rejects the WebSocket handshake. HTTP 401, 403 and redirects
  stop reconnect loops; SSE 401 and auth challenges invalidate the connection
  and publish an actionable sign-in error. Certificate failures also stop retries.
- All API redirects are refused, including same-origin redirects. Cookie stores,
  credential stores, ambient headers, and response caches are disabled. TLS
  server-trust challenges use platform certificate/hostname validation; no custom
  trust acceptance or pinning bypass is installed.
- Disconnect drops cached summaries and cancels streams. Generation checks reject
  late request results. Uploaded attachments include the authenticated user;
  hosted attachments from another account or without identity are rejected.
  Attachment references resolve only inside the current API mount and session.
- Notification identity includes the canonical mounted API URL, user and workspace.
  Keychain and app draft/cache persistence are coordinator-owned. Logout has no
  server-side bearer revocation contract: delete the stored token and discard the
  client. Ordinary account/OIDC session tokens have no refresh endpoint here.

## Executed checks

From the repository root:

```sh
xcrun swift test --package-path web/ios/NativeLab \
  --scratch-path /tmp/omnigent-core-hosted-auth-build
```

Result: **278 tests, 3 skipped, 0 failures**, including **18 new hosted-auth
tests**. The skips were the two opt-in local fixture/stream checks and the
coordinator's opt-in real Keychain CRUD check. Log:
`/tmp/omnigent-hosted-auth-tests.log`. The focused transport regression run also
passed (123 tests, two local opt-in skips, zero failures) before the additional
stream failure cases were added. SwiftPM needed execution outside the sandbox
because its manifest sandbox could not nest inside this session's sandbox.

`xcrun swift-format lint --strict --configuration web/ios/.swift-format` passed
for the twelve modified/new Swift files owned by this work.

The tests use synthetic URLProtocol responses, plus direct delegate checks.
They verify request routing, bearer/cookie behavior, accounts/OIDC wire formats,
cross-origin rejection, identity mismatches, mounted attachment/upload handling,
notification scope, cancellation races, and auth failures stopping streams.
They do **not** establish a successful hosted login, actual certificate exchange,
browser completion, WebSocket proxy support, or live model streaming.

### Databricks org-routing follow-up

The new `DatabricksRoutingTests` contains eight synthetic tests for strict host
and selector validation, endpoint-query preservation, REST/SSE/WSS headers,
org-isolated identity/notification/draft scopes, actual upload/preview request
routing, cross-org attachment rejection, both notification transports, and
explicit rejection of standalone browser/password auth for org-scoped proxies.

```sh
xcrun swift test --package-path web/ios/NativeLab \
  --scratch-path /tmp/omnigent-core-hosted-auth-build \
  --filter 'DatabricksRoutingTests|HostedServerAuthenticationTests|LocalAttachmentTests|NativeNotificationTests|LocalServerSessionClientTests|LocalServerUploadTests'
```

Result: **86 tests, 2 opt-in local live tests skipped, 0 failures**. This includes
all eight routing tests and 19 hosted-auth tests (the additional hosted test
checks public `isConnected` before/after a 401). Log:
`/tmp/omnigent-databricks-routing-tests.log`. Strict Swift formatting lint passed
for the six Swift files changed by this routing follow-up. No real hosted token
or provider traffic was used in these tests.

## Remaining integration evidence

1. The coordinator's attempt to resolve existing hosted CLI credentials failed
   before an HTTP request. Authenticated hosted `/v1/info`, `/v1/me`, inventory,
   SSE and WSS need fresh login and deployment validation. A subsequent safe
   metadata check confirmed a recorded org selector for the configured server.
   Core now implements the existing CLI `X-Databricks-Org-Id` contract through
   the bounded `?o=` API above. This has not established live hosted success.
2. Standalone accounts and browser OIDC need an actual deployment/device run.
   OIDC tickets are in-memory on the server, so ingress affinity and server
   restarts remain deployment constraints. Mounted OIDC callback routing needs
   validation; core does not guess another auth origin or follow API redirects.
3. Mounted hosted push is not end-to-end supported yet: server-side
   `APNsConfiguration.load` currently permits only a canonical origin for
   `OMNIGENT_APNS_SERVER_URL`. Its configured scope must be aligned with the
   client's mounted API root before relying on push registration or tap routing.
   This core worker did not edit the notification server.

## Files changed by the core worker

Under `web/ios/NativeLab/Sources/NativeLabCore/`:

- `ServerConnection.swift` (new)
- `ServerAuthenticationClient.swift` (new)
- `LocalServerSessionClient.swift`
- `LocalServerStreaming.swift`
- `LocalServerAttachments.swift`
- `LocalServerUploads.swift`
- `LocalServerNotifications.swift`
- `LocalServerSessionCreation.swift`
- `NativeNotifications.swift`

Under `web/ios/NativeLab/Tests/NativeLabCoreTests/`:

- `HostedServerAuthenticationTests.swift` (new)
- `DatabricksRoutingTests.swift` (new)
- `LocalServerSessionClientTests.swift`
- `NativeNotificationTests.swift`

And this validation file. No App, Keychain, README, Python, startup, or live
streaming-proof files were edited by this worker.

# Background push setup

Push is off by default. The server worker observes session events independently
of connected phones and sends APNs alerts for selected, owned sessions. Device
registration and delivery both validate ownership. Payloads contain routing IDs
and generic text, not prompts, tool arguments or conversation contents.

## Development activation

1. Use an Apple Developer team and app identifier with Push Notifications
   enabled. The default bundle identifier is `ai.omnigent.ios.lab`; choose an
   identifier owned by your team and keep the app and server topic identical.
2. Obtain an APNs signing key (`.p8`) and its key ID and team ID. Keep the key
   outside the repository and readable only by the server account.
3. Install HTTP/2 support into the server environment:

   ```sh
   uv pip install --python .venv/bin/python 'httpx[http2]>=0.27,<1'
   ```

4. Build with the opt-in settings from `web/ios/NativeLab`:

   ```sh
   xcodebuild -project NativeLab.xcodeproj -scheme NativeLab \
     -xcconfig Config/PushDevelopment.xcconfig \
     -destination 'generic/platform=iOS' \
     DEVELOPMENT_TEAM=YOUR_TEAM_ID PRODUCT_BUNDLE_IDENTIFIER=YOUR_APP_ID build
   ```

   Alternatively apply that xcconfig to an Xcode development configuration and
   run on a supported development device/simulator. It adds `aps-environment`
   with `development` and the app's push environment with `sandbox`.
   Production distribution requires `production` for both settings and a matching
   provisioning profile. The ordinary project build does not require APNs signing.

5. For the existing loopback-only Simulator connection, set these variables in
   your server terminal, replacing the placeholders, then start the launcher:

   ```sh
   export OMNIGENT_APNS_ENABLED=1
   export OMNIGENT_APNS_TEAM_ID=YOUR_TEAM_ID
   export OMNIGENT_APNS_KEY_ID=YOUR_KEY_ID
   export OMNIGENT_APNS_KEY_PATH=/absolute/private/path/AuthKey.p8
   export OMNIGENT_APNS_TOPIC=YOUR_APP_ID
   bash web/ios/NativeLab/bin/local-server.sh
   ```

   The launcher fixes the push origin to `http://127.0.0.1:6767`, selects sandbox
   APNs by default, enables the explicit local-development gate, and keeps the
   private notification database in `.native-lab-server/data/notifications.sqlite`.
   It continues to bind only to loopback. Restart an existing development server
   deliberately before applying configuration; do not run a second listener on its port.

6. Reconnect the app. In **Settings > Notifications**, choose **Sessions for alerts**,
   select owned sessions, and allow notifications. Successful device registration
   must be reported before treating alerts as enabled.
7. Background the app, then let a selected session request input or complete a
   turn. Completion waits ten seconds to avoid brief idle transitions. Tap the
   delivered alert and verify the correct session opens. Do not use a simulated
   notification as proof that Apple delivery works.

## Deployment boundary

The outbox is a private SQLite file owned by one API process. For non-local
deployment, configure `OMNIGENT_APNS_ENABLED=1`, `OMNIGENT_APNS_SINGLE_PROCESS=1`,
`OMNIGENT_APNS_TEAM_ID`, `OMNIGENT_APNS_KEY_ID`, `OMNIGENT_APNS_KEY_PATH`,
`OMNIGENT_APNS_TOPIC`, `OMNIGENT_APNS_ENVIRONMENT=sandbox|production`,
`OMNIGENT_APNS_STORE_PATH` and a canonical HTTPS `OMNIGENT_APNS_SERVER_URL`.
Leave `OMNIGENT_APNS_LOCAL_DEVELOPMENT` unset. Multi-worker/replica deployment
needs a shared event source and outbox before enabling this worker.

The native app still has a loopback single-user connection boundary. A physical
phone cannot reach the Mac through `127.0.0.1`; authenticated phone networking is
separate remaining work. The HTTPS registration transport is implemented for
that integration. Do not expose the no-login development server on the network.

Registrations expire after 30 days unless renewed. Switching connections tries
to unregister the old account; an unreachable server is reported rather than
claiming revocation. Uncertain notification transport failures retry with bounded
backoff and a stable APNs collapse identifier. Delivery across a process crash
can repeat an accepted push; the app also deduplicates by scoped event ID.

## Verified without Apple credentials

Core tests cover versioned routing, account/workspace isolation, deduplication
and HTTP contracts. Server tests use a synthetic ES256 key, a mock Apple endpoint
and a temporary outbox to check permissions, token rotation, retries,
ownership revocation, settled completion and delivery without an iOS connection.
Real Apple delivery and physical-phone notification taps remain unverified.

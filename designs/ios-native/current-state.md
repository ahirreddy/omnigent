Implementation update (2026-10-17): this file preserves the discovery baseline.
The native preview now supports local messaging, SSE/WebSocket updates and a
persistent Inbox tab. See [live interaction validation](live-interaction-validation.md)
for current implementation, tests and remaining device limitations. A genuine
model reply through the native composer and SSE passed on the 17 Pro simulator
after correcting the local host's provider-login environment.

Existing-session harness/model/reasoning controls are now implemented in the
native composers and session list. See the [configuration journey audit](configuration-journey-audit.md)
and [configuration validation](configuration-validation.md) for current checks,
streamed-change handling and physical-device limits.

The proposed mobile app should focus on finding active sessions, reading and
continuing conversations, answering decisions, and starting a basic session on
an existing host. Native components can own that experience. Basic attachments
and read-only artifacts are useful additions to size separately; terminals,
editors, scheduling and administration can be deferred.

This is the discovery team's recommendation, not an approved first-release
feature list. The user-confirmed direction is **mostly native components, narrow
web-rendering exceptions where justified, and selective mobile functionality**.

Discovery baseline: `76281b94`, 2026-10-16. Three specialists inspected the
native shell, mobile product, and server contracts; the coordinator checked
build/test/release readiness and reconciled their findings. Source discovery
and the web baseline are complete. iOS/device and deployed-auth observations
remain outstanding.

| Report | Use it for |
| --- | --- |
| [Mobile scope](mobile-scope.md) | Current routes/features, keep/simplify/defer/omit recommendations, five detailed core journeys, acceptance criteria and browser handoffs. |
| [Native shell](native-shell.md) | Every current native surface and bridge operation, lifecycle/state ownership, reusable Swift pieces and migration risks. |
| [Server contracts](server-contracts.md) | Auth/deployment matrix, endpoint and event behavior, streaming reconciliation, permissions, optional files/terminal and compatibility gaps. |
| [Validation baseline](validation-baseline.md) | Executed checks, current coverage/automation, release setup and exact next validation commands. |

**What the current app actually owns**

Swift provides setup, saved servers, limited navigation, local notifications,
badge updates, and floating server/Chat-Terminal controls. A server-served React
app inside `WKWebView` owns identity, session lists, conversations, input,
approvals, state reconciliation, and most network behavior. The bridge largely
coordinates presentation and OS integrations; it is not a reusable native API
client.

Useful foundations already exist: setup UI, server persistence, URL/deep-link
utilities, system browser presentation, assets, and notification APIs. Each
needs integration work rather than blanket replacement. The main new work is a
native connection/client state layer and native workflows built on it.

**Recommended scope**

| Area | Recommendation |
| --- | --- |
| Connect and account | Native saved-server management, explicit connection/login state, supported mode-specific auth and server-scoped credentials/data. Browser-assisted auth is compatible with this design. |
| Sessions and Attention | Native paginated list/search/status, an approvals-focused Attention view, and direct navigation to sessions/children. Preserve read-only permissions and existing organization labels; simplify management controls. |
| Conversation | Native text/Markdown/code, tool details and errors, history paging, live updates, drafts, sending and interruption. Handle unknown content explicitly; never hide a pending decision as unsupported generic content. |
| Decisions | Native binary approval, command/plan review, structured single/multiple-choice questions and custom answers. Preserve real child-session targets and authoritative resolved state. Defer persistent-policy editing. |
| Basic creation | Choose an already configured agent/host/workspace, create a session, then submit the first message. Defer host provisioning, custom bundles and advanced launch configuration. |
| Small extensions | Size photo/document import, attachment downloads, linked read-only text/image/PDF artifacts, and child/progress summaries separately. These do not require a full file editor or terminal. |
| Deferred surfaces | Terminal/shell creation, IDE-style browsing/editing/diffs, interactive HTML/notebooks, comments, scheduling, sharing administration and server administration. Preserve destination context for browser handoff. |
| OS behavior | Native navigation/input/accessibility, deliberate foreground notifications, deep links, foreground reconciliation and saved-state migration. APNs and guaranteed background sends require separate scope. |

No core journey identified by this audit requires embedding the whole web app.
A small terminal or HTML renderer remains a possible later exception, with
native ownership of navigation, identity and lifecycle. Deferral should follow
mobile value and tested harness behavior; a vendor "native" CLI session is not
automatically terminal-only.

**Findings that determine implementation order**

1. **Connection support is deployment-specific.** Accounts has a bearer login
   contract; OIDC has a browser ticket/poll flow. Workspace/proxy authentication
   and API/WebSocket routing rely on an external host integration. Saved UI URLs
   are not necessarily API bases. Device grant is optional and does not cover
   the full native bootstrap. Prove the selected deployment contracts first.
2. **Conversation recovery is the main client-state problem.** SSE has limited
   in-flight replay, not a durable event cursor. History, pending input, decisions,
   transient text and status must be merged across initial load, switching,
   disconnect and resume. A native reducer with test fixtures is more useful
   than beginning with a large collection of screens.
3. **Existing APIs cover most core actions, with documentation gaps.** Essential
   message and decision routes are omitted from OpenAPI. Explicit wire models
   and contract fixtures are needed even if some client code is generated.
   There is no evidence that the entire backend needs a rewrite.
4. **Sending has uncertain outcomes.** Create and first-send are separate calls;
   inspected routes have no identified idempotency contract. Preserve the created
   session and reconcile ambiguous submissions before offering retry. Local
   drafts/queues differ from server-accepted pending input and need clear UI.
5. **Attention and approvals need full semantics.** Current attention discovery
   scans session pages and fetches relevant snapshots; filtering only the loaded
   page misses requests. Questions need full schemas, and parent-visible cards
   may resolve against a child. An aggregate endpoint is a possible scale
   improvement, not a prerequisite demonstrated by this audit.
6. **Native delivery needs its own evidence.** The checkout has 32 Swift unit
   test methods and seven UI test methods, but no iOS build/test workflow was
   found. Swift hooks skip when the toolchain is absent. Browser mobile tests
   cannot validate native controls, lifecycle, SSO, accessibility or performance.

**Suggested implementation sequence**

| Step | Concrete result | Gate before expanding |
| --- | --- | --- |
| 1. Connection and test foundation | Define a server connection with separate identity/UI/API/stream routing, native credential storage and connection states. Establish a working Mac toolchain and native test fixture/CI. | Prove discover → login → identity → authenticated REST/SSE/WS on each selected deployment, including expiry. Define a supported server/harness matrix. |
| 2. Native reading slice | Native session list and conversation detail backed by a testable history/event reducer. Reuse existing server setup/persistence where appropriate. | Paginated history and live data converge after a mid-turn disconnect, foreground return and A→B→A session switch; no duplicate messages or cross-server state. |
| 3. Native interaction slice | Composer, draft/send state, interrupt and structured decisions. This completes the first useful connect → list → conversation → decision vertical slice. | Send/decision failures remain actionable; child targets and read-only permissions are correct; unknown events are tolerated; stale approvals cannot be submitted as current. |
| 4. Mobile workflow completion | Basic create, Attention, selected child/progress navigation, foreground notifications and typed deep-link intents. Add small extensions only after sizing. | Create-success/send-failure does not create a second session; Attention finds requests beyond page one; cold/warm links survive login; unsupported routes have a useful handoff. |
| 5. Upgrade and release validation | Migrate selected saved state, apply device/accessibility/performance checks, validate each distribution and server compatibility. | Recorded Mac/device results, meaningful native UI tests, reviewable demo media and a release/rollback plan. Existing web cookies are not assumed to become native credentials. |

The intended ownership is native connection services → native session/list
repositories and conversation reducer → SwiftUI views and platform adapters.
Any optional web renderer receives a bounded content/interaction contract.
Specific libraries and detailed type/module layout are implementation design
decisions, not established by this source audit.

**Results and remaining decisions**

The existing focused web baseline passed **527 tests across 10 files**, and the
production web build passed. Plists/scheme XML parsed, but iOS compilation,
XCTest, backend pytest, Playwright journeys, real deployment login, screenshots,
accessibility and performance were not executed here. This is a Linux workspace
without Xcode/Swift; [validation-baseline.md](validation-baseline.md) records the
precise limits and Mac handoff.

Before locking the implementation scope, settle the first-release deployment
priority, supported server/harness floor, whether basic attachments/read-only
artifacts belong in the first release, and how much local queue behavior to
retain. Both standalone and workspace deployments were assessed; support for a
particular workspace integration still requires its owner's contract and runtime
proof. No background push/delivery guarantee is included in the recommendation.

To review the discovery, start with the scope table above, then read the five
journeys and acceptance criteria in [mobile-scope.md](mobile-scope.md). To verify
the current baseline, run the exact web commands and Mac test invocation in
[validation-baseline.md](validation-baseline.md); use its device checklist to
record the remaining runtime evidence. Application code has not been rewritten
during discovery.

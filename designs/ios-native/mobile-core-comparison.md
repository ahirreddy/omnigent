# Mobile Omni: the native core

Source baseline: local clone of Arca's clean main,
76281b9438578e472810879e18fc60acc64d3d6c, inspected on 2026-10-16.
This is the Arca snapshot, not a claim that GitHub was fetched to its latest commit.
Local branch: feature/mobile-native-core.

The product goal is to pick up work from your phone: find a session, understand
its state, write a thoughtful message, and unblock a decision. Codex-inspired
patterns here mean a quiet session browser, obvious compose action and native
long-form editing—not a pixel-for-pixel reproduction or copied assets.

| Omnigent capability | Mobile priority | Native preview in this change |
| --- | --- | --- |
| Session list, search, activity and workspace context | Core | Recent-first list; pinned/recent sections; search title, message preview, project and agent; running/attention/archive filters |
| Pin, rename, archive and restore | Core | Native swipe actions, context menus and conversation menu; persisted locally; no destructive delete |
| Read/continue conversations | Core | Native selectable text, basic Markdown and code, copy/share, simulated incremental replies, Stop and jump-to-latest |
| Long messages and drafts | Core | Growing inline field plus expandable native TextEditor sheet; shared draft binding; keyboard dismissal; local drafts survive navigation and relaunch |
| Approvals and questions | Core | Existing native approval/decline and option cards retained; Attention includes archived pending sessions; read-only and decision gates preserved |
| New session | Core | Native creation sheet, optional name, durable unsent first prompt, create-then-send behavior |
| Connect, authenticate, switch servers | Core for a live release | **Not implemented in NativeLab.** Existing production web shell remains unchanged |
| Real-time server updates and recovery | Core for a live release | **Not implemented.** Local demo stream and explicit interrupted-reply recovery only |
| Rich artifacts and attachments | Next | Deferred; read-only review should precede mobile editing |
| Projects | Simplify | Display/search workspace context; no project administration |
| Background notifications | Later | No APNs or background-delivery guarantee |
| Terminal, Monaco editor, execution logs | Desktop-first | Omitted from the native preview |
| Agent/host setup, scheduling, admin | Desktop-first | Omitted; create against an already configured host in a future live adapter |

## Source evidence

- [iOS README](../../web/ios/README.md) and
  [AppRootView](../../web/ios/Omnigent/AppRootView.swift):
  the shipping iOS app is a SwiftUI/WKWebView shell, not a native conversation client.
- [Sidebar.tsx](../../web/src/shell/Sidebar.tsx):
  server-authoritative pins, project organization, archived-session routing and search.
- [sessionsApi.ts](../../web/src/lib/sessionsApi.ts):
  create, snapshot, cursor-paged history, message acceptance, interrupt and label updates.
- [Server schemas](../../omnigent/server/schemas.py):
  SessionListItem includes timestamps, workspace, archive, permissions, pending
  elicitation count and per-viewer read state; elicitation params include schema
  and child target routing.
- [SessionRail.tsx](../../web/src/shell/SessionRail.tsx):
  terminal and execution-log panels illustrate desktop functionality omitted here.
- [server-contracts.md](server-contracts.md):
  detailed discovery of API routing, auth modes and stream reconciliation.

## Native implementation decisions

NativeLab remains a separate app/bundle; importing the tested prototype does
not replace or regress the production web-shell target. The original copy in
Downloads is unchanged. No browser session, token or production conversation
was copied into the preview.

Use system glassEffect for the composer on iOS 26+, native material on iOS 18,
and a solid semantic background with Reduce Transparency. Native sheets and
navigation provide system chrome. Glass is limited to controls; reading surfaces
stay quiet. TextEditor supplies native selection, paste, undo, dictation through
the system keyboard, and scrolling. iPhone and iPad are enabled; layouts use
semantic text sizes, bounded reading width, safe-area insets and no fixed editor
height.

The versioned local store atomically writes demo snapshots and drafts under
Application Support. iOS file protection is applied. Unknown/corrupt data is
left untouched and a temporary-workspace warning is shown. In-flight demo
replies reopen with their partial text and an interruption explanation. UUID
identifiers prevent collisions across launches. This is local preview storage,
not a server cache or encrypted credential store.

## Live-release boundary

A live release still needs deployment-aware API/UI base discovery, supported
native authentication and secure credential storage, cursor pagination,
subscribe-before-hydrate streaming, foreground/reconnect reconciliation,
read-state writes, server-backed organization, full elicitation schemas and
host/agent selection for creation. HTTP acceptance is not confirmation that an
agent consumed a message; uncertain sends must not be automatically retried.
Keep server/account identity in every draft/cache key when that integration is
introduced. The preview does not currently implement those contracts.

See [mobile-native-core.md](../../specs/features/mobile-native-core.md) for
acceptance criteria and the NativeLab README for commands and verification.

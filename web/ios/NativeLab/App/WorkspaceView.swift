import NativeLabCore
import SwiftUI

struct WorkspaceView: View {
  @ObservedObject private var notifications = NativeNotificationController.shared
  @EnvironmentObject private var model: AppModel
  @State private var selectedTab: WorkspaceTab = .sessions
  @State private var sessionsPath: [String] = []
  @State private var inboxPath: [String] = []
  @State private var searchText = ""
  @State private var filter: SessionFilter = .all
  @State private var showsNewSession = false
  @State private var renamingSession: SessionSummary?

  private enum WorkspaceTab: Hashable {
    case sessions, inbox, settings
  }

  private var matchingSessions: [SessionSummary] {
    SessionQuery.matching(model.sessions, text: searchText, filter: filter)
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack(path: $sessionsPath) {
        List {
          Section {
            workspaceHeader
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
          }
          if let error = model.listError ?? (model.isLive ? nil : model.storageError) {
            Section {
              Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
              Button("Try again") {
                Task {
                  await model.refresh()
                  model.flushPersistence()
                }
              }
            }
          }
          if model.isRefreshing && model.sessions.isEmpty {
            ProgressView("Loading sessions…")
              .accessibilityIdentifier("sessions-loading")
          } else if matchingSessions.isEmpty {
            ContentUnavailableView {
              Label(
                searchText.isEmpty ? emptyTitle : "No matching sessions", systemImage: "bubble.left"
              )
            } description: {
              VStack(spacing: 8) {
                Text(
                  searchText.isEmpty
                    ? (model.isLive
                      ? "Your server sessions appear here automatically while the app is open."
                      : "Your conversations will appear here.")
                    : (model.isLive
                      ? "Search covers loaded sessions. Load more to include older sessions."
                      : "Try another title, message or project."))
                if searchText.isEmpty && filter == .all,
                  let reason = model.newSessionUnavailableReason
                {
                  Text(reason)
                }
              }
            } actions: {
              if model.canCreateSessions && searchText.isEmpty && filter == .all {
                Button("Start a session") { showsNewSession = true }
              }
            }
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("sessions-empty")
          }
          let pinned = matchingSessions.filter(\.isPinned)
          let recent = matchingSessions.filter { !$0.isPinned }
          if !pinned.isEmpty {
            Section("Pinned") {
              ForEach(pinned) { sessionLink($0) }
            }
          }
          if !recent.isEmpty {
            Section(filter == .archived ? "Archived" : "Recent") {
              ForEach(recent) { sessionLink($0) }
            }
          }
          if model.isLive && model.hasMoreSessions {
            Section {
              Button {
                Task { await model.loadMoreSessions() }
              } label: {
                HStack {
                  Text("Load more sessions")
                  if model.isLoadingMoreSessions { ProgressView() }
                }
              }
              .disabled(model.isLoadingMoreSessions || model.isRefreshing)
              .accessibilityIdentifier("load-more-sessions")
            } footer: {
              Text("Search and filters include only loaded sessions.")
            }
          }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sessions")
        .searchable(
          text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
          prompt: "Search sessions or projects"
        )
        .refreshable { await model.refresh() }
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Menu {
              ForEach(SessionFilter.allCases) { value in
                Button {
                  filter = value
                } label: {
                  if filter == value {
                    Label(value.rawValue, systemImage: "checkmark")
                  } else {
                    Text(value.rawValue)
                  }
                }
                .accessibilityIdentifier("filter-\(value.id)")
              }
            } label: {
              Label(filter.rawValue, systemImage: "line.3.horizontal.decrease")
            }
            .accessibilityLabel("Filter sessions")
            .accessibilityValue(filter.rawValue)
            .accessibilityIdentifier("session-filter")
          }
          ToolbarItem(placement: .primaryAction) {
            Button("New session", systemImage: "square.and.pencil") {
              showsNewSession = true
            }
            .disabled(!model.canCreateSessions)
            .accessibilityHint(model.newSessionUnavailableReason ?? "Start a conversation")
            .accessibilityIdentifier("new-session")
          }
        }
        .navigationDestination(for: String.self) { ConversationView(sessionID: $0) }
      }
      .tabItem {
        Label("Sessions", systemImage: "bubble.left.and.bubble.right")
          .accessibilityIdentifier("sessions-tab")
      }
      .tag(WorkspaceTab.sessions)

      NavigationStack(path: $inboxPath) {
        List {
          Section {
            Text("Sessions with approvals or questions to review.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .listRowBackground(Color.clear)
          }
          if let error = model.inboxError {
            Section {
              Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("inbox-error")
              Button("Try again") {
                Task { await model.refreshInbox() }
              }
              .disabled(model.isLoadingInbox)
              .accessibilityIdentifier("retry-inbox")
            }
          }
          if model.isLoadingInbox && model.inboxSessions.isEmpty {
            ProgressView("Loading Inbox…")
              .accessibilityIdentifier("inbox-loading")
          } else if model.inboxSessions.isEmpty && model.inboxError == nil {
            ContentUnavailableView(
              "You're all caught up", systemImage: "checkmark.circle",
              description: Text("Sessions that need your response appear here.")
            )
            .accessibilityIdentifier("inbox-empty")
            .listRowBackground(Color.clear)
          }
          ForEach(model.inboxSessions) { sessionLink($0) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Inbox")
        .refreshable { await model.refreshInbox() }
        .task { await model.refreshInbox() }
        .navigationDestination(for: String.self) { ConversationView(sessionID: $0) }
      }
      .tabItem {
        Label("Inbox", systemImage: "tray")
          .accessibilityIdentifier("inbox-tab")
      }
      .badge(model.inboxSessions.count)
      .tag(WorkspaceTab.inbox)

      NavigationStack { WorkspaceSettingsView() }
        .tabItem {
          Label("Settings", systemImage: "gearshape")
            .accessibilityIdentifier("settings-tab")
        }
        .tag(WorkspaceTab.settings)
    }
    .task { await model.start() }
    .onChange(of: notifications.pendingRoute, initial: true) { _, _ in openPendingNotification() }
    .onChange(of: model.connectionGeneration) { _, _ in
      sessionsPath = []
      inboxPath = []
      selectedTab = .sessions
      searchText = ""
      filter = .all
      showsNewSession = false
      renamingSession = nil
      openPendingNotification()
    }
    .onChange(of: model.notificationScope) { _, _ in openPendingNotification() }
    .safeAreaInset(edge: .top) {
      if let route = notifications.pendingRoute, route.scope != model.notificationScope {
        HStack(alignment: .top) {
          Text(
            "Connect to \(route.scope.serverURL) as \(route.scope.userID) to open the waiting notification."
          )
          .font(.caption)
          Button("Dismiss") { notifications.clearPendingRoute() }
        }
        .padding(12).background(.bar)
        .accessibilityIdentifier("notification-scope-mismatch")
      }
    }
    .sheet(isPresented: $showsNewSession) {
      NewSessionView { sessionID in
        selectedTab = .sessions
        filter = .all
        searchText = ""
        sessionsPath = [sessionID]
        showsNewSession = false
      }
      .environmentObject(model)
    }
    .sheet(item: $renamingSession) { session in
      RenameSessionView(session: session).environmentObject(model)
    }
  }

  private var emptyTitle: String {
    if model.isLive {
      return model.hasMoreSessions ? "No matches in loaded sessions" : "No matching server sessions"
    }
    return switch filter {
    case .all: "A fresh start"
    case .running: "Nothing running"
    case .needsResponse: "You're all caught up"
    case .archived: "No archived sessions"
    }
  }

  private func openPendingNotification() {
    guard let route = notifications.pendingRoute, route.scope == model.notificationScope else {
      return
    }
    showsNewSession = false
    renamingSession = nil
    selectedTab = .sessions
    filter = .all
    searchText = ""
    sessionsPath = [route.sessionID]
    notifications.clearPendingRoute()
  }

  private var workspaceHeader: some View {
    HStack(spacing: 12) {
      Image(systemName: "sparkle")
        .font(.title2.weight(.medium))
        .frame(width: 44, height: 44)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Your workspace").font(.headline)
        Text(model.isLive ? "Connected server" : "Sample workspace · Offline")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier(
            model.isLive ? "live-workspace-notice" : "sample-workspace-notice")
        if model.isLive {
          HStack(spacing: 6) {
            if model.isReconnecting { ProgressView().controlSize(.mini) }
            Text(model.connectionStatus)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .accessibilityIdentifier("workspace-connection-status")
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
  }

  private func sessionLink(_ session: SessionSummary) -> some View {
    NavigationLink(value: session.id) {
      VStack(alignment: .leading, spacing: 4) {
        SessionRow(
          session: session,
          pendingCount: model.snapshot(for: session.id)?.pendingDecisions.count ?? 0,
          hasDraft: !(model.drafts[session.id] ?? "").isEmpty
        )
        if let error = model.errors[session.id] {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityIdentifier("session-row-error-\(session.id)")
        }
      }
    }
    .accessibilityIdentifier("session-row-\(session.id)")
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      if session.canPin {
        Button(
          session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin"
        ) {
          Task { await model.editSession(session.id, change: .pinned(!session.isPinned)) }
        }
        .tint(.indigo)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if session.canArchive {
        Button(session.isArchived ? "Restore" : "Archive", systemImage: "archivebox") {
          Task { await model.editSession(session.id, change: .archived(!session.isArchived)) }
        }
        .tint(.gray)
      }
    }
    .contextMenu {
      if session.canRename {
        Button("Rename", systemImage: "pencil") { renamingSession = session }
      }
      if session.canPin {
        Button(session.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
          Task { await model.editSession(session.id, change: .pinned(!session.isPinned)) }
        }
      }
      if session.canArchive {
        Button(session.isArchived ? "Restore" : "Archive", systemImage: "archivebox") {
          Task { await model.editSession(session.id, change: .archived(!session.isArchived)) }
        }
      }
    }
    .disabled(model.editingSessionIDs.contains(session.id))
    .accessibilityActions {
      if session.canRename {
        Button("Rename session") { renamingSession = session }
      }
    }
  }
}

private struct SessionRow: View {
  let session: SessionSummary
  let pendingCount: Int
  let hasDraft: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(session.title)
          .font(.headline)
          .lineLimit(2)
        Spacer(minLength: 0)
        Text(session.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      Text(session.preview)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      HStack(spacing: 6) {
        HarnessLogo(harness: session.configuration?.harness).frame(width: 18, height: 18)
        Text(session.configuration?.modelLabel ?? "Model not reported")
          .font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(session.configuration?.identityLabel ?? "Harness & model not reported")
      .accessibilityIdentifier("session-identity-\(session.id)")
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { metadata }
        VStack(alignment: .leading, spacing: 6) { metadata }
      }
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var metadata: some View {
    Text(session.workspace).foregroundStyle(.secondary).lineLimit(1).font(.caption)
    if hasDraft {
      Label("Draft", systemImage: "pencil")
        .font(.caption.weight(.medium)).foregroundStyle(.orange)
    }
    if session.isArchived {
      Label("Archived", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary)
    }
    SessionStatusLabel(session: session, pendingCount: pendingCount)
  }
}

private struct WorkspaceSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var signOutError: String?

  var body: some View {
    Form {
      Section {
        Label("Omni Native Preview", systemImage: "sparkle").font(.headline)
        Text("A focused, native workspace for your phone and iPad.")
          .foregroundStyle(.secondary)
      }
      Section("Connection") {
        if model.isLive {
          Label("Connected server", systemImage: "network")
          Text(model.connectedServerURL).font(.footnote).textSelection(.enabled)
          Text("Identity: \(model.serverIdentity)")
            .font(.footnote)
            .accessibilityIdentifier("live-identity")
          HStack(spacing: 8) {
            if model.isReconnecting { ProgressView() }
            Text(model.connectionStatus)
          }
          .accessibilityIdentifier("connection-status")
          Text(
            "Messages, session activity and Inbox requests update while the app is open. Send messages and respond to requests where your permissions allow."
          )
          .foregroundStyle(.secondary)
          Button("Use offline sample workspace") {
            Task { await model.useDemo() }
          }
          .accessibilityIdentifier("use-demo")
          Button("Sign out and forget this account", role: .destructive) {
            guard let url = URL(string: model.connectedServerURL) else { return }
            do {
              try SecureServerStore().remove(
                SavedServerAccount(serverURL: url, userID: model.serverIdentity))
              signOutError = nil
              Task { await model.useDemo() }
            } catch { signOutError = error.localizedDescription }
          }
          .accessibilityIdentifier("sign-out-server")
          if let signOutError { Text(signOutError).foregroundStyle(.red) }
        } else {
          Label("Offline sample workspace", systemImage: "wifi.slash")
          Text(
            "Replies and decisions are simulated. Your sample drafts are kept when switching connections."
          )
          .foregroundStyle(.secondary)
        }
      }
      Section(model.isLive ? "Switch or reconnect" : "Connect to a server") {
        LocalServerConnectionControls()
      }
      NativeNotificationSettingsView()
      if let reason = model.newSessionUnavailableReason {
        Section("Starting sessions") {
          Label(reason, systemImage: "desktopcomputer")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("new-session-unavailable")
        }
      }
      Section("On this device") {
        Label("Sample drafts and sessions are saved", systemImage: "internaldrive")
        Text(
          "Offline sample data stays in this app's local storage. Server sessions are kept in memory only and are never written into the sample workspace. Removing the app removes saved sample data."
        )
        .foregroundStyle(.secondary)
        if let error = model.storageError {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          Button("Retry saving") { model.flushPersistence() }
        }
      }
      Section("Native controls") {
        Text(
          "Expand the composer for long messages. Dismiss it to keep your draft. Long-press a session for rename, pin and archive."
        )
        Text(
          "Liquid Glass is used on iOS 26 and later. Earlier systems use native material, and Reduce Transparency uses solid surfaces."
        )
        .foregroundStyle(.secondary)
      }
      Section("What's next") {
        Text(
          "Physical-phone validation and richer artifact editing."
        )
        Text(
          "Background push needs APNs signing and server configuration. Sample replies do not resume after the app closes."
        )
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Settings")
    .accessibilityIdentifier("demo-settings")
  }
}

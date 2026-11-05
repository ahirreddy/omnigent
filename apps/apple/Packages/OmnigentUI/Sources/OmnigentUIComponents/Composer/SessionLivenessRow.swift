import SwiftUI

/// The agent's liveness under the composer: "Connecting…" while a turn wakes it, a quiet
/// asleep line (the next message relaunches it), or for an unreachable session the web's
/// "Host is offline — click to reconnect" with the reconnect sheet, and from it Switch Host or
/// Resume on a Machine.
struct SessionLivenessRow: View {
  let notice: SessionLivenessNotice
  let actions: SessionLivenessActions
  /// The row's own sheet state when the conversation keeps none.
  @State private var localSheets = SessionLivenessSheets()

  private var sheets: SessionLivenessSheets { actions.sheets ?? localSheets }

  var body: some View {
    Group {
      if let line = notice.line {
        HStack(spacing: Theme.Spacing.small) {
          if notice.liveness == .starting {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "moon.zzz").foregroundStyle(.secondary).accessibilityHidden(true)
          }
          Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
      } else if notice.liveness.isUnreachable {
        Button {
          sheets.shown = .reconnect
        } label: {
          Label("\(notice.title) \u{2014} reconnect\u{2026}", systemImage: "wifi.slash")
            .font(.callout)
            .foregroundStyle(Theme.failure)
        }
        .buttonStyle(.borderless)
        .help("How to reconnect this session")
        .accessibilityIdentifier("composer-liveness-reconnect")
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, Theme.Spacing.medium)
    .accessibilityIdentifier("composer-liveness")
    .sheet(item: Bindable(sheets).shown) { sheet in
      switch sheet {
      case .reconnect:
        ReconnectSessionSheet(notice: notice, actions: actions) { sheets.shown = $0 }
      case .switchHost, .resume:
        if let route = sheet == .switchHost ? actions.switchHost : actions.resume {
          HostMoveSheet(kind: route.kind, actions: route.actions) { sheets.shown = nil }
        }
      }
    }
  }
}

/// How to bring an unreachable session back (the web's `ReconnectSessionDialog`): the command
/// to run on the machine, Check Again, moving to another machine, and forking to continue in a
/// copy.
struct ReconnectSessionSheet: View {
  let notice: SessionLivenessNotice
  let actions: SessionLivenessActions
  /// Closes the sheet, or replaces it with another (`nil` closes).
  let show: @MainActor (SessionLivenessSheet?) -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(notice.message).fixedSize(horizontal: false, vertical: true)
        }
        if let command = notice.command {
          Section("Command") {
            Text(command)
              .font(Theme.codeFont)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("reconnect-session-command")
            CopyButton(
              text: command, label: "Copy Command", identifier: "reconnect-session-copy",
              showsLabel: true)
          }
        }
        moveSection
        Section {
          if let checkAgain = actions.checkAgain {
            Button("Check Again", systemImage: "arrow.clockwise") {
              checkAgain()
              show(nil)
            }
            .accessibilityIdentifier("reconnect-session-check")
          }
          if let fork = actions.fork {
            Button("Fork Session\u{2026}", systemImage: "arrow.triangle.branch") {
              show(nil)
              fork()
            }
            .accessibilityIdentifier("reconnect-session-fork")
          }
        } footer: {
          if actions.fork != nil {
            Text(
              actions.switchHost == nil
                ? "Can\u{2019}t bring that machine back? Fork the session to continue in a copy."
                : "Or fork the session to continue in a copy.")
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(notice.title)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { show(nil) }
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, minHeight: 320)
    #endif
    .accessibilityIdentifier("reconnect-session-sheet")
  }

  /// The way out when the machine may not come back: move to another host (owners of a session
  /// whose host is offline), or start on one of the user's machines (a session bound to none).
  @ViewBuilder private var moveSection: some View {
    if actions.switchHost != nil {
      Section {
        Button("Switch Host\u{2026}", systemImage: "arrow.left.arrow.right") { show(.switchHost) }
          .accessibilityIdentifier("reconnect-session-switch-host")
      } footer: {
        Text("Can\u{2019}t bring that machine back? Move the session to another one instead.")
      }
    } else if actions.resume != nil {
      Section {
        Button("Resume on a Machine\u{2026}", systemImage: "desktopcomputer") { show(.resume) }
          .accessibilityIdentifier("reconnect-session-resume")
      } footer: {
        Text("Pick one of your machines and a directory to continue the conversation there.")
      }
    }
  }
}

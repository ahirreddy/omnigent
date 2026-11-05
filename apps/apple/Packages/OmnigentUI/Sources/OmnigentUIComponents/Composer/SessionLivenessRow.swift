import SwiftUI

/// The agent's liveness under the composer: "Connecting…" while a turn wakes it, a quiet
/// asleep line (the next message relaunches it), or for an unreachable session the web's
/// "Host is offline — click to reconnect" with the reconnect sheet.
struct SessionLivenessRow: View {
  let notice: SessionLivenessNotice
  let actions: SessionLivenessActions
  @State private var showsReconnect = false

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
          showsReconnect = true
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
    .sheet(isPresented: $showsReconnect) {
      ReconnectSessionSheet(notice: notice, actions: actions) { showsReconnect = false }
    }
  }
}

/// How to bring an unreachable session back (the web's `ReconnectSessionDialog`): the command
/// to run on the machine, Check Again, and forking to continue in a copy.
struct ReconnectSessionSheet: View {
  let notice: SessionLivenessNotice
  let actions: SessionLivenessActions
  let close: @MainActor () -> Void

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
        Section {
          if let checkAgain = actions.checkAgain {
            Button("Check Again", systemImage: "arrow.clockwise") {
              checkAgain()
              close()
            }
            .accessibilityIdentifier("reconnect-session-check")
          }
          if let fork = actions.fork {
            Button("Fork Session\u{2026}", systemImage: "arrow.triangle.branch") {
              close()
              fork()
            }
            .accessibilityIdentifier("reconnect-session-fork")
          }
        } footer: {
          if actions.fork != nil {
            Text("Can\u{2019}t bring that machine back? Fork the session to continue in a copy.")
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
          Button("Done", action: close)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, minHeight: 320)
    #endif
    .accessibilityIdentifier("reconnect-session-sheet")
  }
}

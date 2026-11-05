import OmnigentPlatform
public import SwiftUI

/// The fix sheet for a harness on a host (the web's `HarnessFixDialog` beyond first setup).
public struct HarnessFixSheetState: Equatable, Sendable {
  /// What the sheet shows.
  public enum Phase: Equatable, Sendable {
    /// Before switching: who is signed in, and whether an account can be named.
    case confirmSwitch(account: String?, asksForEmail: Bool)
    /// In progress.
    case working(String)
    /// Enter `code` at `link` before `expiresAt`.
    case deviceCode(link: URL?, code: String, expiresAt: Date)
    /// Another sign-in is running on the host.
    case waitingForOtherSignIn
    /// Run `command` on the host, then check again.
    case runCommand(command: String, hint: String, stillNotReady: Bool)
    /// More setup is needed; Continue opens the setup sheet.
    case needsSetup(String)
    /// Failed.
    case failed(String)
    /// Done.
    case done(String)
  }

  /// The title.
  public var title: String
  /// The host's name.
  public var hostName: String
  /// What shows.
  public var phase: Phase
  /// A Check Again is in flight.
  public var isChecking: Bool

  /// Creates the state.
  public init(title: String, hostName: String, phase: Phase, isChecking: Bool = false) {
    self.title = title
    self.hostName = hostName
    self.phase = phase
    self.isChecking = isChecking
  }
}

/// What the fix sheet can do.
public struct HarnessFixActions {
  /// Sign out and switch, signing in as the optional email.
  public var confirmSwitch: @MainActor (String?) -> Void
  /// Check the harness again after running a command.
  public var checkAgain: @MainActor () -> Void
  /// Try the failed step again.
  public var retry: @MainActor () -> Void
  /// Continue in the setup sheet.
  public var continueSetup: @MainActor () -> Void
  /// Close; cancels a pending sign-in.
  public var close: @MainActor () -> Void

  /// Creates the actions.
  public init(
    confirmSwitch: @escaping @MainActor (String?) -> Void,
    checkAgain: @escaping @MainActor () -> Void, retry: @escaping @MainActor () -> Void,
    continueSetup: @escaping @MainActor () -> Void, close: @escaping @MainActor () -> Void
  ) {
    self.confirmSwitch = confirmSwitch
    self.checkAgain = checkAgain
    self.retry = retry
    self.continueSetup = continueSetup
    self.close = close
  }
}

/// Switches a harness's account, signs it in with a device code, updates it, or walks through a
/// sign-in command run on the host, with Check Again.
public struct HarnessFixSheet: View {
  private let state: HarnessFixSheetState
  private let actions: HarnessFixActions
  @State private var email = ""

  /// Creates the sheet.
  public init(state: HarnessFixSheetState, actions: HarnessFixActions) {
    self.state = state
    self.actions = actions
  }

  /// The sheet.
  public var body: some View {
    NavigationStack {
      Form { content }
        .formStyle(.grouped)
        .navigationTitle(state.title)
        .toolbar { toolbar }
    }
    #if os(macOS)
      .frame(width: 480)
      .frame(minHeight: 240, idealHeight: 320)
    #endif
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness-fix-sheet")
  }

  @ViewBuilder private var content: some View {
    switch state.phase {
    case .confirmSwitch(let account, let asksForEmail):
      Section {
        Text("\(state.hostName) is signed in as \(Text(account ?? "the current account").bold()).")
        Label(
          "Switching signs this machine out of that account. Every session on \(state.hostName) that uses this harness will use the new account. Running sessions keep working until their token expires.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(Theme.warning)
        if asksForEmail {
          TextField(
            "Account to sign in with (optional)", text: $email,
            prompt: Text(verbatim: "name@example.com")
          )
          .accessibilityIdentifier("harness-fix-email")
        }
      }
    case .working(let message):
      Section {
        HStack(spacing: Theme.Spacing.medium) {
          ProgressView().controlSize(.small)
          Text(message)
        }
        Text("This can take a few minutes.").font(.caption).foregroundStyle(.secondary)
      }
    case .deviceCode(let link, let code, let expiresAt):
      HarnessDeviceCodeSection(link: link, code: code, expiresAt: expiresAt)
    case .waitingForOtherSignIn:
      Section {
        HStack(spacing: Theme.Spacing.medium) {
          ProgressView().controlSize(.small)
          Text(
            "Another sign-in is already in progress on \(state.hostName). Waiting for it to finish\u{2026}"
          )
        }
      }
    case .runCommand(let command, let hint, let stillNotReady):
      Section {
        Text("Run this in a terminal on \(state.hostName), then come back.")
        CopyCommandButton(command: command)
        Text(hint).font(.caption).foregroundStyle(.secondary)
        if stillNotReady {
          Text("Still not signed in on \(state.hostName).")
            .foregroundStyle(Theme.failure)
            .accessibilityIdentifier("harness-fix-still-not-ready")
        }
      }
    case .needsSetup(let message):
      Section {
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
      }
    case .failed(let message):
      Section {
        Text(
          "Nothing changed on \(state.hostName). Try again, or run setup in a terminal on that machine."
        )
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(Theme.failure)
          .textSelection(.enabled)
          .accessibilityIdentifier("harness-fix-error")
        CopyCommandButton(command: "omni setup")
      }
    case .done(let message):
      Section {
        Label(message, systemImage: "checkmark.circle.fill")
          .foregroundStyle(Theme.success)
          .accessibilityIdentifier("harness-fix-done")
      }
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    switch state.phase {
    case .confirmSwitch:
      ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: actions.close) }
      ToolbarItem(placement: .confirmationAction) {
        Button("Sign Out and Switch") {
          let trimmed = email.trimmingCharacters(in: .whitespaces)
          actions.confirmSwitch(trimmed.isEmpty ? nil : trimmed)
        }
        .accessibilityIdentifier("harness-fix-confirm-switch")
      }
    case .runCommand:
      ToolbarItem(placement: .cancellationAction) { Button("Close", action: actions.close) }
      ToolbarItem(placement: .confirmationAction) {
        Button(state.isChecking ? "Checking\u{2026}" : "Check Again", action: actions.checkAgain)
          .disabled(state.isChecking)
          .accessibilityIdentifier("harness-fix-check-again")
      }
    case .needsSetup:
      ToolbarItem(placement: .cancellationAction) { Button("Close", action: actions.close) }
      ToolbarItem(placement: .confirmationAction) {
        Button("Continue Setup\u{2026}", action: actions.continueSetup)
      }
    case .failed:
      ToolbarItem(placement: .cancellationAction) { Button("Close", action: actions.close) }
      ToolbarItem(placement: .confirmationAction) {
        Button("Try Again", action: actions.retry).accessibilityIdentifier("harness-fix-retry")
      }
    case .done:
      ToolbarItem(placement: .confirmationAction) { Button("Done", action: actions.close) }
    case .working, .deviceCode, .waitingForOtherSignIn:
      ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: actions.close) }
    }
  }
}

/// Codex's device sign-in: open the link, enter the code, wait.
struct HarnessDeviceCodeSection: View {
  let link: URL?
  let code: String
  let expiresAt: Date

  var body: some View {
    Section {
      if let link {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          Text("1. Open the ChatGPT sign-in page and choose the account for Codex.")
          HStack {
            Link(destination: link) {
              Label("Open Sign-In Page", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("harness-fix-open-link")
            CopyValueButton(value: link.absoluteString, title: "Copy Link")
          }
        }
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          Text("2. Enter this one-time code when asked:")
          HStack {
            Text(code)
              .font(.system(.title2, design: .monospaced).weight(.semibold))
              .tracking(2)
              .textSelection(.enabled)
              .accessibilityIdentifier("harness-fix-code")
            CopyValueButton(value: code, title: "Copy Code")
          }
        }
        TimelineView(.periodic(from: .now, by: 1)) { context in
          HStack(spacing: Theme.Spacing.medium) {
            ProgressView().controlSize(.small)
            Text(
              "Waiting for you to finish in the browser\u{2026} Code expires in \(Self.countdown(until: expiresAt, now: context.date))."
            )
            .foregroundStyle(.secondary)
          }
        }
      } else {
        Text("The host returned an invalid sign-in link.").foregroundStyle(Theme.failure)
      }
    }
  }

  /// `m:ss` until `date`, never negative.
  static func countdown(until date: Date, now: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
    let remainder = seconds % 60
    return "\(seconds / 60):\(remainder < 10 ? "0" : "")\(remainder)"
  }
}

/// Copies a value, showing that it did.
struct CopyValueButton: View {
  let value: String
  let title: String
  @State private var copied = false

  var body: some View {
    Button(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc") {
      Pasteboard.copy(value)
      copied = true
    }
    .accessibilityLabel(title)
  }
}

#if os(macOS)
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Harness settings screens with hostile data", .serialized)
  struct HarnessScreensRenderTests {
    private static let setupActions = HarnessSetupActions(
      install: {}, saveCredential: { _ in }, close: {})
    private static let fixActions = HarnessFixActions(
      confirmSwitch: { _ in }, checkAgain: {}, retry: {}, continueSetup: {}, close: {})
    private static let detailActions = HarnessDetailActions(
      back: {}, fixWarning: {}, fixCredential: {})
    private static let listActions = HarnessesSettingsActions(
      selectHost: { _ in }, setUp: { _ in }, refresh: {}, open: { _ in })

    private static var realisticSteps: [HarnessSetupStepState] {
      [
        HarnessSetupStepState(
          id: "install", title: "Install Codex", detail: "Installs the CLI.", status: .done,
          control: .install, loginCommand: nil),
        HarnessSetupStepState(
          id: "credential", title: "Add a credential", detail: "An API key or a subscription.",
          status: .todo, control: .credential(enabled: true), loginCommand: "codex login"),
        HarnessSetupStepState(
          id: "command", title: "Trust the folder", detail: "Run this once.", status: .unknown,
          control: .command("codex trust ."), loginCommand: nil),
      ]
    }

    private static var hostileSteps: [HarnessSetupStepState] {
      let controls: [HarnessSetupStepState.Control] = [
        .none, .install, .credential(enabled: false), .credential(enabled: true),
        .command(HostileData.unbroken), .command(""),
      ]
      let statuses: [HarnessSetupStepState.Status] = [.done, .todo, .unknown]
      return (0..<HostileData.formRowCount).map { index in
        HarnessSetupStepState(
          id: "\(index)", title: HostileData.text(index), detail: HostileData.text(index + 1),
          status: statuses[index % statuses.count], control: controls[index % controls.count],
          loginCommand: index.isMultiple(of: 2) ? HostileData.text(index) : nil)
      }
    }

    private static var hostileSetup: HarnessSetupSheetState {
      HarnessSetupSheetState(
        name: HostileData.bidirectional, hostName: HostileData.bidirectional, steps: hostileSteps,
        isInstalling: true, isSavingCredential: true, adoptableSource: HostileData.unbroken,
        notice: HostileData.controlCharacters, errorMessage: HostileData.bidirectional)
    }

    private static func fix(_ phase: HarnessFixSheetState.Phase, title: String = "Fix Codex")
      -> HarnessFixSheetState
    {
      HarnessFixSheetState(title: title, hostName: "ahir-mbp", phase: phase)
    }

    private static var realisticStartup: HarnessStartupState {
      HarnessStartupState(
        command: "/usr/local/bin/codex", found: true, source: "From the host's PATH.",
        listsEnvironment: true,
        environment: [HarnessStartupState.Variable(name: "CODEX_HOME", value: "~/.codex")],
        environmentNote: "Inherits the host's environment.", arguments: ["--full-auto"],
        argumentsNote: "")
    }

    private static var hostileStartup: HarnessStartupState {
      HarnessStartupState(
        command: HostileData.controlCharacters, found: false, source: HostileData.bidirectional,
        listsEnvironment: true,
        environment: (0..<HostileData.formRowCount).map {
          HarnessStartupState.Variable(
            name: "\($0)\(HostileData.text($0))", value: HostileData.text($0 + 1))
        },
        environmentNote: HostileData.bidirectional,
        arguments: (0..<HostileData.formRowCount).map(HostileData.text),
        argumentsNote: HostileData.controlCharacters)
    }

    private static func detail(
      name: String = "Codex", text: String = "Signed in", startup: HarnessDetailState.Startup,
      warning: HarnessDetailState.Warning? = nil
    ) -> HarnessDetailState {
      HarnessDetailState(
        harness: name, name: name, hostName: text, status: text, isReady: true, warning: warning,
        credentialLabel: text, credentialDescription: text, credentialWarning: warning != nil,
        credentialAction: warning?.action, notice: text, startup: startup)
    }

    private static var hostileList: HarnessesSettingsState {
      HarnessesSettingsState(
        hosts: (0..<HostileData.formRowCount).map {
          HarnessesSettingsHost(
            id: "\($0)", name: HostileData.text($0), isOnline: $0.isMultiple(of: 2))
        }, selectedHostID: "missing",
        rows: (0..<HostileData.formRowCount).map { index in
          HarnessesSettingsRow(
            id: "\(index)", name: HostileData.text(index), description: HostileData.text(index + 1),
            status: index.isMultiple(of: 2) ? HostileData.text(index) : nil,
            isReady: index.isMultiple(of: 3),
            needsSetup: !index.isMultiple(of: 3))
        }, errorMessage: HostileData.bidirectional)
    }

    nonisolated static let screens: [ScreenCase] = [
      ScreenCase("harness-setup-realistic", realistic: true) {
        HarnessSetupSheet(
          state: HarnessSetupSheetState(
            name: "Codex", hostName: "ahir-mbp", steps: realisticSteps,
            adoptableSource: "$OPENAI_API_KEY"), actions: setupActions)
      },
      ScreenCase("harness-setup-blank", narrowOnly: true) {
        HarnessSetupSheet(
          state: HarnessSetupSheetState(name: "", hostName: ""), actions: setupActions)
      },
      ScreenCase("harness-setup-loading", narrowOnly: true) {
        HarnessSetupSheet(
          state: HarnessSetupSheetState(name: "Codex", hostName: "h", isLoading: true),
          actions: setupActions)
      },
      ScreenCase("harness-setup-omni-setup", narrowOnly: true) {
        HarnessSetupSheet(
          state: HarnessSetupSheetState(
            name: HostileData.unbroken, hostName: HostileData.bidirectional, needsOmniSetup: true),
          actions: setupActions)
      },
      ScreenCase("harness-setup-hostile") {
        HarnessSetupSheet(state: hostileSetup, actions: setupActions)
      },
      ScreenCase("harness-credential-form-hostile", narrowOnly: true) {
        GroupedFormHost {
          HarnessCredentialForm(
            hostName: HostileData.bidirectional, loginCommand: HostileData.unbroken,
            adoptableSource: HostileData.bidirectional, isSaving: true, save: { _ in })
        }
      },
      ScreenCase("harness-fix-realistic", realistic: true) {
        HarnessFixSheet(
          state: fix(.confirmSwitch(account: "ahir@example.com", asksForEmail: true)),
          actions: fixActions)
      },
      ScreenCase("harness-fix-blank", narrowOnly: true) {
        HarnessFixSheet(
          state: HarnessFixSheetState(
            title: "", hostName: "", phase: .confirmSwitch(account: nil, asksForEmail: false)),
          actions: fixActions)
      },
      ScreenCase("harness-fix-working", narrowOnly: true) {
        HarnessFixSheet(state: fix(.working(HostileData.unbroken)), actions: fixActions)
      },
      ScreenCase("harness-fix-device-code-past", narrowOnly: true) {
        HarnessFixSheet(
          state: fix(
            .deviceCode(
              link: URL(string: "https://example.com/device"), code: HostileData.unbroken,
              expiresAt: .distantPast)), actions: fixActions)
      },
      ScreenCase("harness-fix-device-code-future-no-link", narrowOnly: true) {
        HarnessFixSheet(
          state: fix(.deviceCode(link: nil, code: "", expiresAt: .distantFuture)),
          actions: fixActions)
      },
      ScreenCase("harness-fix-waiting", narrowOnly: true) {
        HarnessFixSheet(state: fix(.waitingForOtherSignIn), actions: fixActions)
      },
      ScreenCase("harness-fix-command-hostile") {
        var state = fix(
          .runCommand(
            command: HostileData.unbroken, hint: HostileData.bidirectional, stillNotReady: true),
          title: HostileData.unbroken)
        state.isChecking = true
        return HarnessFixSheet(state: state, actions: fixActions)
      },
      ScreenCase("harness-fix-needs-setup", narrowOnly: true) {
        HarnessFixSheet(state: fix(.needsSetup(HostileData.unbroken)), actions: fixActions)
      },
      ScreenCase("harness-fix-failed", narrowOnly: true) {
        HarnessFixSheet(state: fix(.failed(HostileData.unbroken)), actions: fixActions)
      },
      ScreenCase("harness-fix-done", narrowOnly: true) {
        HarnessFixSheet(state: fix(.done(HostileData.controlCharacters)), actions: fixActions)
      },
      ScreenCase("harness-detail-realistic", realistic: true) {
        GroupedFormHost {
          HarnessDetailView(
            state: detail(startup: .loaded(realisticStartup)), actions: detailActions)
        }
      },
      ScreenCase("harness-detail-blank", narrowOnly: true) {
        GroupedFormHost {
          HarnessDetailView(
            state: detail(name: "", text: "", startup: .hidden), actions: detailActions)
        }
      },
      ScreenCase("harness-detail-loading", narrowOnly: true) {
        GroupedFormHost {
          HarnessDetailView(state: detail(startup: .loading), actions: detailActions)
        }
      },
      ScreenCase("harness-detail-unavailable", narrowOnly: true) {
        GroupedFormHost {
          HarnessDetailView(
            state: detail(startup: .unavailable(HostileData.unbroken)), actions: detailActions)
        }
      },
      ScreenCase("harness-detail-hostile") {
        GroupedFormHost {
          HarnessDetailView(
            state: detail(
              name: HostileData.bidirectional, text: HostileData.bidirectional,
              startup: .loaded(hostileStartup),
              warning: HarnessDetailState.Warning(
                message: HostileData.controlCharacters, action: HostileData.bidirectional)),
            actions: detailActions)
        }
      },
      ScreenCase("harness-detail-long-text", narrowOnly: true) {
        GroupedFormHost {
          HarnessDetailView(
            state: detail(
              name: HostileData.unbroken, text: HostileData.unbroken, startup: .hidden,
              warning: HarnessDetailState.Warning(
                message: HostileData.unbroken, action: HostileData.unbroken)),
            actions: detailActions)
        }
      },
      ScreenCase("harnesses-realistic", realistic: true) {
        GroupedFormHost {
          HarnessesSettingsSection(
            state: HarnessesSettingsState(
              hosts: [
                HarnessesSettingsHost(id: "h1", name: "ahir-mbp", isOnline: true),
                HarnessesSettingsHost(id: "h2", name: "lab", isOnline: false),
              ], selectedHostID: "h1",
              rows: [
                HarnessesSettingsRow(
                  id: "codex", name: "Codex", description: "OpenAI's agent",
                  status: "Configured", isReady: true, needsSetup: false),
                HarnessesSettingsRow(
                  id: "claude", name: "Claude Code", description: "Anthropic's agent",
                  status: "Needs sign-in", isReady: false, needsSetup: true),
              ]), actions: listActions)
        }
      },
      ScreenCase("harnesses-empty", realistic: true, narrowOnly: true) {
        GroupedFormHost {
          HarnessesSettingsSection(state: HarnessesSettingsState(), actions: listActions)
        }
      },
      ScreenCase("harnesses-loading", narrowOnly: true) {
        GroupedFormHost {
          HarnessesSettingsSection(
            state: HarnessesSettingsState(isLoading: true), actions: listActions)
        }
      },
      ScreenCase("harnesses-hostile") {
        GroupedFormHost {
          HarnessesSettingsSection(state: hostileList, actions: listActions)
        }
      },
    ]

    @Test("renders without crashing or hanging", arguments: screens)
    func render(screen: ScreenCase) throws {
      try ScreenRenderer.check(screen)
    }
  }

  @Suite("Device sign-in countdown")
  struct HarnessDeviceCountdownTests {
    private let now = Date(timeIntervalSince1970: 1_793_880_000)

    @Test("minutes and zero-padded seconds, rounding up so it never reads 0:00 early")
    func format() {
      let cases: [(TimeInterval, String)] = [
        (0, "0:00"), (0.2, "0:01"), (59, "0:59"), (60, "1:00"), (61, "1:01"), (3_600, "60:00"),
      ]
      for (seconds, text) in cases {
        #expect(
          HarnessDeviceCodeSection.countdown(until: now.addingTimeInterval(seconds), now: now)
            == text)
      }
    }

    @Test("an expired code reads 0:00, and a far-off one doesn't overflow")
    func extremes() {
      #expect(HarnessDeviceCodeSection.countdown(until: .distantPast, now: now) == "0:00")
      #expect(HarnessDeviceCodeSection.countdown(until: .distantFuture, now: now) != "0:00")
      // The server sends the expiry as 64-bit seconds.
      let largest = Date(timeIntervalSince1970: TimeInterval(Int64.max))
      #expect(HarnessDeviceCodeSection.countdown(until: largest, now: now) != "0:00")
    }
  }
#endif

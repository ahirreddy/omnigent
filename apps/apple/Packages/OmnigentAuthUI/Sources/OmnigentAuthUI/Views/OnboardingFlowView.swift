public import SwiftUI

/// What a window shows before it has a server, as the web's first-run selector: the landing
/// ("Get started locally" or "Join your team"), the local setup, and the server list.
///
/// The steps are local to the view. Once a connect starts, the flow leaves for the connecting and
/// sign-in screens; a failed connect comes back on the server list with the failure.
public struct OnboardingFlowView: View {
  private let directory: ServerDirectory
  private let prefill: String
  private let banner: AuthBanner?
  private let localSetup: LocalSetupState?
  private let validator: ServerURLValidator
  private let actions: AuthActions

  @State private var step: OnboardingStep

  /// Creates the flow.
  /// - Parameters:
  ///   - directory: The servers to offer.
  ///   - prefill: The URL to start the server list with.
  ///   - banner: A notice or the last connection failure.
  ///   - localSetup: This Mac's local setup, when it has one.
  ///   - validator: Checks typed URLs with the core's normalizer.
  ///   - actions: The store's actions.
  public init(
    directory: ServerDirectory, prefill: String, banner: AuthBanner?,
    localSetup: LocalSetupState?, validator: ServerURLValidator, actions: AuthActions
  ) {
    self.directory = directory
    self.prefill = prefill
    self.banner = banner
    self.localSetup = localSetup
    self.validator = validator
    self.actions = actions
    _step = State(
      initialValue: OnboardingStep.initial(
        directory: directory, banner: banner,
        offersLocalSetup: localSetup != nil && actions.localSetup != nil))
  }

  /// Opens on `step`, for previews and snapshots.
  init(
    step: OnboardingStep, directory: ServerDirectory, localSetup: LocalSetupState?,
    actions: AuthActions
  ) {
    self.init(
      directory: directory, prefill: "", banner: nil, localSetup: localSetup, validator: .preview,
      actions: actions)
    _step = State(initialValue: step)
  }

  /// The current step.
  public var body: some View {
    // A container, so the identifier names the flow without replacing its controls' own.
    ZStack {
      switch step {
      case .landing:
        LandingView(
          directory: directory, offersLocalSetup: setup != nil,
          getStarted: { step = .localIntro }, joinTeam: { step = .servers }, join: join)
      case .localIntro:
        if let setup, let state = localSetup {
          LocalIntroView(
            state: state, back: { step = .landing },
            proceed: {
              if state.needsCLI {
                step = .installCLI
              } else {
                step = .localProgress
                setup.start()
              }
            })
        }
      case .localProgress:
        if let setup, let state = localSetup {
          LocalProgressView(
            state: state, actions: setup, back: { step = backFromLocal },
            retry: { setup.start() })
        }
      case .installCLI:
        if let setup, let state = localSetup {
          InstallCLIView(
            state: state, actions: setup, back: { step = backFromLocal },
            start: {
              step = .localProgress
              setup.start()
            })
        }
      case .servers:
        ServerPickerView(
          directory: directory, prefill: prefill, banner: banner, validator: validator,
          actions: actions, localSetup: localSetup,
          back: offersLanding ? { step = .landing } : nil,
          join: join,
          startLocal: setup.map { setup in
            {
              step = .localProgress
              setup.start()
            }
          })
      case .runner(let serverUrl):
        RunnerChoiceView(
          serverUrl: serverUrl, directory: directory, localSetup: localSetup,
          back: { step = offersLanding ? .landing : .servers },
          proceed: { hostHere in
            if hostHere { setup?.hostAfterSignIn(serverUrl) }
            actions.connect(serverUrl)
          })
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("auth.onboarding")
  }

  private var setup: LocalSetupActions? {
    localSetup == nil ? nil : actions.localSetup
  }

  private var offersLanding: Bool {
    setup != nil || !directory.managed.isEmpty
  }

  private var backFromLocal: OnboardingStep {
    offersLanding ? .localIntro : .servers
  }

  /// Joins `serverUrl`, first asking where agents run when that applies.
  private func join(_ serverUrl: String) {
    if OnboardingStep.asksForRunner(
      joining: serverUrl, directory: directory, localSetup: localSetup)
    {
      step = .runner(serverUrl: serverUrl)
    } else {
      actions.connect(serverUrl)
    }
  }
}

/// "Meet Omnigent": the two first-run paths, or the organization's servers.
struct LandingView: View {
  let directory: ServerDirectory
  let offersLocalSetup: Bool
  let getStarted: () -> Void
  let joinTeam: () -> Void
  let join: (String) -> Void

  var body: some View {
    AuthCard(
      systemImage: "sparkles", title: "Meet Omnigent",
      subtitle: "One interface for all your coding agents."
    ) {
      VStack(spacing: 10) {
        if let preset = directory.managed.first {
          presetButton(preset)
        }
        if offersLocalSetup {
          LandingButton(
            title: "Get started locally", systemImage: "laptopcomputer",
            prominent: directory.managed.isEmpty, identifier: "auth.get-started-locally",
            action: getStarted)
        }
        LandingButton(
          title: directory.managed.isEmpty ? "Join your team" : "Other server\u{2026}",
          systemImage: "person.2", prominent: false, identifier: "auth.join-team",
          action: joinTeam)
      }
      LandingFooter().padding(.top, 8)
    } buttons: {
      EmptyView()
    }
  }

  /// The organization's first server, with the others in its menu.
  @ViewBuilder
  private func presetButton(_ preset: ManagedServerEntry) -> some View {
    HStack(spacing: 6) {
      LandingButton(
        title: joinTitle(preset), systemImage: "person.2.fill", prominent: true,
        identifier: "auth.join-preset", action: { join(preset.url) })
      if directory.managed.count > 1 {
        Menu {
          ForEach(directory.managed) { server in
            Button(ServerText.escaped(server.displayName, limit: 80)) { join(server.url) }
          }
        } label: {
          Image(systemName: "chevron.down")
            .accessibilityHidden(true)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .fixedSize()
        .help("Choose another organization server")
        .accessibilityLabel("Choose organization server")
        .accessibilityIdentifier("auth.choose-preset")
      }
    }
  }

  private func joinTitle(_ preset: ManagedServerEntry) -> String {
    "Join your team (\(ServerText.escaped(preset.displayName, limit: 40)))"
  }
}

/// A full-width landing button.
struct LandingButton: View {
  let title: String
  let systemImage: String
  let prominent: Bool
  let identifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity)
    }
    .controlSize(.large)
    .modifier(LandingButtonStyle(prominent: prominent))
    .accessibilityIdentifier(identifier)
  }
}

private struct LandingButtonStyle: ViewModifier {
  let prominent: Bool

  func body(content: Content) -> some View {
    if prominent {
      content.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
    } else {
      content.buttonStyle(.bordered)
    }
  }
}

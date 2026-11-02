#if os(iOS)
  public import OmnigentAuthUI
  import OmnigentStores
  public import OmnigentUIComponents
  public import SwiftUI

  extension View {
    /// Wires a scene to phone supervision: registers its connection, posts the core's
    /// notifications, polls when the scene backgrounds, opens tapped notifications, offers
    /// Settings › Notifications, and confirms pairing codes opened from the Camera.
    /// - Parameters:
    ///   - supervision: The app's coordinator.
    ///   - session: The scene's server session, once created.
    ///   - selection: The scene's destination, set when a notification is tapped.
    ///   - scenePhase: The scene's phase.
    /// - Returns: The view.
    public func phoneSupervision(
      _ supervision: PhoneSupervision, session: ServerSession?,
      selection: Binding<SidebarDestination?>, scenePhase: ScenePhase
    ) -> some View {
      modifier(
        PhoneSupervisionScene(
          supervision: supervision, session: session, selection: selection,
          scenePhase: scenePhase))
    }
  }

  struct PhoneSupervisionScene: ViewModifier {
    let supervision: PhoneSupervision
    let session: ServerSession?
    @Binding var selection: SidebarDestination?
    let scenePhase: ScenePhase

    @State private var showsSettings = false
    @State private var presenter = NotificationSettingsPresenter()
    @State private var pairing: PairingConfirmation?
    @State private var pairingProblem: String?

    private var connection: ConnectionStore? {
      session.flatMap { $0.isSignedIn ? $0.connection : nil }
    }

    func body(content: Content) -> some View {
      presenter.open = { showsSettings = true }
      let pending = connection?.notifications?.pending.count ?? 0
      let badge = connection?.notifications?.badgeCount ?? 0
      return
        content
        .environment(
          \.openNotificationSettings, OpenNotificationSettingsAction(presenter: presenter)
        )
        .sheet(isPresented: $showsSettings) {
          PhoneNotificationSettingsView(supervision: supervision)
        }
        .sheet(item: $pairing) { confirmation in
          ScrollView {
            PairingConfirmationView(
              confirmation: confirmation,
              connect: {
                session?.signIn.connect(confirmation.serverURL)
                pairing = nil
              },
              cancel: { pairing = nil }
            )
            .padding()
          }
          .presentationDetents([.medium, .large])
        }
        .alert(
          "Pairing code",
          isPresented: Binding(
            get: { pairingProblem != nil }, set: { if !$0 { pairingProblem = nil } })
        ) {
          Button("OK", role: .cancel) { pairingProblem = nil }
        } message: {
          Text(pairingProblem ?? "")
        }
        .onOpenURL(perform: openPairingCode)
        .onChange(of: session?.isSignedIn ?? false, initial: true) { signedIn() }
        .onChange(of: supervision.authorization, initial: true) {
          connection?.notifications?.setAllowed(supervision.isAllowed)
        }
        .onChange(of: pending) { deliver() }
        .onChange(of: badge) { Task { await supervision.setBadge(badge) } }
        .onChange(of: scenePhase) { _, phase in
          guard let connection else { return }
          if phase == .background { supervision.didEnterBackground(connection) }
          if phase == .active { Task { await supervision.refreshAuthorization() } }
        }
        .onChange(of: supervision.pendingOpen, initial: true) { open() }
    }

    private func signedIn() {
      guard let connection else { return }
      Task { await supervision.didSignIn(connection) }
      open()
    }

    private func deliver() {
      guard let connection else { return }
      Task { await supervision.deliverPending(from: connection) }
    }

    /// Opens the tapped notification's session once this scene is signed in to its server.
    private func open() {
      guard let payload = supervision.pendingOpen, let connection,
        let server = connection.supervisedServerURL,
        SupervisionConnections.key(server) == SupervisionConnections.key(payload.serverURL)
      else { return }
      supervision.pendingOpen = nil
      selection = .session(payload.openSessionID)
    }

    private func openPairingCode(_ url: URL) {
      let code: PairingCode
      do {
        code = try PairingCode(parsing: url.absoluteString)
      } catch .notAPairingCode {
        // Another kind of omnigent: link; this handler only reads pairing codes.
        return
      } catch {
        pairingProblem = error.message
        return
      }
      do {
        pairing = try code.confirmation(validator: .app)
      } catch {
        pairingProblem = error.message
      }
    }
  }

  /// Settings › Notifications on iPhone and iPad: permission, and a toggle per kind.
  struct PhoneNotificationSettingsView: View {
    let supervision: PhoneSupervision
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
      NavigationStack {
        Form {
          Section {
            LabeledContent("Permission", value: permission)
            switch supervision.authorization {
            case .notDetermined:
              Button("Allow Notifications") { Task { await supervision.requestAuthorization() } }
                .accessibilityIdentifier("notifications.allow")
            case .denied:
              Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                  openURL(url)
                }
              }
            default:
              EmptyView()
            }
          }
          Section {
            toggle("Approval requests", .approval)
            toggle("Questions", .question)
            toggle("Finished turns", .completed)
            toggle("Failed turns", .failed)
          } header: {
            Text("Notify when")
          } footer: {
            Text(
              """
              Approve needs Face ID, Touch ID or your passcode. Omnigent checks that a request \
              is still waiting before it answers. Notifications arrive while Omnigent is open or \
              recently used, and from periodic background checks; instant alerts while it is \
              closed need server push.
              """)
          }
          if let error = supervision.lastError {
            Section("Last problem") {
              Text(error).font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("notifications.last-error")
            }
          }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
              .accessibilityIdentifier("notifications-done")
          }
        }
        .task { await supervision.refreshAuthorization() }
      }
      .accessibilityIdentifier("notification-settings")
    }

    private func toggle(_ title: String, _ kind: SupervisionKind) -> some View {
      Toggle(
        title,
        isOn: Binding(
          get: { supervision.preferences.isEnabled(kind) },
          set: { supervision.preferences.set(kind, enabled: $0) })
      )
      .accessibilityIdentifier("notifications.\(kind.rawValue)")
    }

    private var permission: String {
      switch supervision.authorization {
      case .notDetermined: "Not requested"
      case .denied: "Off in Settings"
      case .authorized: "Allowed"
      case .provisional: "Delivered quietly"
      case .ephemeral: "Allowed for now"
      @unknown default: "Unknown"
      }
    }
  }
#endif

import SwiftUI

@main
@MainActor
struct NativeLabApp: App {
  @UIApplicationDelegateAdaptor(NativeNotificationAppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      NativeLabRootView()
        .environmentObject(model)
        .tint(.primary)
        .onChange(of: scenePhase) { _, phase in
          if phase == .active {
            Task { await model.foregroundRefresh() }
          } else if phase == .background {
            model.flushPersistence()
            Task { await model.suspendLiveConnection() }
          }
        }
    }
  }
}

private struct NativeLabRootView: View {
  @EnvironmentObject private var model: AppModel
  @State private var hasOpenedDemo = false
  @State private var isEditingServerURL = false
  @ObservedObject private var notifications = NativeNotificationController.shared

  var body: some View {
    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
      ProcessInfo.processInfo.arguments.contains("--ui-test-upload-fixtures")
    {
      AttachmentUploadFixtureView()
    } else if hasOpenedDemo {
      WorkspaceView()
    } else {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            if let route = notifications.pendingRoute {
              Text(
                "A session notification is waiting. Connect to \(route.scope.serverURL) as \(route.scope.userID) to open it."
              )
              .font(.callout)
              .accessibilityIdentifier("notification-awaiting-connection")
            }
            Image(systemName: "bubble.left.and.bubble.right.fill")
              .font(.largeTitle)
              .foregroundStyle(.tint)
              .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
              Text("Omni, on the go.")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
              Text("A little space for your next big idea.")
                .font(.title2)
              Text(
                "Connect to your Omnigent server, or explore an offline sample workspace."
              )
              .foregroundStyle(.secondary)
            }

            LocalServerConnectionControls(
              onConnected: { hasOpenedDemo = true },
              onEditingChanged: { isEditingServerURL = $0 }
            )
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))

          }
          .padding(24)
          .frame(maxWidth: 600, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
          if !isEditingServerURL {
            Button {
              Task {
                await model.useDemo()
                hasOpenedDemo = true
              }
            } label: {
              Text("Open sample workspace")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("open-demo")
            .padding(20)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .background(.bar)
          }
        }
        .navigationTitle("Welcome")
        .navigationBarTitleDisplayMode(.inline)
      }
    }
  }
}

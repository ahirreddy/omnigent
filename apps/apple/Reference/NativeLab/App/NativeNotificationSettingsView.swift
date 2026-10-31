import SwiftUI

struct NativeNotificationSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var notifications = NativeNotificationController.shared

  var body: some View {
    Section("Notifications") {
      Text(notifications.status)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("notification-status")
      if model.isLive {
        NavigationLink("Sessions for alerts (\(notifications.selectedSessionIDs.count))") {
          List {
            Section {
              ForEach(model.notificationSessions) { session in
                Toggle(
                  session.title,
                  isOn: Binding(
                    get: { notifications.selectedSessionIDs.contains(session.id) },
                    set: { enabled in
                      var ids = Set(notifications.selectedSessionIDs)
                      if enabled { ids.insert(session.id) } else { ids.remove(session.id) }
                      Task { await notifications.updateSessionIDs(Array(ids)) }
                    })
                )
                .disabled(
                  !notifications.selectedSessionIDs.contains(session.id)
                    && notifications.selectedSessionIDs.count >= 500)
              }
            } footer: {
              Text(
                "Choose owned sessions for approval, question and completion alerts. The server checks access again before delivery."
              )
            }
            if !notifications.selectedSessionIDs.isEmpty {
              Button("Turn off all session alerts") {
                Task { await notifications.updateSessionIDs([]) }
              }
            }
          }
          .navigationTitle("Session alerts")
          .task { await model.refreshInbox() }
        }
        .accessibilityIdentifier("notification-sessions")
      }
      if notifications.permission == .denied {
        Button("Open iOS notification settings") {
          if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
          }
        }
      } else if notifications.permission == .notDetermined || notifications.permission == .unknown {
        Button("Allow notifications") {
          Task { await notifications.requestPermission() }
        }
        .accessibilityIdentifier("notification-permission")
      } else {
        Label("iOS notification permission granted", systemImage: "checkmark.circle")
      }
      Text(
        "Background alerts require server push. An open session or local notification cannot keep the app running after iOS suspends it."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .task { await notifications.refreshPermission() }
  }
}

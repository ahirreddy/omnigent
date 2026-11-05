// Settings › General › Updates for the Developer ID edition, over Sparkle's own preferences.
// Inert without Sparkle, like `SparkleUpdater`.
#if canImport(Sparkle)
  public import SwiftUI

  /// Automatic checks, automatic install on quit and Check Now, as the web's desktop Updates
  /// section (its "Automatic" and "Manual only" modes, and "Install downloaded updates on next
  /// quit"), stored by Sparkle.
  public struct UpdateSettingsSection: View {
    private let updater: SparkleUpdater
    private let issue: String?
    @State private var checksAutomatically: Bool
    @State private var downloadsAutomatically: Bool

    /// Creates the section.
    /// - Parameters:
    ///   - updater: The app's updater.
    ///   - issue: Why automatic updates are off this run, when the updater could not start.
    public init(updater: SparkleUpdater, issue: String?) {
      self.updater = updater
      self.issue = issue
      _checksAutomatically = State(initialValue: updater.automaticallyChecksForUpdates)
      _downloadsAutomatically = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    /// The section.
    public var body: some View {
      Section {
        Toggle(isOn: $checksAutomatically) {
          Text("Check for updates automatically")
          Text("Omnigent asks before installing an update it finds.")
        }
        .accessibilityIdentifier("settings.updates.automatic-checks")
        Toggle(isOn: $downloadsAutomatically) {
          Text("Install downloaded updates on next quit")
          Text("Updates download in the background and install when you quit Omnigent.")
        }
        .disabled(!checksAutomatically || !updater.allowsAutomaticUpdates)
        .accessibilityIdentifier("settings.updates.auto-install")
        LabeledContent {
          Button("Check Now") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
            .accessibilityIdentifier("settings.updates.check-now")
        } label: {
          Text("Last checked")
          Text(updater.lastUpdateCheckDate?.formatted(.relative(presentation: .named)) ?? "Never")
        }
        if let issue {
          Label(issue, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings.updater-issue")
        }
      } header: {
        Text("Updates")
      }
      .onChange(of: checksAutomatically) { _, value in
        if updater.automaticallyChecksForUpdates != value {
          updater.automaticallyChecksForUpdates = value
        }
      }
      .onChange(of: downloadsAutomatically) { _, value in
        if updater.automaticallyDownloadsUpdates != value {
          updater.automaticallyDownloadsUpdates = value
        }
      }
    }
  }
#endif

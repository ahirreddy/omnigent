public import SwiftUI

/// One harness in the import review.
nonisolated public struct ImportReviewHarnessState: Hashable, Sendable, Identifiable {
  /// The harness (`claude-native`).
  public var id: String
  /// "Claude Code".
  public var label: String
  /// Where its credential comes from ("Signed in"); `nil` without one.
  public var credential: String?
  /// Its MCP servers.
  public var mcpServers: [String]
  /// Its skills.
  public var skills: [String]
  /// Its plugins.
  public var plugins: [String]
  /// Why some of it couldn't be read.
  public var notices: [String]

  /// Creates a harness.
  public init(
    id: String, label: String, credential: String?, mcpServers: [String], skills: [String],
    plugins: [String], notices: [String] = []
  ) {
    self.id = id
    self.label = label
    self.credential = credential
    self.mcpServers = mcpServers
    self.skills = skills
    self.plugins = plugins
    self.notices = notices
  }
}

/// Where the import review stands.
nonisolated public enum ImportReviewPhase: Hashable, Sendable {
  /// The host isn't online yet.
  case connecting
  /// Its harnesses are being read.
  case checking
  /// What the host's harnesses carry over.
  case loaded(hostName: String, harnesses: [ImportReviewHarnessState])
  /// The read failed.
  case failed(String)
}

/// What a newly connected host carries over (the web's `ImportContextModal`): per harness, the
/// credential it found and its MCP servers, skills and plugins. Review only: nothing to choose.
public struct ImportReviewView: View {
  private let phase: ImportReviewPhase
  private let seeMore: (() -> Void)?
  private let confirm: () -> Void
  @State private var tab: String?

  /// Creates the review.
  /// - Parameters:
  ///   - phase: Where it stands.
  ///   - seeMore: Opens Settings › Harnesses; `nil` hides See More.
  ///   - confirm: Closes the review.
  public init(phase: ImportReviewPhase, seeMore: (() -> Void)?, confirm: @escaping () -> Void) {
    self.phase = phase
    self.seeMore = seeMore
    self.confirm = confirm
  }

  /// The view.
  public var body: some View {
    NavigationStack {
      content
        .navigationTitle("Your setup is ready")
        .toolbar {
          if let seeMore {
            ToolbarItem(placement: .cancellationAction) { Button("See More", action: seeMore) }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Confirm", action: confirm).accessibilityIdentifier("import-review-confirm")
          }
        }
    }
    #if os(macOS)
      .frame(minWidth: 460, minHeight: 380)
    #endif
    .accessibilityIdentifier("import-review")
  }

  @ViewBuilder private var content: some View {
    switch phase {
    case .connecting:
      ProgressView("Connecting this Mac\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .checking:
      ProgressView("Checking your harnesses\u{2026}")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ContentUnavailableView(
        "Couldn\u{2019}t Read Your Harnesses", systemImage: "exclamationmark.triangle",
        description: Text(message))
    case .loaded(_, let harnesses) where harnesses.isEmpty:
      ContentUnavailableView(
        "Nothing to import from your harnesses", systemImage: "tray")
    case .loaded(let host, let harnesses):
      loaded(host: host, harnesses: harnesses)
    }
  }

  private func loaded(host: String, harnesses: [ImportReviewHarnessState]) -> some View {
    let shown = harnesses.first { $0.id == tab } ?? harnesses.first
    return Form {
      Section {
        Text(
          host.isEmpty
            ? "Found in your harnesses. These carry over automatically."
            : "Found in your harnesses on \(host). These carry over automatically."
        )
        .foregroundStyle(.secondary)
        if harnesses.count > 1 {
          Picker("Harness", selection: Binding(get: { shown?.id }, set: { tab = $0 })) {
            ForEach(harnesses) { Text($0.label).tag(Optional($0.id)) }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
      }
      if let shown { harness(shown) }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private func harness(_ harness: ImportReviewHarnessState) -> some View {
    if let credential = harness.credential {
      Section {
        LabeledContent("Credential") {
          HStack(spacing: Theme.Spacing.small) {
            Text(credential)
            Label("Detected", systemImage: "checkmark.circle.fill")
              .labelStyle(.titleAndIcon)
              .foregroundStyle(Theme.success)
          }
        }
      }
    }
    if harness.mcpServers.isEmpty, harness.skills.isEmpty, harness.plugins.isEmpty {
      Section { Text("No MCPs, skills, or plugins detected").foregroundStyle(.secondary) }
    }
    list("MCPs", harness.mcpServers, systemImage: "server.rack")
    list("Skills", harness.skills, systemImage: "wand.and.stars")
    list("Plugins", harness.plugins, systemImage: "puzzlepiece.extension")
    if !harness.notices.isEmpty {
      Section {
        ForEach(harness.notices, id: \.self) { notice in
          Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private func list(_ title: String, _ items: [String], systemImage: String)
    -> some View
  {
    if !items.isEmpty {
      Section {
        ForEach(items, id: \.self) { Label($0, systemImage: systemImage) }
      } header: {
        Text("\(title) \u{00B7} \(items.count)")
      }
    }
  }
}

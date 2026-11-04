public import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
public import SwiftUI
import UniformTypeIdentifiers

/// Connects this Mac as a host for a server ("Use this machine"). The app sets it where the
/// edition can run the CLI; it returns a status line for the Connect a Host sheet.
public struct UseThisMachineAction: Sendable {
  private let run: @MainActor @Sendable (URL) async -> String?

  /// Creates the action.
  /// - Parameter run: Starts hosting for the server URL; returns a status line.
  public init(_ run: @escaping @MainActor @Sendable (URL) async -> String?) {
    self.run = run
  }

  /// Starts hosting for `serverURL`.
  @MainActor public func callAsFunction(_ serverURL: URL) async -> String? {
    await run(serverURL)
  }
}

extension EnvironmentValues {
  /// Connects this Mac as a host; `nil` where the edition cannot.
  @Entry public var useThisMachine: UseThisMachineAction?
}

extension NewSessionContainer {
  /// The amber "not ready" notice: the selected agent's harness reports a readiness that is
  /// not ready on an online host (offline hosts and unknown agents say so in the context row).
  func harnessNotice(_ catalog: OmnigentCoreFFI.CreationCatalog?) -> (text: String, name: String)? {
    guard !isSandbox, let catalog, let agent = selectedAgent,
      let host = catalog.hosts.first(where: { $0.hostId == selection.hostId }),
      host.status == "online", host.sandboxProvider == nil,
      creationUnavailableReason(
        catalog: catalog, agentId: selection.agentId, hostId: selection.hostId) != nil
    else { return nil }
    return ("\(agent.name) isn't ready on \(host.name).", agent.name)
  }

  /// The setup sheet's harness: the readiness key the host reports for the selected agent.
  var setupHarness: String? {
    guard let agent = selectedAgent else { return nil }
    return agent.harness ?? (agent.harnessId.isEmpty ? nil : agent.harnessId)
  }

  /// Plan mode at launch: Claude Code's `plan` approval mode, or a Codex launch label.
  func planToggle(_ creation: CreationStore) -> (@MainActor () -> Void)? {
    guard !isSandbox, let agent = selectedAgent, let catalog = creation.catalog.value else {
      return nil
    }
    if creationApprovalModeMenu(agent: agent)?.options.contains(where: { $0.value == "plan" })
      == true
    {
      return {
        selection.approvalMode = selection.approvalMode == "plan" ? nil : "plan"
      }
    }
    guard creationStartsInPlanMode(catalog: catalog, agentId: agent.id) else { return nil }
    return { selection.planMode.toggle() }
  }

  var isPlanOn: Bool {
    selection.approvalMode == "plan" || selection.planMode
  }

  /// The staged files as composer chips.
  func attachmentChips(_ creation: CreationStore) -> [OmnigentUIComponents.DraftAttachment] {
    creation.attachments.map {
      OmnigentUIComponents.DraftAttachment(
        id: $0.id.uuidString, title: $0.filename,
        kind: UTType(mimeType: $0.mediaType ?? "")?.conforms(to: .image) == true ? .image : .file,
        byteCount: Int64($0.data.count))
    }
  }

  /// Reads picked or dropped files and stages them; a file that cannot be read is reported.
  func stage(_ inputs: [ComposerAttachmentInput], in creation: CreationStore) {
    for input in inputs {
      switch input {
      case .file(let url):
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
          let data = try Data(contentsOf: url)
          creation.stageAttachment(
            PendingAttachment(
              filename: url.lastPathComponent,
              mediaType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
              data: data))
        } catch {
          attachmentError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
      case .data(let data, let name, let type):
        creation.stageAttachment(
          PendingAttachment(filename: name, mediaType: type.preferredMIMEType, data: data))
      }
    }
  }

  /// "Import your recent sessions" while the server has none: the server's import page (the
  /// native Settings window has no import section yet).
  func importSessions(_ openURL: OpenURLAction) -> (@MainActor () -> Void)? {
    let list = connection.sessionList
    guard list.isLoaded, list.sessionsByID.isEmpty,
      let url = URL(string: serverURLText)?.appending(path: "settings/import")
    else { return nil }
    return { openURL(url) }
  }

  /// The server URL a new host connects to.
  var serverURLText: String {
    connection.connectedServer?.baseUrl ?? ""
  }
}

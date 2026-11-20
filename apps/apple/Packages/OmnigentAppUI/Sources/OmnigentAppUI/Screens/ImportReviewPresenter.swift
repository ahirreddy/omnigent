import Foundation
public import Observation
import OmnigentCoreFFI
public import OmnigentStores
import OmnigentUIComponents
public import SwiftUI

/// Servers whose desktop onboarding just connected this Mac as a host, so their window reviews
/// what the host carries over (the web's `requestImportReview` after onboarding).
@MainActor
@Observable
public final class ImportReviewRequests {
  /// The app's requests.
  public static let shared = ImportReviewRequests()
  private var servers: Set<String> = []

  /// Asks `serverURL`'s window for the review.
  public func request(_ serverURL: String) { servers.insert(Self.key(serverURL)) }

  /// Whether `serverURL`'s window owes a review.
  public func isRequested(_ serverURL: String) -> Bool { servers.contains(Self.key(serverURL)) }

  /// The review was shown.
  public func done(_ serverURL: String) { servers.remove(Self.key(serverURL)) }

  private static func key(_ url: String) -> String {
    var key = url.lowercased()
    while key.hasSuffix("/") { key.removeLast() }
    return key
  }
}

/// The review's per-device memory, as the web's `omnigent:imports-reviewed:<host>`: Confirm and
/// closing both count, and a host reviewed here is never reviewed again.
enum ImportReviewMemory {
  static func key(_ hostID: String) -> String { "omnigent:imports-reviewed:\(hostID)" }

  static func isReviewed(_ hostID: String, defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: key(hostID)) != nil
  }

  static func markReviewed(_ hostID: String, defaults: UserDefaults = .standard) {
    defaults.set(Date.now.ISO8601Format(), forKey: key(hostID))
  }
}

extension ImportReviewStore.Phase {
  /// The review's view state.
  var view: ImportReviewPhase {
    switch self {
    case .connecting: .connecting
    case .checking: .checking
    case .failed(let message): .failed(message)
    case .loaded(let review):
      .loaded(
        hostName: review.hostName,
        harnesses: review.harnesses.map {
          ImportReviewHarnessState(
            id: $0.harness, label: $0.label, credential: $0.credential,
            mcpServers: $0.mcpServers, skills: $0.skills, plugins: $0.plugins,
            notices: $0.notices)
        })
    }
  }
}

/// Shows the import review over a server's window when onboarding asked for it, the server has
/// `import_review` on, and this Mac's host wasn't reviewed here before.
struct ImportReviewPresenter: ViewModifier {
  let connection: ConnectionStore
  @State private var store: ImportReviewStore?
  @Environment(\.openSettingsAt) private var openSettingsAt

  private var serverURL: String { connection.connectedServer?.baseUrl ?? "" }

  private var isDue: Bool {
    connection.pages?.offered?.importReview == true
      && ImportReviewRequests.shared.isRequested(serverURL)
  }

  func body(content: Content) -> some View {
    content
      .onChange(of: isDue, initial: true) { _, due in
        guard due, store == nil else { return }
        guard let hostID = connection.sessionList.thisMachineHostID(),
          !ImportReviewMemory.isReviewed(hostID)
        else {
          ImportReviewRequests.shared.done(serverURL)
          return
        }
        store = connection.importReview(hostID: hostID)
      }
      .sheet(
        isPresented: Binding(get: { store != nil }, set: { if !$0 { close() } })
      ) {
        if let store {
          ImportReviewView(
            phase: store.phase.view,
            seeMore: openSettingsAt.map { open in
              {
                close()
                open(.server(url: serverURL, pane: .harnesses))
              }
            },
            confirm: close
          )
          .task { await store.load() }
        }
      }
  }

  private func close() {
    if let store { ImportReviewMemory.markReviewed(store.hostID) }
    ImportReviewRequests.shared.done(serverURL)
    store = nil
  }
}

extension View {
  /// Reviews what this Mac's new host carries over, once onboarding asks.
  /// - Parameter connection: The server's connection.
  /// - Returns: The view.
  public func importReview(_ connection: ConnectionStore) -> some View {
    modifier(ImportReviewPresenter(connection: connection))
  }
}

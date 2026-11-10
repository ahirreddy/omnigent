import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The drafts of side chats whose first message has not created them yet, by tab. Not saved: a
/// restored new side chat starts empty.
@Observable
final class SideChatDrafts {
  struct Draft: Equatable {
    var text = ""
    var isStarting = false
    var failure: String?
  }

  private(set) var drafts: [String: Draft] = [:]

  func draft(_ tabID: String) -> Draft { drafts[tabID] ?? Draft() }

  func update(_ tabID: String, _ change: (inout Draft) -> Void) {
    var draft = draft(tabID)
    change(&draft)
    if drafts[tabID] != draft { drafts[tabID] = draft }
  }

  func remove(_ tabID: String) {
    if drafts[tabID] != nil { drafts[tabID] = nil }
  }
}

/// Numbers a session's side chats in strip order, as the web's "Side chat 1", "Side chat 2".
struct SideChatNumbers {
  private var counts: [String: Int] = [:]

  mutating func next(_ parentID: String) -> String {
    let number = counts[parentID, default: 0] + 1
    counts[parentID] = number
    return "\(TabKind.sideChat.label) \(number)"
  }
}

/// A new side chat's tab: its draft, until the first send creates the side chat and the tab
/// shows it (web `startPendingSideChat`).
struct PendingSideChatTab: View {
  let session: ServerSession
  let tabID: String
  let parentID: String
  let fail: @MainActor (String) -> Void

  var body: some View {
    let drafts = session.sideChatDrafts
    let draft = drafts.draft(tabID)
    let tabID = tabID
    PendingSideChatView(
      draft: Binding(
        get: { drafts.draft(tabID).text },
        set: { text in drafts.update(tabID) { $0.text = text } }),
      parent: CreatingSession(
        id: parentID, title: session.connection.sessionList.sessionWithoutActivity(parentID)?.title),
      isStarting: draft.isStarting, failure: draft.failure,
      send: { Self.start(session: session, tabID: tabID, parentID: parentID, fail: fail) },
      dismissFailure: { drafts.update(tabID) { $0.failure = nil } },
      openParent: { session.tabs.showChat($0) })
  }

  /// Creates the side chat with the tab's draft as its first message, then shows it in the tab.
  /// A failure before the side chat exists keeps the draft for another try; once it exists, an
  /// unsent first message waits in the side chat's composer.
  static func start(
    session: ServerSession, tabID: String, parentID: String,
    fail: @escaping @MainActor (String) -> Void
  ) {
    let drafts = session.sideChatDrafts
    let text = drafts.draft(tabID).text
    guard !drafts.draft(tabID).isStarting,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    guard let parent = session.connection.conversations[parentID] else {
      drafts.update(tabID) { $0.failure = "The conversation isn't open." }
      return
    }
    drafts.update(tabID) {
      $0.isStarting = true
      $0.failure = nil
    }
    Task {
      let created: CreatedSideChat
      do throws(CoreError) {
        created = try await parent.tools.createSideChat(text: text)
      } catch {
        drafts.update(tabID) {
          $0.isStarting = false
          $0.failure = "Couldn't start a side chat for this session: \(error.message)"
        }
        return
      }
      if case .failed(let error) = created.firstMessage {
        parent.composer.seedDraft(text, forSession: created.sessionId)
        fail("The side chat started, but its first message wasn't sent: \(error.message)")
      }
      drafts.remove(tabID)
      session.tabs.replace(
        tabID, with: .sideChatSession(parentID: parentID, childID: created.sessionId))
    }
  }
}

extension WindowTabs {
  /// Opens a new side chat of `sessionID` with `draft` in its composer, in the tab `id` when it
  /// is open, else a new one. With `sendNow` (a typed `/side <question>`), the draft is sent.
  func openPendingSideChat(
    _ sessionID: String, draft: String, sendNow: Bool, replacing id: String? = nil
  ) {
    let content = AppTabContent.sideChatSession(parentID: sessionID, childID: nil)
    guard let tab = show(content, in: sessionID, replacing: id) else { return }
    session.sideChatDrafts.update(tab.id) { $0.text = draft }
    if sendNow {
      PendingSideChatTab.start(session: session, tabID: tab.id, parentID: sessionID, fail: fail)
    }
  }
}

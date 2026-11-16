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
    /// The first message, while the session's own agent forks the side chat for it.
    var asked: String?
    /// The agent has taken longer than ``ForkedSideChats/patience`` to report the fork.
    var isLate = false

    /// The side chat did not start: the message is back in the field, with the reason.
    mutating func giveBack(_ reason: String) {
      if let asked {
        text = text.isEmpty ? asked : "\(asked)\n\n\(text)"
      }
      asked = nil
      isStarting = false
      isLate = false
      failure = reason
    }
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
      isStarting: draft.isStarting, failure: draft.failure, asked: draft.asked,
      isLate: draft.isLate,
      send: { Self.start(session: session, tabID: tabID, parentID: parentID, fail: fail) },
      dismissFailure: { drafts.update(tabID) { $0.failure = nil } },
      openParent: { session.tabs.showChat($0) })
  }

  /// Sends the tab's draft as the side chat's first message, then shows the side chat in the
  /// tab. Where the server forks it, a failure before it exists keeps the draft for another try
  /// and an unsent first message waits in its composer. Where the session's own agent forks it,
  /// the tab shows the question and waits its turn for the child the session reports.
  static func start(
    session: ServerSession, tabID: String, parentID: String,
    fail: @escaping @MainActor (String) -> Void
  ) {
    let drafts = session.sideChatDrafts
    let text = drafts.draft(tabID).text
    guard !drafts.draft(tabID).isStarting,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    guard let parent = session.connection.openConversation(parentID) else {
      drafts.update(tabID) { $0.failure = "The conversation isn't open." }
      return
    }
    let harness = parent.header?.settings?.harness
    let asksAgent = sideChatStart(harness: harness, quote: nil).delivery == .sendToParent
    drafts.update(tabID) {
      $0.isStarting = true
      $0.isLate = false
      $0.failure = nil
      if asksAgent {
        $0.asked = text
        $0.text = ""
      }
    }
    // The fork is reported with nothing to pair it on, so the tab queues before the request.
    let wait = asksAgent ? awaitFork(of: parent, session: session, tabID: tabID) : nil
    Task {
      let started: StartedSideChat
      do throws(CoreError) {
        started = try await parent.tools.startSideChat(text: text, harness: harness)
      } catch {
        if let wait { session.forkedSideChats.cancel(wait, of: parentID) }
        drafts.update(tabID) {
          $0.giveBack("Couldn't start a side chat for this session: \(error.message)")
        }
        return
      }
      // An agent that was asked to fork reports the side chat itself: the queued wait shows it.
      guard case .created(let created) = started else { return }
      if case .failed(let error) = created.firstMessage {
        parent.composer.seedDraft(text, forSession: created.sessionId)
        fail("The side chat started, but its first message wasn't sent: \(error.message)")
      }
      drafts.remove(tabID)
      session.tabs.replace(
        tabID, with: .sideChatSession(parentID: parentID, childID: created.sessionId))
    }
  }

  /// Queues the tab for the next child `parent` reports: the tab then shows that side chat,
  /// however long the agent takes, and says so once it is late. A session that closes first
  /// gives the question back with the reason.
  private static func awaitFork(
    of parent: ConversationStore, session: ServerSession, tabID: String
  ) -> ForkedSideChats.WaitID {
    let drafts = session.sideChatDrafts
    let parentID = parent.sessionID
    return session.forkedSideChats.awaitFork(
      of: parent,
      late: { drafts.update(tabID) { $0.isLate = true } },
      gaveUp: {
        drafts.update(tabID) {
          $0.giveBack(
            "The agent didn't report a side chat for this question. Check it is running, then send again."
          )
        }
      },
      forked: { childID in
        // Words typed while waiting go to the side chat's composer.
        let typed = drafts.draft(tabID).text
        if !typed.isEmpty { parent.composer.seedDraft(typed, forSession: childID) }
        drafts.remove(tabID)
        session.tabs.bindSideChat(tabID, to: childID, of: parentID)
      })
  }
}

extension SessionTabGroups {
  /// Shows the side chat `childID` in the new side chat's tab `tabID`. When another tab of the
  /// strip already shows it, that one is selected and the new tab closes. A tab closed while it
  /// waited leaves the side chat a tab of its own, behind the selected one.
  func bindSideChat(_ tabID: String, to childID: String, of parentID: String) {
    guard let (ownerID, _) = tab(tabID) else {
      openChild(childID, in: parentID, isSideChat: true, name: nil, select: false)
      return
    }
    let group = group(ownerID)
    if let shown = group.tabs.first(where: { $0.content.conversationID == childID }) {
      let wasSelected = group.selectedID == tabID
      group.close(tabID)
      if wasSelected { group.select(shown.id) }
    } else {
      group.replace(tabID, with: .sideChatSession(parentID: parentID, childID: childID))
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

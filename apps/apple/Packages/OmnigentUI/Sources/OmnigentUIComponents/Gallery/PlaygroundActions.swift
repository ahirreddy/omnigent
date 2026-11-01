import Foundation
import SwiftUI

// The playground model's actions, which mutate the sample state like a store would.
extension PlaygroundModel {
  var conversationActions: ConversationActions {
    ConversationActions(
      loadOlder: { [weak self] in self?.conversation.hasMoreHistory = false },
      openSession: { [weak self] id in self?.selection = .session(id) },
      openAttachment: { _ in }, openURL: { url in Self.open(url) },
      respond: { [weak self] card, response in self?.respond(card, response) },
      validateForm: PreviewData.validate,
      dismissError: { [weak self] in self?.conversation.errorMessage = nil },
      retry: { [weak self] in self?.conversation.errorMessage = nil },
      forkFrom: { [weak self] row in
        guard let self else { return }
        fork = PreviewData.fork
        fork?.kind = .fromMessage(rowID: row.id)
      },
      messageURL: {
        URL(string: "https://omnigent.example.com/c/\(PreviewData.sessionID)?message=\($0.id)")
      },
      resume: { [weak self] in self?.conversation.terminal = .resuming },
      share: {})
  }

  var composerActions: ComposerActions {
    ComposerActions(
      send: { [weak self] in self?.send() },
      interrupt: { [weak self] in self?.interrupt() },
      addAttachments: { [weak self] inputs in self?.add(inputs) },
      removeAttachment: { [weak self] attachment in
        self?.composer.attachments.removeAll { $0.id == attachment.id }
      },
      selectModel: { [weak self] id in self?.composer.configuration?.selectedModelId = id },
      selectEffort: { [weak self] effort in self?.composer.configuration?.selectedEffort = effort },
      selectAgent: { [weak self] id in self?.composer.configuration?.selectedAgentId = id },
      acknowledgeUncertainDelivery: { [weak self] in self?.composer.delivery = .idle },
      dismissDeliveryError: { [weak self] in self?.composer.delivery = .idle },
      extras: ComposerExtraActions(
        selectHost: { [weak self] host in self?.composer.hosts?.selectedID = host.id },
        selectApprovalMode: { [weak self] mode in self?.composer.approvalModes?.selectedID = mode.id
        },
        dictate: {},
        sendQueuedNow: { [weak self] message in
          self?.composer.queue.removeAll { $0.id == message.id }
        },
        removeQueued: { [weak self] message in
          self?.composer.queue.removeAll { $0.id == message.id }
        }))
  }

  var startActions: ComposerActions {
    ComposerActions(
      send: { [weak self] in self?.start() },
      addAttachments: { _ in },
      selectModel: { [weak self] id in self?.startComposer.configuration?.selectedModelId = id },
      selectEffort: { [weak self] effort in
        self?.startComposer.configuration?.selectedEffort = effort
      },
      extras: ComposerExtraActions(
        selectHost: { [weak self] host in self?.startComposer.hosts?.selectedID = host.id },
        selectApprovalMode: { [weak self] mode in
          self?.startComposer.approvalModes?.selectedID = mode.id
        },
        dictate: {},
        selectDirectory: { [weak self] path in self?.startComposer.tray?.directory = path },
        openFolder: {},
        selectWorktree: { [weak self] name in
          self?.startComposer.tray?.worktree = name ?? "No worktree"
        },
        newSideChat: {}, setGoal: {}, togglePlan: {}))
  }

  var sidebarActions: SidebarActions {
    SidebarActions(
      sessions: SessionListActions(
        setPinned: { [weak self] session, pinned in
          self?.updateSession(session.id) { $0.isPinned = pinned }
          self?.sidebar.undo = UndoBanner(id: UUID().uuidString, kind: pinned ? .pinned : .unpinned)
        },
        setArchived: { [weak self] session, archived in
          self?.updateSession(session.id) { $0.isArchived = archived }
          if archived {
            self?.sidebar.undo = UndoBanner(id: UUID().uuidString, kind: .archived(count: 1))
          }
        },
        rename: { [weak self] session, title in self?.updateSession(session.id) { $0.title = title }
        },
        setUnread: { [weak self] session, unread in
          if unread {
            self?.sidebar.list.unreadIds.insert(session.id)
          } else {
            self?.sidebar.list.unreadIds.remove(session.id)
          }
        },
        share: { _ in }, fork: { [weak self] _ in self?.fork = PreviewData.fork },
        moveToProject: { _, _ in }, stop: { _ in }, delete: { _ in }, leave: { _ in },
        webURL: { URL(string: "https://omnigent.example.com/c/\($0.id)") },
        newSession: { [weak self] in self?.selection = .newSession },
        retry: { [weak self] in self?.sidebar.list.phase = .loaded }),
      setDisplay: { [weak self] options in self?.sidebar.display = options },
      setQuickFilter: { [weak self] filter in self?.sidebar.quickFilter = filter },
      switchServer: { [weak self] server in self?.sidebar.currentServerID = server.id },
      addServer: {}, openServerSettings: { [weak self] in self?.scenario = .serverSettings },
      undo: { [weak self] _ in self?.sidebar.undo = nil },
      dismissUndo: { [weak self] in self?.sidebar.undo = nil },
      viewArchived: { [weak self] in self?.sidebar.display.show = .archived })
  }

  var shareActions: ShareActions {
    ShareActions(
      setGeneralAccess: { [weak self] access in self?.share.generalAccess = access },
      setWorkspaceFiles: { [weak self] isOn in self?.share.workspaceFiles = isOn },
      addGrant: { [weak self] principal, role in
        self?.share.grants.append(
          ShareGrant(id: UUID().uuidString, principal: principal, role: role))
      },
      setRole: { [weak self] grant, role in
        guard let index = self?.share.grants.firstIndex(of: grant) else { return }
        self?.share.grants[index].role = role
      },
      removeGrant: { [weak self] grant in self?.share.grants.removeAll { $0.id == grant.id } })
  }

  var forkActions: ForkActions {
    ForkActions(
      fork: { [weak self] _, _, _ in self?.fork = nil }, cancel: { [weak self] in self?.fork = nil }
    )
  }

  var inboxActions: InboxActions {
    InboxActions(
      open: { [weak self] item in self?.selection = .session(item.sessionId) },
      markRead: { [weak self] item in
        guard let index = self?.inbox.items.firstIndex(where: { $0.id == item.id }) else { return }
        self?.inbox.items[index].isUnread = false
      },
      reply: { _, _ in }, respond: { _, _ in })
  }
}

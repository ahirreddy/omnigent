import SwiftUI

/// The row menu in the web's order, shared by the context menu and the hover menu.
struct SessionRowMenu {
  let session: SessionSummary
  let isUnread: Bool
  let isShared: Bool
  let pinLimitReached: Bool
  let projects: [SessionProject]
  let actions: SessionListActions
  let rename: () -> Void
  let confirmDelete: () -> Void
  let confirmLeave: () -> Void
  /// Asks before stopping the session.
  let confirmStop: () -> Void
  /// The project it is filed in, if any.
  var project: SessionProject?
  /// Asks for a name and moves the session into a new project; `nil` hides the item.
  var newProject: (() -> Void)?

  /// Hover buttons are Mac-only; touch uses the context menu and swipe actions.
  var showsHoverActions: Bool {
    #if os(macOS)
      offersPin || (actions.setArchived != nil && session.canArchive)
    #else
      false
    #endif
  }

  /// Pin or Unpin is offered; archived rows omit it, since archive outranks pin (as the web).
  var offersPin: Bool { actions.setPinned != nil && session.canPin && !session.isArchived }

  func togglePin() {
    guard let setPinned = actions.setPinned, offersPin else { return }
    if !session.isPinned, pinLimitReached { return }
    setPinned(session, !session.isPinned)
  }

  /// The most used row actions as VoiceOver actions; the rest stay in the context menu.
  @ViewBuilder var accessibilityItems: some View {
    if offersPin, session.isPinned || !pinLimitReached {
      Button(session.isPinned ? "Unpin" : "Pin") { togglePin() }
    }
    if let setUnread = actions.setUnread {
      Button(isUnread ? "Mark as read" : "Mark as unread") { setUnread(session, !isUnread) }
    }
    if let setArchived = actions.setArchived, session.canArchive {
      Button(session.isArchived ? "Unarchive" : "Archive") {
        setArchived(session, !session.isArchived)
      }
    }
    if actions.rename != nil, session.canRename {
      Button("Rename", action: rename)
    }
  }

  @ViewBuilder var items: some View {
    if offersPin {
      Button(
        session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin"
      ) {
        togglePin()
      }
      .disabled(!session.isPinned && pinLimitReached)
      .help(!session.isPinned && pinLimitReached ? "Unpin a session first" : "")
    }
    // Sharing is the owner's, as on the web.
    if let share = actions.share, !isShared {
      Button("Share", systemImage: "person.badge.plus") { share(session) }
    }
    if let fork = actions.fork {
      Button("Fork", systemImage: "arrow.triangle.branch") { fork(session) }
    }
    if actions.rename != nil, session.canRename {
      Button("Rename\u{2026}", systemImage: "pencil", action: rename)
    }
    if let setUnread = actions.setUnread {
      Button(
        isUnread ? "Mark as read" : "Mark as unread",
        systemImage: isUnread ? "envelope.open" : "envelope.badge"
      ) {
        setUnread(session, !isUnread)
      }
    }
    // Filing is owner-only, as on the web.
    if let move = actions.moveToProject, !isShared, !projects.isEmpty || newProject != nil {
      // "Add to project" until it is filed, then "Move session", as the web.
      Menu(project == nil ? "Add to project" : "Move session", systemImage: "folder") {
        ForEach(projects) { target in
          Button(target.name) { move(session, target) }
            .disabled(target.id == project?.id)
        }
        if let newProject {
          if !projects.isEmpty { Divider() }
          Button("New project\u{2026}", systemImage: "folder.badge.plus", action: newProject)
        }
        if project != nil {
          Divider()
          Button("Remove from project") { move(session, nil) }
        }
      }
    }
    // Stop, Archive and Delete end the session's life, below a divider.
    Divider()
    if actions.stop != nil, session.canStop {
      Button("Stop session", systemImage: "stop.circle", action: confirmStop)
        .disabled(isShared)
        .help(isShared ? "Only the owner can stop this session" : "")
    }
    if let setArchived = actions.setArchived, session.canArchive {
      Button(
        session.isArchived ? "Unarchive" : "Archive",
        systemImage: session.isArchived ? "tray.and.arrow.up" : "archivebox"
      ) {
        setArchived(session, !session.isArchived)
      }
    }
    if actions.delete != nil, !isShared {
      Button("Delete\u{2026}", systemImage: "trash", role: .destructive, action: confirmDelete)
    }
    if actions.leave != nil, isShared {
      Button(
        "Leave session\u{2026}", systemImage: "rectangle.portrait.and.arrow.right",
        role: .destructive, action: confirmLeave)
    }
    Divider()
    if let open = actions.openInNewWindow {
      Button("Open in New Window", systemImage: "macwindow.badge.plus") { open(session) }
    }
    // The web's "Open in grid"; archived sessions don't offer it.
    if let split = actions.openInSplit, !session.isArchived {
      Button("Open in Split View", systemImage: "rectangle.split.2x1") { split(session) }
    }
    if let webURL = actions.webURL?(session) {
      ConfirmedCopyButton(
        title: "Copy Link", systemImage: "link", text: webURL.absoluteString,
        confirmation: "Link copied")
    }
    ConfirmedCopyButton(
      title: "Copy Session ID", systemImage: "number", text: session.id,
      confirmation: "Session ID copied")
  }
}

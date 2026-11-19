import SwiftUI

/// A row menu's items as a view of their own. A row's body builds only this value; the items,
/// with what they read (the session's web link, the nests it can join, every project), are built
/// when the menu opens, not for every row the list draws.
struct SessionRowMenuItems: View {
  let menu: SessionRowMenu

  var body: some View {
    menu.items.countsRenders("session row menu")
  }
}

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
  /// Why Share is unavailable; it then shows disabled with the reason.
  var shareUnavailableReason: String?
  /// Its place among its group's rows (Pinned, or a project); `nil` hides Reorder.
  var move: SessionRowMove?
  /// The other nests it can join, one session of each, read when the menu shows.
  var nests: @MainActor () -> [SessionSummary] = { [] }

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

  /// Add nested agent: the owner's, on a session that is not archived (the web's gate).
  var offersNestedAgent: Bool {
    actions.addNestedAgent != nil && !isShared && !session.isArchived
  }

  /// Filing is the owner's; a nested member files with its representative.
  private var offersProjects: Bool {
    actions.moveToProject != nil && !isShared && !session.isNestedMember
      && (!projects.isEmpty || newProject != nil)
  }

  /// An owned, active session moves between nests where the server can: into another where it
  /// adds nested agents, and out of its own.
  private var offersNests: Bool {
    actions.moveToNest != nil && !isShared && !session.isArchived
      && (actions.canJoinNests || session.family != nil)
  }

  @ViewBuilder private var projectItems: some View {
    if let move = actions.moveToProject {
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

  /// The nests it can join, by their representative's title, then Remove from nest.
  @ViewBuilder private func nestItems(
    _ moveToNest: @escaping @MainActor (SessionSummary, SessionSummary?) -> Void
  ) -> some View {
    if actions.canJoinNests {
      let destinations = nests()
      ForEach(destinations) { nest in
        Button(nest.family?.representativeTitle ?? nest.title) { moveToNest(session, nest) }
      }
      if destinations.isEmpty {
        Text("No other nests")
      }
    }
    if session.family != nil {
      if actions.canJoinNests { Divider() }
      Button("Remove from nest", systemImage: "rectangle.portrait.and.arrow.right") {
        moveToNest(session, nil)
      }
    }
  }

  @ViewBuilder var items: some View {
    if offersNestedAgent, let addNestedAgent = actions.addNestedAgent {
      Button("Add nested agent", systemImage: "plus.square.on.square") { addNestedAgent(session) }
      Divider()
    }
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
      ReasonedMenuButton(
        "Share", systemImage: "person.badge.plus", unavailableReason: shareUnavailableReason
      ) { share(session) }
    }
    if let fork = actions.fork {
      ReasonedMenuButton(
        "Fork", systemImage: "arrow.triangle.branch",
        unavailableReason: actions.forkUnavailableReason?(session)
      ) { fork(session) }
    }
    // An automation runs from the owner's own session.
    if let createAutomation = actions.createAutomation, !isShared, !session.isArchived,
      actions.offersCreateAutomation?(session) ?? true
    {
      Button("Create automation", systemImage: "clock.arrow.circlepath") {
        createAutomation(session)
      }
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
    // Moving is owner-only, as on the web; a nested member files with its representative.
    if let moveToNest = offersNests ? actions.moveToNest : nil {
      Menu("Move session", systemImage: "folder") {
        if offersProjects {
          Menu("Projects", systemImage: "folder") { projectItems }
        }
        Menu("Nests", systemImage: "square.on.square") { nestItems(moveToNest) }
      }
    } else if offersProjects {
      // "Add to project" until it is filed, then "Move session", as the web.
      Menu(project == nil ? "Add to project" : "Move session", systemImage: "folder") {
        projectItems
      }
    }
    if let move {
      MoveMenu(title: "Reorder", items: move.rows, id: session.id, save: move.save)
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

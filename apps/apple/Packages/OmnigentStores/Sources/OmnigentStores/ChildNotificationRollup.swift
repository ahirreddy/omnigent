public import OmnigentCoreFFI

/// Rolls sub-agent notifications into their parent, as Warp and the roadmap describe: a child's
/// notification opens the parent (where its requests are answerable), and several from the same
/// parent and kind fold into one ("2 subagents finished"). A child's request still notifies, so
/// blocked child work stays discoverable; it is only routed and grouped.
public struct ChildNotificationRollup: Sendable {
  /// A child's parent, as the session list knows it.
  public struct Parent: Hashable, Sendable {
    /// The parent session.
    public var id: String
    /// Its title, when known.
    public var title: String?

    /// Creates a parent.
    /// - Parameters:
    ///   - id: Parent session id.
    ///   - title: Its title.
    public init(id: String, title: String?) {
      self.id = id
      self.title = title
    }
  }

  private struct Key: Hashable {
    let parent: String
    let kind: NotificationKind
  }

  /// Children folded into each pending parent notification.
  private var children: [Key: [String]] = [:]

  /// Creates an empty rollup.
  public init() {}

  /// Adds `notification` to `pending`, rolled into its parent when it comes from a child.
  /// - Parameters:
  ///   - notification: What the core decided to show.
  ///   - pending: Notifications not yet presented, oldest first.
  ///   - parent: The notified session's parent, or `nil` for a top-level session.
  ///   - childTitle: The child's title, when the notification has none.
  public mutating func add(
    _ notification: AttentionNotification, to pending: inout [AttentionNotification],
    parent: Parent?, childTitle: String? = nil
  ) {
    guard let parent, parent.id != notification.sessionId else {
      pending.append(notification)
      return
    }
    let key = Key(parent: parent.id, kind: notification.kind)
    let name = notification.title ?? childTitle ?? "A subagent"
    let previous = children[key] ?? []
    var names = previous
    if !names.contains(name) { names.append(name) }
    children[key] = names
    let rolled = AttentionNotification(
      sessionId: parent.id, kind: notification.kind, title: parent.title,
      body: Self.body(kind: notification.kind, names: names))
    // Replace this parent's earlier rollup, never the parent's own notification.
    let earlier = previous.isEmpty ? nil : Self.body(kind: notification.kind, names: previous)
    if let earlier,
      let index = pending.firstIndex(where: {
        $0.sessionId == parent.id && $0.kind == notification.kind && $0.body == earlier
      })
    {
      pending[index] = rolled
    } else {
      pending.append(rolled)
    }
  }

  /// The presenter took everything pending; the next child notification starts a new group.
  public mutating func reset() {
    children = [:]
  }

  static func body(kind: NotificationKind, names: [String]) -> String {
    let subject =
      names.count == 1 ? "Subagent \u{201C}\(names[0])\u{201D}" : "\(names.count) subagents"
    switch kind {
    case .approval:
      return names.count == 1
        ? "\(subject) is asking for your input." : "\(subject) are asking for your input."
    case .completed:
      return "\(subject) finished."
    case .failed:
      return "\(subject) failed."
    }
  }
}

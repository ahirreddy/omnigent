public import Foundation

/// An item an agent posted to its owner's Inbox.
nonisolated public struct InboxSuggestion: Hashable, Sendable {
  /// "Suggested follow-up", "Reminder" or "For your information".
  public var kindLabel: String
  /// Title.
  public var title: String
  /// The body, as Markdown.
  public var body: String
  /// Charts the agent attached.
  public var charts: [InboxChart]
  /// Links the agent attached, each target once.
  public var links: [InboxLink]
  /// Action labels, the first the primary one; each opens a new session with its prompt.
  public var actions: [String]
  /// The session the agent posted from, named as the sidebar names it, else "its session".
  public var sourceTitle: String
  /// The Dismiss menu's reasons.
  public var dismissChoices: [InboxDismissChoice]

  /// Creates a suggestion.
  public init(
    kindLabel: String, title: String, body: String, charts: [InboxChart] = [],
    links: [InboxLink] = [], actions: [String] = [], sourceTitle: String = "its session",
    dismissChoices: [InboxDismissChoice] = []
  ) {
    self.kindLabel = kindLabel
    self.title = title
    self.body = body
    self.charts = charts
    self.links = links
    self.actions = actions
    self.sourceTitle = sourceTitle
    self.dismissChoices = dismissChoices
  }
}

/// A link on an agent-posted item: a session here or a web page.
nonisolated public struct InboxLink: Hashable, Sendable, Identifiable {
  /// The text it shows.
  public var title: String
  /// The session it opens.
  public var sessionID: String?
  /// The web page it opens.
  public var url: URL?

  /// The link's target.
  public var id: String { sessionID.map { "session:\($0)" } ?? url?.absoluteString ?? title }

  /// Creates a link.
  public init(title: String, sessionID: String? = nil, url: URL? = nil) {
    self.title = title
    self.sessionID = sessionID
    self.url = url
  }
}

/// A line or bar chart on an agent-posted item.
nonisolated public struct InboxChart: Hashable, Sendable, Identifiable {
  /// One series: a name and one value (or a gap) per label.
  public struct Series: Hashable, Sendable {
    /// The legend's name.
    public var name: String
    /// One value per label; `nil` is a gap.
    public var values: [Double?]
    /// Drawn heavier.
    public var emphasis: Bool

    /// Creates a series.
    public init(name: String, values: [Double?], emphasis: Bool = false) {
      self.name = name
      self.values = values
      self.emphasis = emphasis
    }
  }

  /// Bars rather than lines.
  public var isBar: Bool
  /// The caption.
  public var title: String
  /// The x labels.
  public var labels: [String]
  /// The series.
  public var series: [Series]
  /// A shaded band from one label to another.
  public var highlight: ClosedRange<Int>?
  /// Labelled vertical lines, by label index.
  public var markers: [Int: String]
  /// Where the numbers come from, and its link.
  public var source: String?
  /// The source's web page.
  public var sourceURL: URL?
  /// The values' unit, such as `ms` or `%`.
  public var unit: String?

  /// The caption names the chart.
  public var id: String { title }

  /// Creates a chart.
  public init(
    isBar: Bool, title: String, labels: [String], series: [Series],
    highlight: ClosedRange<Int>? = nil, markers: [Int: String] = [:], source: String? = nil,
    sourceURL: URL? = nil, unit: String? = nil
  ) {
    self.isBar = isBar
    self.title = title
    self.labels = labels
    self.series = series
    self.highlight = highlight
    self.markers = markers
    self.source = source
    self.sourceURL = sourceURL
    self.unit = unit
  }
}

/// An automation whose latest run failed before it made a session.
nonisolated public struct InboxAutomationFailure: Hashable, Sendable {
  /// The automation.
  public var automationID: String
  /// Its name.
  public var name: String
  /// Where the run stopped and why.
  public var reason: String

  /// Creates a failure.
  public init(automationID: String, name: String, reason: String) {
    self.automationID = automationID
    self.name = name
    self.reason = reason
  }
}

/// A reason the Dismiss menu offers.
nonisolated public struct InboxDismissChoice: Hashable, Sendable, Identifiable {
  /// The reason's id, for the adapter.
  public var id: String
  /// The menu's label.
  public var title: String

  /// Creates a choice.
  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

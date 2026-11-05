public import Foundation

/// A built-in policy handler a default policy can be added from (the server's policy registry).
nonisolated public struct PolicyTemplate: Hashable, Sendable, Identifiable {
  /// How a parameter is edited.
  public enum ParamKind: Hashable, Sendable {
    /// Free text.
    case text
    /// A whole number.
    case integer
    /// Any number.
    case number
    /// On or off.
    case boolean
    /// One of the options.
    case choice
    /// A comma-separated list.
    case list
    /// Any of the options.
    case multiChoice
    /// A JSON object.
    case object
  }

  /// One parameter.
  public struct Param: Hashable, Sendable, Identifiable {
    /// The parameter name.
    public var id: String
    /// How it is edited.
    public var kind: ParamKind
    /// What it does.
    public var detail: String?
    /// The default, as form text.
    public var defaultValue: String
    /// A choice's allowed values.
    public var options: [String]

    /// Creates a parameter.
    public init(
      id: String, kind: ParamKind, detail: String? = nil, defaultValue: String = "",
      options: [String] = []
    ) {
      self.id = id
      self.kind = kind
      self.detail = detail
      self.defaultValue = defaultValue
      self.options = options
    }
  }

  /// The handler path.
  public var id: String
  /// Display name.
  public var name: String
  /// What it does.
  public var detail: String
  /// The name the form starts with.
  public var suggestedName: String
  /// Its parameters; empty for a handler that takes none.
  public var params: [Param]

  /// Creates a template.
  public init(id: String, name: String, detail: String, suggestedName: String, params: [Param]) {
    self.id = id
    self.name = name
    self.detail = detail
    self.suggestedName = suggestedName
    self.params = params
  }

  /// Whether it matches a filter, by name or description.
  /// - Parameter filter: The typed filter.
  /// - Returns: Whether it is listed.
  public func matches(_ filter: String) -> Bool {
    let query = filter.trimmingCharacters(in: .whitespaces)
    return query.isEmpty || name.localizedCaseInsensitiveContains(query)
      || detail.localizedCaseInsensitiveContains(query)
  }
}

/// A minted invite link, shown once.
nonisolated public struct MemberInviteLink: Hashable, Sendable {
  /// The link to send.
  public var url: String
  /// When it expires, if the server said.
  public var expiresAt: Date?

  /// Creates a link.
  public init(url: String, expiresAt: Date? = nil) {
    self.url = url
    self.expiresAt = expiresAt
  }
}

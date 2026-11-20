import SwiftUI

/// The reviewer picker, as the web's: people and teams to request a review from, with the
/// pending requests checked, the PR's author left out, and a typed login or `org/team` offered
/// when the provider didn't list it.
struct PullRequestReviewerPicker: View {
  let choices: PullRequestChoices
  /// Chip ids with a pending request.
  let requested: Set<String>
  /// The PR's author, whom the provider refuses as a reviewer.
  let author: String?
  /// The provider lists more candidates than were read.
  let truncated: Bool
  let toggle: (String, Bool) -> Void

  @State private var filter = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text("Request a review").font(.headline)
      SearchField("Filter or type a login\u{2026}", text: $filter)
      List {
        if let typed = typedChoice {
          Toggle(isOn: binding(typed.id)) { Text(typed.title) }
            .accessibilityIdentifier("pr-reviewer-typed")
        }
        content
      }
      .listStyle(.plain)
      .frame(minHeight: 160)
      if truncated, case .loaded = choices {
        Text("Showing the first \(listed.count). Type a login to request anyone else.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(Theme.Spacing.medium)
    .frame(width: 300, height: 340, alignment: .top)
  }

  @ViewBuilder private var content: some View {
    switch choices {
    case .idle, .loading:
      Text("Loading reviewers\u{2026}").foregroundStyle(.secondary)
    case .failed(let message):
      Text(message).foregroundStyle(Theme.failure)
    case .loaded:
      let shown = shown
      if shown.isEmpty, typedChoice == nil {
        Text(listed.isEmpty ? "No one to request." : "No reviewers match.")
          .foregroundStyle(.secondary)
      }
      let people = shown.filter { !$0.id.hasPrefix("team:") }
      let teams = shown.filter { $0.id.hasPrefix("team:") }
      if !people.isEmpty {
        Section("People") { ForEach(people) { row($0) } }
      }
      if !teams.isEmpty {
        Section("Teams") { ForEach(teams) { row($0) } }
      }
    }
  }

  private func row(_ item: PullRequestChip) -> some View {
    Toggle(isOn: binding(item.id)) {
      VStack(alignment: .leading, spacing: 0) {
        Text(item.title)
        if let detail = item.detail {
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func binding(_ id: String) -> Binding<Bool> {
    Binding(get: { requested.contains(id) }, set: { toggle(id, $0) })
  }

  /// The candidates, without the PR's author.
  private var listed: [PullRequestChip] {
    guard case .loaded(let items) = choices else { return [] }
    let author = author?.lowercased()
    return items.filter { $0.id.hasPrefix("team:") || $0.title.lowercased() != author }
  }

  private var shown: [PullRequestChip] {
    let query = filter.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return listed }
    return listed.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || ($0.detail?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  /// "Request review from ann" for a typed login the list doesn't hold.
  private var typedChoice: PullRequestChip? {
    guard let typed = Self.typedReviewer(filter), !listed.contains(where: { $0.id == typed.id })
    else { return nil }
    return typed
  }

  /// A typed `login`, `@login` or `org/team` as a reviewer chip, as the web's `typedReviewer`;
  /// `nil` when it can't be one.
  static func typedReviewer(_ query: String) -> PullRequestChip? {
    var text = query.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("@") { text.removeFirst() }
    let team = text.split(separator: "/", omittingEmptySubsequences: false)
    if team.count == 2, isName(team[0], extra: "-"), isName(team[1], extra: "_.-") {
      let slug = String(team[1])
      return PullRequestChip(
        id: "team:\(slug.lowercased())", title: "Request review from Team \(slug)")
    }
    guard let first = text.unicodeScalars.first, isAlphanumeric(first),
      isName(Substring(text), extra: "_-")
    else { return nil }
    return PullRequestChip(id: "user:\(text.lowercased())", title: "Request review from \(text)")
  }

  private static func isName(_ text: Substring, extra: String) -> Bool {
    !text.isEmpty
      && text.unicodeScalars.allSatisfy { isAlphanumeric($0) || extra.unicodeScalars.contains($0) }
  }

  private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
  }
}

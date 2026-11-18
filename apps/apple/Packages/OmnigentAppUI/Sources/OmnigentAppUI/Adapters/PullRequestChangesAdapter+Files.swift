import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// A changed file's header actions: the conversation count, earlier comments, Viewed, and
/// opening the file on its provider (the web's `PullRequestFileActions` and
/// `pullRequestFileUrl`).
extension PullRequestChangesAdapter {
  /// Where a file opens on its provider: the repositories and the revision the list shows.
  struct FileLinks {
    /// The provider's id.
    var provider: String?
    /// The source (possibly fork) repository's page.
    var headRepository: String?
    /// The base repository's page.
    var baseRepository: String?
    /// The head shown, or the open commit.
    var head: String?
    /// The base shown; a commit's patch has none.
    var base: String?
  }

  static func headerActions(
    _ panel: SessionPanelStore, file: StackedDiffFile, viewed: PullRequestViewedState,
    reviewing: Bool
  ) -> some View {
    var state = fileActions(panel, file: file)
    let earlier =
      reviewing && hasEarlierComments(panel, path: file.path, previous: file.previousPath)
    state.hasEarlierComments = earlier
    state.earlierCommentsShown = panel.changesView.shownEarlierComments.contains(file.path)
    if reviewing {
      let threads = panel.reviewThreads.value?.threads ?? []
      state.conversations = threads.count {
        ($0.path == file.path || $0.path == file.previousPath)
          && (!$0.outdated || state.earlierCommentsShown)
      }
      if panel.viewedAvailable {
        state.offersViewed = true
        state.viewed = viewed.viewed.contains(file.path)
        state.changedSinceViewed = viewed.changed.contains(file.path)
      }
    }
    let shown = state.earlierCommentsShown
    return PullRequestFileActionsView(
      state: state,
      toggleEarlier: earlier ? { panel.setEarlierCommentsShown(file.path, !shown) } : nil,
      toggleViewed: state.offersViewed ? { panel.toggleViewed(file.path) } : nil)
  }

  private static func hasEarlierComments(
    _ panel: SessionPanelStore, path: String, previous: String?
  ) -> Bool {
    let threads = panel.reviewThreads.value?.threads ?? []
    return threads.contains { ($0.path == path || $0.path == previous) && $0.outdated }
      || panel.openLocalComments.contains { $0.path == path && panel.isEarlier($0) }
  }

  /// Copy path, Copy previous path and Open in the provider at the revision the list shows:
  /// deleted files open at the base, others at the head; a commit's files at that commit.
  static func fileActions(_ panel: SessionPanelStore, file: StackedDiffFile)
    -> PullRequestFileActionsState
  {
    let info = panel.detail.value
    let providerName = info?.providerName ?? "GitHub"
    let baseRepository = repositoryURL(
      provider: info?.provider, pullRequest: panel.openPullRequest ?? "")
    let head: String? =
      if case .commit(let sha) = panel.changesMode { sha } else { panel.changes.value?.headSha }
    let links = FileLinks(
      provider: info?.provider, headRepository: info?.pullRequest?.headRepositoryUrl,
      baseRepository: baseRepository, head: head,
      base: panel.showsPatchView ? nil : panel.changes.value?.baseSha)
    let reason: String
    if panel.showsPatchView, file.kind == .deleted {
      if case .commit = panel.changesMode {
        reason = "Deleted in this commit"
      } else {
        reason = "Deleted since that commit"
      }
    } else {
      let source = file.kind == .deleted ? baseRepository : links.headRepository
      reason = openUnavailable(
        provider: providerName, supported: baseRepository != nil, source: source)
    }
    return PullRequestFileActionsState(
      path: file.path, previousPath: file.renamedFrom, openLabel: "Open in \(providerName)",
      openURL: fileURL(links, file: file), openUnavailable: reason)
  }

  /// Why a file's Open action is unavailable (the web's `openUnavailableReason`).
  static func openUnavailable(provider: String, supported: Bool, source: String?) -> String {
    if !supported { return "Opening files isn\u{2019}t supported for \(provider)" }
    guard let source else { return "Source repository unavailable" }
    if !source.hasPrefix("https://") { return "Repository URL isn\u{2019}t secure" }
    return "Revision unknown"
  }

  /// The web page of the repository a PR URL belongs to (the web's `pullRequestRepoUrl`).
  static func repositoryURL(provider: String?, pullRequest url: String) -> String? {
    let markers = [
      "github": "/pull/", "gitlab": "/-/merge_requests/", "azure_devops": "/pullrequest/",
    ]
    guard let provider, let marker = markers[provider],
      let range = url.range(of: marker, options: .backwards)
    else { return nil }
    let repo = String(url[..<range.lowerBound])
    let rest = url[range.upperBound...]
    let number = rest.prefix { $0.isNumber }
    let after = rest.dropFirst(number.count)
    guard repo.hasPrefix("http://") || repo.hasPrefix("https://"), !number.isEmpty,
      after.isEmpty || after.first.map({ "/?#".contains($0) }) == true,
      repo.count > (repo.hasPrefix("https://") ? 8 : 7)
    else { return nil }
    return repo
  }

  /// What `encodeURIComponent` leaves unescaped.
  private static let uriComponent = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

  /// The provider page of a changed file (the web's `pullRequestFileUrl`); `nil` when the
  /// repository or revision is unknown or not served over HTTPS.
  static func fileURL(_ links: FileLinks, file: StackedDiffFile) -> URL? {
    let deleted = file.kind == .deleted
    guard let repo = deleted ? links.baseRepository : links.headRepository,
      let sha = deleted ? links.base : links.head, repo.hasPrefix("https://")
    else { return nil }
    let path = deleted ? (file.renamedFrom ?? file.path) : file.path
    let encoded = path.split(separator: "/", omittingEmptySubsequences: false)
      .map { $0.addingPercentEncoding(withAllowedCharacters: uriComponent) ?? String($0) }
      .joined(separator: "/")
    let address: String? =
      switch links.provider {
      case "github": "\(repo)/blob/\(sha)/\(encoded)"
      case "gitlab": "\(repo)/-/blob/\(sha)/\(encoded)"
      case "azure_devops": "\(repo)?path=/\(encoded)&version=GC\(sha)"
      default: nil
      }
    return address.flatMap(URL.init(string:))
  }
}

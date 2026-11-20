import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// The PR panel's web-parity rules that need no window: suggestion fences, typed reviewers,
/// author hues, attachments at the cursor and the "Comment as" line.
@Suite("Pull requests: parity logic")
struct PullRequestParityLogicTests {
  @Test func suggestionFencesSplitOutOfTheMarkdown() {
    let body = "Try this:\n```suggestion\nlet x = 1\n\n```\nThanks"
    #expect(
      PullRequestReviewBodyPart.split(body) == [
        .markdown("Try this:"), .suggestion("let x = 1\n"), .markdown("Thanks"),
      ])
    #expect(PullRequestReviewBodyPart.split("~~~ suggestion\n~~~") == [.suggestion("")])
    #expect(
      PullRequestReviewBodyPart.split("```suggestion\nunclosed") == [.suggestion("unclosed")],
      "an unclosed fence runs to the end")
  }

  @Test func otherCodeKeepsItsSuggestionsAsMarkdown() {
    let quoted = "````markdown\n```suggestion\nx\n```\n````"
    #expect(PullRequestReviewBodyPart.split(quoted) == [.markdown(quoted)])
    let indented = "    ```suggestion\n    x\n    ```"
    #expect(PullRequestReviewBodyPart.split(indented) == [.markdown(indented)])
    #expect(PullRequestReviewBodyPart.split("```swift\nlet a\n```").count == 1)
  }

  @Test func aTypedLoginOrTeamCanBeRequested() {
    #expect(PullRequestReviewerPicker.typedReviewer("@Ann-1")?.id == "user:ann-1")
    #expect(PullRequestReviewerPicker.typedReviewer(" org/core.team ")?.id == "team:core.team")
    #expect(
      PullRequestReviewerPicker.typedReviewer("org/core")?.title == "Request review from Team core")
    for invalid in ["", "-ann", "a b", "org/", "a/b/c", "ann!"] {
      #expect(PullRequestReviewerPicker.typedReviewer(invalid) == nil, "\(invalid)")
    }
  }

  @Test func authorHuesSpreadEvenlyAndGroupSharedSuffixes() {
    let hues = PullRequestAuthorAvatar.hues(["ann-bot", "Zed", "sam-bot", "ann-bot"])
    #expect(hues.count == 3)
    #expect(Set(hues.values) == [0, 120, 240])
    // Sorted by reversed name, the two "-bot" authors sit next to each other.
    #expect(abs((hues["ann-bot"] ?? 0) - (hues["sam-bot"] ?? 0)) == 120)
    #expect(hues["zed"] != nil)
  }

  @Test func attachmentsLandAtTheCursorOnLinesOfTheirOwn() {
    var draft = PullRequestDescriptionDraft(original: "", body: "Beforeafter")
    draft.insertion = 6..<6
    draft.insert("![a](x)")
    #expect(draft.body == "Before\n![a](x)\nafter")
    draft.insert("![b](y)")
    #expect(draft.body == "Before\n![a](x)\n![b](y)\nafter", "the next one goes after it")
    var empty = PullRequestDescriptionDraft(original: "", body: "Text")
    empty.insert("![c](z)")
    #expect(empty.body == "Text\n![c](z)")
    var replacing = PullRequestDescriptionDraft(original: "", body: "a\nOLD\nb")
    replacing.insertion = 2..<5
    replacing.insert("NEW")
    #expect(replacing.body == "a\nNEW\nb")
  }

  @Test func theCommentLineNamesTheAccountItPostsAs() {
    typealias Destination = PullRequestCommentDestination
    #expect(Destination.provider(account: "ann", providerName: "GitHub").line == "Comment as ann")
    #expect(Destination.newThread(account: "ann", providerName: "GitHub").line == "@ann")
    #expect(
      Destination.provider(account: nil, providerName: "GitLab").line
        == "Host\u{2019}s GitLab account")
    #expect(Destination.agent.line == nil)
  }
}

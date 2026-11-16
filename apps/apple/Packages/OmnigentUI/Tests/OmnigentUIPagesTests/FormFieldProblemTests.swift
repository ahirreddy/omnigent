import Testing

@testable import OmnigentUIComponents

/// Form problems show next to the field they are about, not under the last field.
@Suite("Decision form field problems")
struct FormFieldProblemTests {
  let fields = PreviewData.formFields

  private func field(_ key: String) -> FormField? { fields.first { $0.key == key } }

  @Test("each field reports its own problem, missing apart from invalid")
  func perField() throws {
    var draft = FormDraft()
    let title = try #require(field("title"))
    let token = try #require(field("token"))
    let reviewers = try #require(field("reviewers"))
    #expect(draft.problem(for: title) == .missing("Enter PR title."))
    // The optional last field has nothing to say about the first one.
    #expect(draft.problem(for: token) == nil)
    draft.text["reviewers"] = "two"
    #expect(draft.problem(for: reviewers) == .invalid("Reviewers must be a whole number."))
    draft.text["title"] = "Coalesce refreshes"
    #expect(draft.problem(for: title) == nil)
  }

  @Test("validator messages attach to the field they name")
  func attribution() {
    #expect(
      FormDraft.field(for: "PR title can be at most 72 characters.", in: fields)?.key == "title")
    #expect(FormDraft.field(for: "Choose at most 2 labels.", in: fields)?.key == "labels")
    #expect(FormDraft.field(for: "This response contains an unknown field.", in: fields) == nil)
  }

  @Test("a keyed problem attaches to its field even when titles overlap")
  func keyedAttribution() {
    let overlapping = [
      FormField(key: "title", title: "Title", kind: .text),
      FormField(key: "pr", title: "PR title", kind: .text),
    ]
    // The message names "PR title", but the core says it is about `title`.
    let keyed = DecisionFormProblem(message: "PR title is taken.", fieldKey: "title")
    #expect(keyed.field(in: overlapping)?.key == "title")
    // Without a key (an older validator), the title match is the fallback.
    #expect(DecisionFormProblem(message: "Enter PR title.").field(in: overlapping)?.key == "pr")
    // A key the form does not have stays with Submit.
    let unknown = DecisionFormProblem(message: "Unknown.", fieldKey: "extra")
    #expect(unknown.field(in: overlapping) == nil)
  }

  @Test("the longest matching title wins when titles overlap")
  func overlappingTitles() {
    let overlapping = [
      FormField(key: "title", title: "Title", kind: .text),
      FormField(key: "pr", title: "PR title", kind: .text),
    ]
    #expect(FormDraft.field(for: "Enter PR title.", in: overlapping)?.key == "pr")
  }
}

/// Approval file rows leave zero counts out.
@Suite("Approval file counts")
struct FileChangeCountTests {
  @Test("a new file reads +11, a file without counts shows none")
  func zeroCounts() {
    let created = DecisionFileChange(path: "a.swift", added: 11, removed: 0, kind: .create)
    #expect(DecisionSummary.counts(created) == "+11")
    let modified = DecisionFileChange(path: "b.swift", added: 4, removed: 1, kind: .modify)
    #expect(DecisionSummary.counts(modified) == "+4 \u{2212}1")
    #expect(DecisionSummary.counts(DecisionFileChange(path: "c.swift", kind: .write)) == nil)
    #expect(FileChangeList.kindLabel(.create) == "new file")
    #expect(FileChangeList.kindLabel(.modify) == nil)
  }
}

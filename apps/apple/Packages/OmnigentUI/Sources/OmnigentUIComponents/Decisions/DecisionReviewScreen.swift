import SwiftUI

/// A large request on a phone, full screen: the whole payload unfolded, a button to switch
/// code between wrapping and scrolling sideways, and the card's own actions.
struct DecisionReviewScreen: View {
  let card: DecisionCard
  let phase: DecisionPhase
  let isReadOnly: Bool
  let context: String?
  let respond: ((DecisionResponse) -> Void)?
  let validate: (([String: ElicitationValue]) -> DecisionFormProblem?)?
  let draft: Binding<FormDraft>
  let close: () -> Void
  @State private var wraps = true

  var body: some View {
    NavigationStack {
      ScrollView {
        DecisionCardView(
          card: card, phase: phase, isReadOnly: isReadOnly, context: context, respond: respond,
          validate: validate, draft: draft
        )
        .padding(Theme.Spacing.compactGutter)
      }
      .environment(\.decisionCodeLayout, .fullScreen(wraps: wraps))
      .navigationTitle(DecisionSummary(card).plain)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: close).accessibilityIdentifier("decision-review-done")
        }
        ToolbarItem(placement: .primaryAction) {
          // A neutral button rather than a toggle, whose selected state fills with system blue.
          Button {
            wraps.toggle()
          } label: {
            Label(
              wraps ? "Scroll long lines" : "Wrap long lines",
              systemImage: wraps ? "arrow.left.and.right.text.vertical" : "text.append")
          }
          .tint(.primary)
          .help(wraps ? "Scroll long lines sideways" : "Wrap long lines")
          .accessibilityIdentifier("decision-review-wrap")
        }
      }
    }
    .themeCanvas()
    .environment(\.decisionIDPrefix, "review-")
    .accessibilityIdentifier("decision-review")
  }
}

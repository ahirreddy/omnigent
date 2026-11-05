import SwiftUI

/// A landing-screen link, as the web's `LandingFooter`.
struct LandingLink: Identifiable, Equatable {
  let id: String
  let title: String
  let systemImage: String
  let url: URL

  /// The apps and community links, in the web's order.
  static let all: [Self] = [
    link("ios", "iOS App", "apple.logo", "https://apps.apple.com/us/app/omnigent/id6783102694"),
    link(
      "android", "Android App", "candybarphone",
      "https://omnigent.ai/docs/interact/mobile#android-app"),
    link(
      "github", "GitHub", "chevron.left.forwardslash.chevron.right",
      "https://github.com/omnigent-ai/omnigent"),
    link("discord", "Join Discord", "bubble.left.and.bubble.right", "https://discord.gg/omnigent"),
  ].compactMap(\.self)

  private static func link(_ id: String, _ title: String, _ symbol: String, _ address: String)
    -> Self?
  {
    URL(string: address).map { Self(id: id, title: title, systemImage: symbol, url: $0) }
  }
}

/// The landing's footer: app and community links, opened in the browser, and who maintains
/// Omnigent.
struct LandingFooter: View {
  var body: some View {
    VStack(spacing: 4) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 2) { links }
        VStack(spacing: 2) { links }
      }
      Text("Maintained by Databricks and the Omnigent community")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("auth.landing-footer")
  }

  private var links: some View {
    ForEach(LandingLink.all) { link in
      Link(destination: link.url) {
        Label(link.title, systemImage: link.systemImage)
          .font(.caption)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .accessibilityIdentifier("auth.landing-link.\(link.id)")
    }
  }
}

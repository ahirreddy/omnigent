public import SwiftUI

/// Every sign-in state side by side, with inert actions: a review surface for design and
/// accessibility passes. On the Mac it is a split view (states on the left); on compact widths a
/// navigation stack.
public struct AuthGalleryView: View {
  private let samples: [AuthSample]
  @State private var selection: AuthSample.ID?

  /// Creates the gallery.
  /// - Parameter samples: The states to show; every sample by default.
  public init(samples: [AuthSample] = AuthSamples.all) {
    self.samples = samples
    _selection = State(initialValue: samples.first?.id)
  }

  /// The gallery.
  public var body: some View {
    NavigationSplitView {
      List(samples, selection: $selection) { sample in
        Text(sample.title)
          .tag(sample.id)
      }
      .navigationTitle("Sign-in states")
    } detail: {
      if let sample = samples.first(where: { $0.id == selection }) {
        AuthGalleryDetail(sample: sample)
          .id(sample.id)
      } else {
        Text("Choose a state")
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct AuthGalleryDetail: View {
  let sample: AuthSample

  var body: some View {
    VStack(spacing: 0) {
      AuthFlowView(state: sample.state, actions: .inert, validator: .preview)
      if case .connected(let account) = sample.state.phase {
        Divider()
        HStack {
          Text("Toolbar chip:")
            .font(.caption)
            .foregroundStyle(.secondary)
          AccountChip(account: account, actions: .inert)
          Spacer()
        }
        .padding()
      }
    }
    .navigationTitle(sample.title)
  }
}

#Preview("Gallery") {
  AuthGalleryView()
}

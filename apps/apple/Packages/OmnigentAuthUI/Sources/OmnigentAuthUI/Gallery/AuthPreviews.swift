import SwiftUI

// One preview per sample state, plus the sheet presentation and the account chip.

private struct SamplePreview: View {
  let id: String
  var presentation = AuthPresentation.window

  var body: some View {
    if let sample = AuthSamples.sample(id) {
      AuthFlowView(
        state: sample.state, actions: .inert, validator: .preview, presentation: presentation)
    } else {
      Text(verbatim: "Unknown sample \(id)")
        .foregroundStyle(.red)
    }
  }
}

#Preview("Picker") { SamplePreview(id: "picker") }
#Preview("Picker, signed out") { SamplePreview(id: "picker-signed-out") }
#Preview("Picker, unreachable") { SamplePreview(id: "picker-unreachable") }
#Preview("Picker, invalid URL") { SamplePreview(id: "picker-invalid-url") }
#Preview("Discovering") { SamplePreview(id: "discovering") }
#Preview("Password") { SamplePreview(id: "password") }
#Preview("Password, error") { SamplePreview(id: "password-error") }
#Preview("Password, submitting") { SamplePreview(id: "password-submitting") }
#Preview("Browser") { SamplePreview(id: "browser") }
#Preview("Browser, refused") { SamplePreview(id: "browser-refused") }
#Preview("Signing in") { SamplePreview(id: "signing-in") }
#Preview("Ticket") { SamplePreview(id: "ticket") }
#Preview("Reauth, expired") { SamplePreview(id: "reauth-expired") }
#Preview("Reauth, ended") { SamplePreview(id: "reauth-ended") }
#Preview("Workspace") { SamplePreview(id: "workspace") }
#Preview("Workspace, signing in") { SamplePreview(id: "workspace-signing-in") }
#Preview("Unsupported") { SamplePreview(id: "unsupported") }
#Preview("Proxy") { SamplePreview(id: "proxy") }
#Preview("Connecting") { SamplePreview(id: "connecting") }
#Preview("Signed in") { SamplePreview(id: "signed-in") }

#Preview("Sheet, dark") {
  SamplePreview(id: "password-error", presentation: .sheet)
    .preferredColorScheme(.dark)
}

#Preview("Account chip") {
  AccountChip(account: AuthSamples.account, actions: .inert)
    .padding()
}

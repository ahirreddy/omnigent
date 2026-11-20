import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The server's branding in the environment: the built-in look without any, its name, logo and
/// "Powered by" otherwise.
@MainActor
@Suite("Server branding")
struct ServerBrandingTests {
  @Test("no branding is the built-in look; a branded server names the app and shows its logo")
  func environment() {
    #expect(ServerBrandingEnvironment.appBranding(nil, logo: Data([1])) == nil)
    let branding = ServerBranding(
      appName: "Acme Agents", heading: "", logoMain: "/v1/branding/logo/main", poweredBy: true)
    let applied = ServerBrandingEnvironment.appBranding(branding, logo: nil)
    #expect(applied?.name == "Acme Agents" && applied?.poweredBy == true)
    #expect(applied?.logoImage == nil, "the mascot shows until the logo is read")
    let unnamed = ServerBranding(appName: nil, heading: nil, logoMain: nil, poweredBy: false)
    #expect(ServerBrandingEnvironment.appBranding(unnamed, logo: nil)?.name == "Omnigent")
    #expect(
      ServerBrandingEnvironment.appBranding(unnamed, logo: Data("not an image".utf8))?.logoImage
        == nil, "a logo that doesn't decode falls back to the mascot")
  }
}

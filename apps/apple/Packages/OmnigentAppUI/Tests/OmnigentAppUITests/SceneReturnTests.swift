import SwiftUI
import Testing

@testable import OmnigentAppUI

@Suite("Scene return from the background")
struct SceneReturnTests {
  @Test("A cold launch that starts in the background to open a link is not a return")
  func coldLinkLaunch() {
    #expect(!SceneReturn.isReturn(from: .background, to: .inactive, hasBeenActive: false))
    #expect(!SceneReturn.isReturn(from: .background, to: .active, hasBeenActive: false))
  }

  @Test("Leaving the background after being on screen is a return; other moves are not")
  func returnAfterActive() {
    #expect(SceneReturn.isReturn(from: .background, to: .inactive, hasBeenActive: true))
    #expect(SceneReturn.isReturn(from: .background, to: .active, hasBeenActive: true))
    #expect(!SceneReturn.isReturn(from: .inactive, to: .active, hasBeenActive: true))
    #expect(!SceneReturn.isReturn(from: .active, to: .background, hasBeenActive: true))
  }
}

import CoreGraphics
import Testing

@testable import OmnigentTerminalUI

@Suite("Gallery model", .serialized)
struct GalleryModelTests {
  @Test("the harness page draws the TUI at the laid-out grid size")
  func harnessPage() async throws {
    let model = TerminalGalleryModel()
    let controller = try model.harness.get()
    _ = try SurfaceHost(controller: controller, width: 600, height: 400)
    #expect(await eventually { controller.visibleText().contains("Harness TUI demo") })
  }

  @Test("the list page attaches the selected terminal")
  func listPage() async throws {
    let model = TerminalGalleryModel()
    let controller = try model.listController(for: "terminal_zsh_u-4f2k9q").get()
    _ = try SurfaceHost(controller: controller, width: 600, height: 400)
    #expect(await eventually { controller.visibleText().contains("Attached to zsh") })
    model.create("bash")
    #expect(model.listItems.count == 4)
    #expect(model.listSelection == model.listItems.last?.id)
    model.close("terminal_zsh_u-4f2k9q")
    #expect(model.listItems.count == 3)
  }
}

#if os(macOS)
  import AppKit

  extension TranscriptTableCLICell {
    // Tool work's lines as SwiftUI's tool views name them, beside the text's own elements: each
    // call and explored line a group `tool-<id>`, a reasoning line `reasoning-<id>`, and
    // "… +N lines" a button that opens what it hides. AppKit's signature makes them optional.
    // swiftlint:disable:next discouraged_optional_collection
    override func accessibilityChildren() -> [Any]? {
      let children = super.accessibilityChildren() ?? []
      guard block?.kind == .work, let document else { return children }
      if workElements.document !== document {
        workElements = (document, regionElements(document))
      }
      return children + workElements.elements
    }

    /// An element for each region of `document` that SwiftUI's tool views name or make a button.
    private func regionElements(_ document: CLITextDocument) -> [TranscriptTableCLIRegionElement] {
      var elements: [TranscriptTableCLIRegionElement] = []
      for case .region(let rect, let id) in document.decorations {
        let label = document.regionLabels[id] ?? ""
        let role: TranscriptTableCLIRegionElement.Role
        if id.hasPrefix(CLITextDecoration.morePrefix) {
          role = .button(String(id.dropFirst(CLITextDecoration.morePrefix.count)))
        } else if let identifier = workIdentifier(of: id) {
          role = .line(identifier)
        } else {
          continue
        }
        elements.append(
          TranscriptTableCLIRegionElement(cell: self, rect: rect, role: role, label: label))
      }
      return elements
    }

    /// The identifier SwiftUI gives the line `id` names: a tool call's or an explored line's
    /// `tool-<id>`, a reasoning line's `reasoning-<id>`; `nil` for a region it leaves unnamed.
    private func workIdentifier(of id: String) -> String? {
      switch block?.work?.targets[id] {
      case .steps: "tool-\(id)"
      case .activity(let row): "reasoning-\(row.id)"
      case nil: nil
      }
    }

    /// Where `rect`, in the text's coordinates, is on the screen.
    func screenFrame(ofTextRect rect: CGRect) -> NSRect {
      // AppKit declares `window` unowned(unsafe); it is only read here.
      guard let window = unsafe window else { return .zero }
      let local = rect.offsetBy(dx: textFrame.minX, dy: textFrame.minY)
      return window.convertToScreen(convert(local, to: nil))
    }
  }

  /// A region of a CLI text cell's tool work as an assistive client reads it: a line SwiftUI
  /// names, or the button "… +N lines" is. Its parent is the cell.
  nonisolated final class TranscriptTableCLIRegionElement: NSAccessibilityElement {
    enum Role {
      /// A tool call's, explored line's or reasoning line's group, by its identifier.
      case line(String)
      /// "… +N lines", which opens the action it names.
      case button(String)
    }

    weak var cell: TranscriptTableCLICell?
    /// In the cell's text's coordinates.
    let rect: CGRect
    let role: Role
    let label: String

    init(cell: TranscriptTableCLICell, rect: CGRect, role: Role, label: String) {
      self.cell = cell
      self.rect = rect
      self.role = role
      self.label = label
      super.init()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? {
      switch role {
      case .line: .group
      case .button: .button
      }
    }

    override func accessibilityLabel() -> String? { label }

    override func accessibilityIdentifier() -> String {
      switch role {
      case .line(let identifier): identifier
      case .button: ""
      }
    }

    override func accessibilityParent() -> Any? { cell }

    // Assistive clients ask on the main thread.
    override func accessibilityFrame() -> NSRect {
      let cell = cell
      let rect = rect
      return MainActor.assumeIsolated { cell?.screenFrame(ofTextRect: rect) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
      guard case .button(let action) = role else { return false }
      let cell = cell
      MainActor.assumeIsolated { cell?.toggle(action) }
      return true
    }
  }
#endif

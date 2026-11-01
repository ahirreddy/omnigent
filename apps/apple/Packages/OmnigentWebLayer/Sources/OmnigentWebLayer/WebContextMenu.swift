public import AppKit
internal import OWLProtocol
internal import os

/// One item of the host's context menu model.
nonisolated public struct WebMenuItem: Sendable, Hashable, Decodable {
  /// What the item is.
  public enum Kind: String, Sendable, Hashable, Decodable {
    /// A plain command.
    case command
    /// A checkable command.
    case check
    /// A radio-group command.
    case radio
    /// A separator.
    case separator
    /// A submenu.
    case submenu
  }

  /// Chromium's command ID; send it back to run the command.
  public let id: Int
  /// The item kind.
  public let kind: Kind
  /// The label, without mnemonics.
  public let label: String
  /// Whether the command is enabled.
  public let enabled: Bool
  /// Whether a check or radio item is on.
  public let checked: Bool
  /// Submenu items; empty for other kinds.
  public let items: [Self]

  private enum CodingKeys: String, CodingKey {
    case id, kind, label, enabled, checked, items
  }

  /// Decodes one MenuItems entry; `items` is present only for submenus.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int.self, forKey: .id)
    kind = try container.decode(Kind.self, forKey: .kind)
    label = try container.decode(String.self, forKey: .label)
    enabled = try container.decode(Bool.self, forKey: .enabled)
    checked = try container.decode(Bool.self, forKey: .checked)
    items = try container.decodeIfPresent([Self].self, forKey: .items) ?? []
  }
}

/// What was under the pointer when the menu opened.
nonisolated public struct WebMenuContext: Sendable, Hashable, Decodable {
  /// The link, if the menu opened on one.
  public let linkURL: String
  /// The image or media source, if any.
  public let sourceURL: String
  /// The page URL.
  public let pageURL: String
  /// The frame URL.
  public let frameURL: String
  /// The selected text.
  public let selectionText: String
  /// Whether the target is editable.
  public let isEditable: Bool
}

/// A context menu the page opened (right-click, Control-click). The host built the items; the
/// app can add its own (see `WebContextMenuPresenter`). Agent clicks never open one.
public final class WebContextMenu: WebPromptRequest {
  /// Where the menu opened, in view points (top-left origin).
  public let location: CGPoint
  /// The host's items.
  public let items: [WebMenuItem]
  /// The context the menu opened in.
  public let context: WebMenuContext

  init(id: UInt64, webView: WebView, fields: WireDecoder) throws(WebLayerError) {
    location = CGPoint(x: fields.double(.X) ?? 0, y: fields.double(.Y) ?? 0)
    items = try WireJSON.decode(
      [WebMenuItem].self, fields.string(.menuItems) ?? "[]", field: "MenuItems")
    context = try WireJSON.decode(
      WebMenuContext.self, fields.string(.menuParams) ?? "{}", field: "MenuParams")
    super.init(id: id, webView: webView)
  }

  /// Runs one of the host's commands.
  public func select(commandID: Int) {
    reply(.contextMenuReply, WireEncoder().i64(.commandID, Int64(commandID)))
  }

  /// Closes the menu without running a host command (also after running an app item).
  public func dismiss() {
    reply(.contextMenuReply, WireEncoder().i64(.commandID, -1))
  }
}

/// An item the app adds to a page's context menu.
public struct WebAppMenuItem {
  /// The label.
  public let title: String
  /// Runs when chosen.
  public let action: () -> Void

  /// Creates an item.
  public init(title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }
}

/// Shows a `WebContextMenu` as a native `NSMenu` and answers it with the chosen command.
public enum WebContextMenuPresenter {
  /// Pops the menu up at its location in `view` (the view showing the page). `appItems` go
  /// first, above the host's items. The menu is answered when it closes.
  public static func present(
    _ menu: WebContextMenu, in view: NSView, appItems: [WebAppMenuItem] = []
  ) {
    let target = MenuTarget(menu: menu, appItems: appItems)
    let nsMenu = NSMenu(title: "")
    nsMenu.autoenablesItems = false
    for (index, item) in appItems.enumerated() {
      let menuItem = NSMenuItem(
        title: item.title, action: #selector(MenuTarget.runAppItem(_:)), keyEquivalent: "")
      menuItem.tag = index
      menuItem.target = target
      nsMenu.addItem(menuItem)
    }
    if !appItems.isEmpty, !menu.items.isEmpty {
      nsMenu.addItem(.separator())
    }
    add(menu.items, to: nsMenu, target: target)
    // popUp blocks in a tracking loop until the menu closes.
    let opened = nsMenu.popUp(positioning: nil, at: menuPoint(menu.location, in: view), in: view)
    target.finish(menuOpened: opened)
  }

  /// Builds the NSMenu items for host items. Exposed for tests.
  static func add(_ items: [WebMenuItem], to menu: NSMenu, target: AnyObject) {
    for item in items {
      switch item.kind {
      case .separator:
        menu.addItem(.separator())
      case .submenu:
        let parent = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: item.label)
        submenu.autoenablesItems = false
        add(item.items, to: submenu, target: target)
        parent.submenu = submenu
        parent.isEnabled = item.enabled
        menu.addItem(parent)
      case .command, .check, .radio:
        let menuItem = NSMenuItem(
          title: item.label, action: #selector(MenuTarget.runHostItem(_:)), keyEquivalent: "")
        menuItem.tag = item.id
        menuItem.target = target
        menuItem.isEnabled = item.enabled
        menuItem.state = item.checked ? .on : .off
        menu.addItem(menuItem)
      }
    }
  }

  private static func menuPoint(_ location: CGPoint, in view: NSView) -> NSPoint {
    view.isFlipped ? location : NSPoint(x: location.x, y: view.bounds.height - location.y)
  }
}

/// Collects the choice; answers the host exactly once.
private final class MenuTarget: NSObject {
  let menu: WebContextMenu
  let appItems: [WebAppMenuItem]
  var chosenHostCommand: Int?
  var chosenAppItem: Int?

  init(menu: WebContextMenu, appItems: [WebAppMenuItem]) {
    self.menu = menu
    self.appItems = appItems
  }

  @objc func runHostItem(_ sender: NSMenuItem) {
    chosenHostCommand = sender.tag
  }

  @objc func runAppItem(_ sender: NSMenuItem) {
    chosenAppItem = sender.tag
  }

  func finish(menuOpened: Bool) {
    if !menuOpened {
      Logger.view.error("The context menu could not be shown.")
    }
    if let command = chosenHostCommand {
      menu.select(commandID: command)
      return
    }
    menu.dismiss()
    if let index = chosenAppItem, appItems.indices.contains(index) {
      appItems[index].action()
    }
  }
}

public import SwiftUI

extension BrowserProfileColor {
  /// The adaptive system color for the profile.
  public var color: Color {
    switch self {
    case .blue: .blue
    case .purple: .purple
    case .pink: .pink
    case .red: .red
    case .orange: .orange
    case .yellow: .yellow
    case .green: .green
    case .teal: .teal
    case .gray: .gray
    }
  }

  /// Display name.
  public var displayName: String { rawValue.capitalized }
}

/// A profile's round avatar: initials, a symbol or an emoji on the profile color.
public struct BrowserProfileAvatarView: View {
  private let profile: BrowserUserProfile?
  private let size: CGFloat

  /// Creates the avatar; a nil (deleted) profile shows a gray person.
  public init(profile: BrowserUserProfile?, size: CGFloat = 18) {
    self.profile = profile
    self.size = size
  }

  /// The view body.
  public var body: some View {
    let tint = profile?.color.color ?? .gray
    ZStack {
      Circle().fill(tint.gradient)
      switch profile?.avatar ?? .symbol("person.fill") {
      case .initials:
        Text(profile?.initials ?? "?")
          .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
          .foregroundStyle(.white)
      case .symbol(let name):
        Image(systemName: name)
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white)
      case .emoji(let emoji):
        Text(emoji).font(.system(size: size * 0.6))
      }
    }
    .frame(width: size, height: size)
    .accessibilityLabel(profile?.name ?? "Deleted profile")
  }
}

/// A profile chip: avatar and name, tinted with the profile color. For a tab or a toolbar.
public struct BrowserProfileChip: View {
  private let profile: BrowserUserProfile?
  private let showsName: Bool

  /// Creates the chip.
  public init(profile: BrowserUserProfile?, showsName: Bool = true) {
    self.profile = profile
    self.showsName = showsName
  }

  /// The view body.
  public var body: some View {
    HStack(spacing: 5) {
      BrowserProfileAvatarView(profile: profile, size: 16)
      if showsName {
        Text(profile?.name ?? "Deleted")
          .font(.callout.weight(.medium))
          .lineLimit(1)
      }
    }
    .padding(.leading, 3)
    .padding(.trailing, showsName ? 8 : 3)
    .padding(.vertical, 3)
    .background((profile?.color.color ?? .gray).opacity(0.16), in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Profile \(profile?.name ?? "deleted")")
  }
}

/// Menu content listing profiles, for "New Tab in Profile". `onPick` gets the chosen profile.
public struct BrowserProfilePicker: View {
  private let store: BrowserProfileStore
  private let onPick: (BrowserUserProfile) -> Void

  /// Creates the picker.
  public init(store: BrowserProfileStore, onPick: @escaping (BrowserUserProfile) -> Void) {
    self.store = store
    self.onPick = onPick
  }

  /// The view body.
  public var body: some View {
    ForEach(store.profiles) { profile in
      Button {
        onPick(profile)
      } label: {
        Label {
          Text(profile.id == store.defaultProfileID ? "\(profile.name) (default)" : profile.name)
        } icon: {
          Image(systemName: "circle.fill").foregroundStyle(profile.color.color)
        }
      }
      .accessibilityIdentifier("browser.profilePicker.\(profile.name)")
    }
  }
}

/// Create, rename, recolor, pick an avatar, set the default, delete.
public struct BrowserProfileManagerView: View {
  private let environment: BrowserEnvironment
  @State private var editing: BrowserUserProfile?
  @State private var deleting: BrowserUserProfile?
  @State private var error: BrowserError?
  @Environment(\.dismiss) private var dismiss

  /// Creates the manager.
  public init(environment: BrowserEnvironment) {
    self.environment = environment
  }

  private var store: BrowserProfileStore { environment.profiles }

  /// The view body.
  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Profiles").font(.title2.bold())
      Text("Each profile keeps its own cookies, history, bookmarks and site settings.")
        .foregroundStyle(.secondary)
      List {
        ForEach(store.profiles) { profile in
          HStack(spacing: 10) {
            BrowserProfileAvatarView(profile: profile, size: 28)
            VStack(alignment: .leading) {
              Text(profile.name).font(.body.weight(.medium))
              if profile.id == store.defaultProfileID {
                Text("Default for new tabs").font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            if profile.id != store.defaultProfileID {
              Button("Make Default") {
                run { () throws(BrowserError) in try store.setDefault(profile.id) }
              }
            }
            Button("Edit", systemImage: "pencil") { editing = profile }
              .labelStyle(.iconOnly)
              .accessibilityIdentifier("browser.profiles.edit.\(profile.name)")
            Button("Delete", systemImage: "trash") { deleting = profile }
              .labelStyle(.iconOnly)
              .disabled(store.profiles.count < 2)
          }
          .padding(.vertical, 2)
        }
      }
      .frame(minHeight: 180)
      if let error = error ?? store.lastError {
        Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Button("Add Profile", systemImage: "plus") {
          editing = BrowserUserProfile(
            name: "",
            color: BrowserProfileColor.allCases[
              store.profiles.count % BrowserProfileColor.allCases.count])
        }
        .accessibilityIdentifier("browser.profiles.add")
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 460, minHeight: 360)
    .sheet(item: $editing) { profile in
      BrowserProfileEditor(
        profile: profile, isNew: store.profile(id: profile.id) == nil, save: save)
    }
    .confirmationDialog(
      "Delete \(deleting?.name ?? "")?", isPresented: .constant(deleting != nil),
      titleVisibility: .visible
    ) {
      Button("Delete Profile and Its Data", role: .destructive) {
        guard let profile = deleting else { return }
        deleting = nil
        Task {
          do throws(BrowserError) {
            try await store.delete(id: profile.id)
          } catch let failure {
            error = failure
          }
        }
      }
      Button("Cancel", role: .cancel) { deleting = nil }
    } message: {
      Text("Its tabs close, and its cookies, history, bookmarks and site settings are removed.")
    }
    .accessibilityIdentifier("browser.profiles")
  }

  private func save(_ edited: BrowserUserProfile) {
    run { () throws(BrowserError) in
      if store.profile(id: edited.id) == nil {
        try store.create(name: edited.name, color: edited.color, avatar: edited.avatar)
      } else {
        try store.update(edited)
      }
    }
  }

  private func run(_ change: () throws(BrowserError) -> Void) {
    do {
      try change()
      error = nil
    } catch let failure {
      error = failure
    }
  }
}

/// Name, color and avatar of one profile.
struct BrowserProfileEditor: View {
  @State private var profile: BrowserUserProfile
  let isNew: Bool
  let save: (BrowserUserProfile) -> Void
  @State private var emoji = ""
  @Environment(\.dismiss) private var dismiss

  init(profile: BrowserUserProfile, isNew: Bool, save: @escaping (BrowserUserProfile) -> Void) {
    _profile = State(initialValue: profile)
    self.isNew = isNew
    self.save = save
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        BrowserProfileAvatarView(profile: profile, size: 44)
        TextField("Name", text: $profile.name)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("browser.profileEditor.name")
      }
      Text("Color").font(.headline)
      HStack {
        ForEach(BrowserProfileColor.allCases, id: \.self) { color in
          Button {
            profile.color = color
          } label: {
            Circle().fill(color.color).frame(width: 22, height: 22)
              .overlay {
                if profile.color == color { Circle().strokeBorder(.primary, lineWidth: 2) }
              }
          }
          .buttonStyle(.plain)
          .accessibilityLabel(color.displayName)
        }
      }
      Text("Avatar").font(.headline)
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 7), alignment: .leading) {
        avatarButton(.initials) { Text(profile.initials).font(.caption.bold()) }
        ForEach(BrowserProfileAvatar.symbols, id: \.self) { symbol in
          avatarButton(.symbol(symbol)) { Image(systemName: symbol).accessibilityLabel(symbol) }
        }
      }
      HStack {
        TextField("Or an emoji", text: $emoji)
          .textFieldStyle(.roundedBorder)
          .frame(width: 120)
          .onChange(of: emoji) { _, value in
            if let first = value.first { profile.avatar = .emoji(String(first)) }
          }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button(isNew ? "Add" : "Save") {
          save(profile)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityIdentifier("browser.profileEditor.save")
      }
    }
    .padding(20)
    .frame(width: 380)
  }

  private func avatarButton(_ avatar: BrowserProfileAvatar, @ViewBuilder label: () -> some View)
    -> some View
  {
    Button {
      profile.avatar = avatar
    } label: {
      label()
        .frame(width: 26, height: 26)
        .background(
          profile.avatar == avatar ? profile.color.color.opacity(0.3) : Color.clear,
          in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
  }
}

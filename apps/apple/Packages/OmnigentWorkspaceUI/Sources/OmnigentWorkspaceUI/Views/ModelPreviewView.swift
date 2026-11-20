import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI

/// A 3D model in an interactive view (the web's `ModelViewer`): drag to orbit, scroll or pinch
/// to zoom, lit and framed by the system. STL carries no material, so it gets a plain one.
struct ModelPreviewView: View {
  let format: ModelFormat
  let data: Data
  let truncated: Bool
  @State private var loaded: Loaded?

  /// The scene read from `data`; `nil` when the reader could not open it.
  private struct Loaded {
    let data: Data
    let scene: SCNScene?
  }

  var body: some View {
    Group {
      if truncated {
        note(Self.truncatedMessage)
      } else if !Self.canRead(format) {
        note("This 3D format can\u{2019}t be previewed here. Download the file to open it.")
      } else if let loaded, loaded.data == data {
        if let scene = loaded.scene {
          ModelScene(scene: scene)
            .accessibilityLabel("3D model")
            .accessibilityIdentifier("workspace.model")
        } else {
          note("Unable to render this 3D model.")
        }
      } else {
        ProgressView("Loading 3D model\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: data) {
      guard !truncated, Self.canRead(format) else { return }
      loaded = Loaded(data: data, scene: Self.scene(data, format: format))
    }
  }

  private func note(_ message: String) -> some View {
    Text(message)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("workspace.model.note")
  }

  /// What a model the server cut shows, as a PDF's does.
  static let truncatedMessage = "3D model is too large to preview (truncated by the server)."

  /// The file extension Model I/O reads the format by.
  static func fileExtension(_ format: ModelFormat) -> String {
    switch format {
    case .stl: "stl"
    case .threeMf: "3mf"
    case .obj: "obj"
    }
  }

  /// Whether this device's Model I/O reads the format.
  static func canRead(_ format: ModelFormat) -> Bool {
    MDLAsset.canImportFileExtension(fileExtension(format))
  }

  /// The model as a scene, read through a temporary file, as Model I/O reads by name.
  static func scene(_ data: Data, format: ModelFormat) -> SCNScene? {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "omnigent-model-\(UUID().uuidString).\(fileExtension(format))")
    defer { try? FileManager.default.removeItem(at: url) }
    guard (try? data.write(to: url)) != nil else { return nil }
    let asset = MDLAsset(url: url)
    // Model I/O reads what it cannot parse as an empty asset.
    guard asset.count >= 1 else { return nil }
    asset.loadTextures()
    let scene = SCNScene(mdlAsset: asset)
    if format == .stl {
      for node in meshes(in: scene) { node.geometry?.materials = [plainMaterial()] }
    }
    return scene
  }

  /// The scene's nodes that draw geometry.
  static func meshes(in scene: SCNScene) -> [SCNNode] {
    var pending = [scene.rootNode]
    var meshes: [SCNNode] = []
    while let node = pending.popLast() {
      if node.geometry != nil { meshes.append(node) }
      pending += node.childNodes
    }
    return meshes
  }

  private static func plainMaterial() -> SCNMaterial {
    let material = SCNMaterial()
    material.lightingModel = .physicallyBased
    material.metalness.contents = 0.1
    material.roughness.contents = 0.6
    #if os(macOS)
      material.diffuse.contents = NSColor.systemGray
    #else
      material.diffuse.contents = UIColor.systemGray
    #endif
    return material
  }
}

/// SceneKit's view: system lighting, the camera framing the model, orbit and zoom by hand.
private struct ModelScene {
  let scene: SCNScene

  func make() -> SCNView {
    let view = SCNView()
    view.scene = scene
    view.autoenablesDefaultLighting = true
    view.allowsCameraControl = true
    view.backgroundColor = .clear
    view.antialiasingMode = .multisampling4X
    return view
  }

  func update(_ view: SCNView) {
    if view.scene !== scene { view.scene = scene }
  }
}

#if os(macOS)
  extension ModelScene: NSViewRepresentable {
    func makeNSView(context: Context) -> SCNView { make() }
    func updateNSView(_ view: SCNView, context: Context) { update(view) }
  }
#else
  extension ModelScene: UIViewRepresentable {
    func makeUIView(context: Context) -> SCNView { make() }
    func updateUIView(_ view: SCNView, context: Context) { update(view) }
  }
#endif

import SwiftUI

/// A flow as a script: an initial model and steps that change it through the same view-state
/// types and actions the app uses. A step's model is the initial one with every step on its path
/// applied, so any step can be shown, exported or tested on its own.
struct CatalogFlowScript<Model> {
  struct Step {
    let id: String
    let title: String
    let note: String
    /// The step this one branches from, instead of the one before it.
    let branchesFrom: String?
    let apply: @MainActor (inout Model) -> Void

    init(
      _ id: String, _ title: String, note: String, branchesFrom: String? = nil,
      apply: @escaping @MainActor (inout Model) -> Void = { _ in }
    ) {
      self.id = id
      self.title = title
      self.note = note
      self.branchesFrom = branchesFrom
      self.apply = apply
    }
  }

  let initial: @MainActor (CatalogContext) -> Model
  let steps: [Step]
  let render: @MainActor (Binding<Model>, CatalogContext) -> AnyView

  /// The indices of the steps applied to reach `index`, in order: its branch ancestors, then the
  /// step itself.
  func path(to index: Int) -> [Int] {
    var path: [Int] = []
    var current: Int? = index
    while let step = current, steps.indices.contains(step), !path.contains(step) {
      path.insert(step, at: 0)
      if let parent = steps[step].branchesFrom {
        current = steps.firstIndex { $0.id == parent }
      } else {
        current = step > 0 ? step - 1 : nil
      }
    }
    return path
  }

  /// The model at step `index`.
  func model(at index: Int, context: CatalogContext) -> Model {
    var model = initial(context)
    for step in path(to: index) { steps[step].apply(&model) }
    return model
  }

  /// The steps as catalog states, each rendering its own copy of the model.
  var states: [CatalogState] {
    steps.indices.map { index in
      let step = steps[index]
      return CatalogState(
        step.id, step.title, note: step.note, branchesFrom: step.branchesFrom
      ) { context in
        AnyView(
          CatalogFlowStepHost(
            model: model(at: index, context: context), context: context, render: render))
      }
    }
  }
}

/// Holds one step's model, so interacting with a step keeps its changes while it is shown.
private struct CatalogFlowStepHost<Model>: View {
  @State private var model: Model
  let context: CatalogContext
  let render: @MainActor (Binding<Model>, CatalogContext) -> AnyView

  init(
    model: Model, context: CatalogContext,
    render: @escaping @MainActor (Binding<Model>, CatalogContext) -> AnyView
  ) {
    _model = State(initialValue: model)
    self.context = context
    self.render = render
  }

  var body: some View { render($model, context) }
}

/// Back and Next through a flow's steps in list order.
struct CatalogFlowNavigator: Hashable {
  let stepIDs: [String]
  private(set) var index: Int

  init(stepIDs: [String], current: String? = nil) {
    self.stepIDs = stepIDs
    index = current.flatMap { stepIDs.firstIndex(of: $0) } ?? 0
  }

  var currentID: String? { stepIDs.indices.contains(index) ? stepIDs[index] : nil }
  var canGoBack: Bool { index > 0 }
  var canGoNext: Bool { index + 1 < stepIDs.count }
  var position: String { stepIDs.isEmpty ? "No steps" : "Step \(index + 1) of \(stepIDs.count)" }

  mutating func next() {
    if canGoNext { index += 1 }
  }

  mutating func back() {
    if canGoBack { index -= 1 }
  }

  mutating func jump(to id: String) {
    if let target = stepIDs.firstIndex(of: id) { index = target }
  }
}

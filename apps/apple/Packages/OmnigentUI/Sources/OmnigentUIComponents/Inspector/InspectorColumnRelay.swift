import Observation
import SwiftUI

/// The Mac inspector column's binding. SwiftUI reports each collapse or expand once its animation
/// ends, through the binding the inspector was made with, and late on a busy main thread: by then
/// the column may have been handed another session's panel. A report goes to the binding the
/// column was handed last, and only when it is not the end of an earlier hand-off.
@MainActor
@Observable
final class InspectorColumnRelay {
  /// The binding of the column's latest update.
  @ObservationIgnored private var handed: Binding<Bool>?
  /// What that binding handed out.
  @ObservationIgnored private var handedValue = false
  /// The column has reported what it was handed last, or was made with it.
  @ObservationIgnored private var isSettled = true
  /// SwiftUI is shown where an earlier hand-off left the column, for one update, so that it
  /// then moves the column to what it was handed since.
  private var isShowingLeftover = false
  /// Whether that hand-off left the column shown.
  @ObservationIgnored private var leftoverShown = false
  /// Ends the leftover's update.
  @ObservationIgnored private var restore: Task<Void, Never>?

  /// Notes what the column is handed in this update.
  /// - Parameter binding: The column's binding in this update.
  /// - Returns: The binding for the inspector to present and report through.
  @discardableResult
  func hand(_ binding: Binding<Bool>) -> Binding<Bool> {
    let value = binding.wrappedValue
    if handed != nil, value != handedValue { isSettled = false }
    handed = binding
    handedValue = value
    if isShowingLeftover, restore == nil {
      restore = Task { @MainActor [weak self] in
        self?.isShowingLeftover = false
        self?.restore = nil
      }
    }
    return Bindable(self).isPresented
  }

  /// Whether the column shows.
  var isPresented: Bool {
    get { isShowingLeftover ? leftoverShown : handed?.wrappedValue ?? false }
    set { report(newValue) }
  }

  /// The column reports whether it shows. Showing what it was handed chooses nothing; anything
  /// else before that is the end of an earlier collapse or expand: it is dropped, and the column
  /// moved to what it was handed. Once settled, a change (the column dragged shut) goes to the
  /// binding it was handed last.
  /// - Parameter isShown: Whether the column shows.
  func report(_ isShown: Bool) {
    if isShown == handedValue {
      isSettled = true
    } else if isSettled {
      // The column shows this already: handing it back is no change to wait on.
      handedValue = isShown
      handed?.wrappedValue = isShown
    } else {
      leftoverShown = isShown
      isShowingLeftover = true
    }
  }
}

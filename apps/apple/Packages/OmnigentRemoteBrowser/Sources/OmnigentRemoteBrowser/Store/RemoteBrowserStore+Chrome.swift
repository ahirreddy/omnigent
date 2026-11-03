extension RemoteBrowserStore {
  /// Zooms the page back out to fit (iOS local zoom).
  public func resetZoom() {
    zoomResets += 1
  }

  /// Samples the top edge 300 ms after video arrives, at most once per 300 ms, so the tint
  /// follows the page without reading every frame.
  func scheduleEdgeSample() {
    #if os(iOS)
      guard edgeSample == nil else { return }
      edgeSample = Task { [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(300))
        } catch {
          return  // Cancelled.
        }
        guard let self else { return }
        self.edgeSample = nil
        let sampled = self.renderer?.sampleTopEdge()
        switch (sampled, self.edgeColor) {
        case (nil, nil): break
        case (let new?, let old?) where new.isClose(to: old): break
        default: self.edgeColor = sampled
        }
      }
    #endif
  }
}

#if os(iOS)
  import Foundation
  import Synchronization

  /// Draws runs that rows show already at a new width, off the main actor, the one nearest the
  /// reader first, and hands each drawing to the main actor. A row keeps its old drawing until
  /// its new one lands, so a width change (a rotation, iPad's sidebar) draws nothing on the main
  /// thread.
  nonisolated final class MessageTextRunRedraws: Sendable {
    static let shared = MessageTextRunRedraws(workers: MessageTextRunPrewarm.workers)

    /// Takes a drawing on the main actor.
    typealias Landed = @MainActor @Sendable (MessageTextRaster) -> Void

    /// A run to draw, where its row is in the transcript, and who takes the drawing.
    private struct Request: Sendable {
      var document: MessageTextDocument
      var style: MessageTextRasterStyle
      var position: Double
      var landed: [Landed]
    }

    private struct State: Sendable {
      var waiting: [MessageTextRasterKey: Request] = [:]
      /// Drawings under way, and who takes them.
      var running: [MessageTextRasterKey: [Landed]] = [:]
      /// Where the reader is in the transcript.
      var focus: Double = 0
      var workers = 0
    }

    private let workerLimit: Int
    private let rasters: MessageTextRasters
    private let sizes: MessageTextSizes
    private let state = Mutex(State())

    /// - Parameters:
    ///   - workers: How many runs draw at once; with none, requests only wait, for tests.
    ///   - rasters: Where drawings are kept.
    ///   - sizes: Where their sizes are kept.
    init(workers: Int, rasters: MessageTextRasters = .shared, sizes: MessageTextSizes = .shared) {
      workerLimit = max(0, workers)
      self.rasters = rasters
      self.sizes = sizes
    }

    /// Draws `document` at the width and scale of `key` in `style`, then hands the drawing to
    /// `landed` on the main actor. The run's row is at `position` in the transcript; a request
    /// for another width of the same run, which the row no longer wants, goes.
    func draw(
      _ document: MessageTextDocument, as key: MessageTextRasterKey,
      style: MessageTextRasterStyle, at position: Double, landed: @escaping Landed
    ) {
      let starts = state.withLock { state -> Bool in
        if state.running[key] != nil {
          state.running[key]?.append(landed)
          return false
        }
        for stale in state.waiting.keys where stale.document == key.document && stale != key {
          state.waiting[stale] = nil
        }
        if var request = state.waiting[key] {
          request.position = position
          request.landed.append(landed)
          state.waiting[key] = request
          return false
        }
        state.waiting[key] = Request(
          document: document, style: style, position: position, landed: [landed])
        guard state.workers < workerLimit else { return false }
        state.workers += 1
        return true
      }
      if starts { startWorker() }
    }

    /// Where the reader is in the transcript: the drawing nearest goes next.
    func focus(at position: Double) {
      state.withLock { $0.focus = position }
    }

    /// The drawings waiting, nearest the reader first, for tests.
    var waitingKeys: [MessageTextRasterKey] {
      state.withLock { state in
        state.waiting.sorted {
          abs($0.value.position - state.focus) < abs($1.value.position - state.focus)
        }.map(\.key)
      }
    }

    private func startWorker() {
      Task.detached(priority: .userInitiated) { [self] in
        while let (key, request) = next() {
          let raster = rasters.raster(for: key) ?? draw(request, key: key)
          let landed = finish(key)
          MainRunLoop.perform {
            MainActor.assumeIsolated {
              for take in landed { take(raster) }
            }
          }
        }
      }
    }

    private func draw(_ request: Request, key: MessageTextRasterKey) -> MessageTextRaster {
      let raster = MessageTextRaster.make(
        request.document.run, width: key.width, scale: key.scale, style: request.style)
      rasters.store(raster, for: key)
      sizes.store(raster.size, document: key.document, width: key.width)
      return raster
    }

    /// The waiting drawing nearest the reader, now under way; `nil` ends the worker.
    private func next() -> (MessageTextRasterKey, Request)? {
      state.withLock { state in
        let focus = state.focus
        guard
          let key = state.waiting.min(by: {
            abs($0.value.position - focus) < abs($1.value.position - focus)
          })?.key,
          let request = state.waiting.removeValue(forKey: key)
        else {
          state.workers -= 1
          return nil
        }
        state.running[key] = request.landed
        return (key, request)
      }
    }

    /// Who takes the drawing for `key`, which is no longer under way.
    private func finish(_ key: MessageTextRasterKey) -> [Landed] {
      state.withLock { $0.running.removeValue(forKey: key) ?? [] }
    }
  }
#endif

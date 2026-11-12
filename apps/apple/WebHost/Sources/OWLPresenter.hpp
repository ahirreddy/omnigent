// Delivers a view's pixels to the client: copies each CEF frame into host-owned IOSurfaces and
// either draws them in a CAContext the client embeds with CALayerHost (remote-layer mode) or
// sends the IOSurface Mach ports over the channel (iosurface mode). See DESIGN.md, "Rendering".
#pragma once

#include <IOSurface/IOSurfaceRef.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "owl_protocol.h"

namespace owl {

class Presenter {
 public:
  Presenter(uint64_t view_id, OWLRenderMode mode);
  ~Presenter();
  Presenter(const Presenter&) = delete;
  Presenter& operator=(const Presenter&) = delete;

  /// Sets up the mode. Remote-layer mode fails when the private CAContext API is missing.
  bool Start(std::string* error);
  void SetGeometry(double width, double height, double scale);
  /// Copies `source` (a CEF shared texture, valid only during the call) and presents it.
  /// Returns false when every buffer was busy and the frame was dropped: the page must be
  /// painted again, or it stays on the frame before this one.
  bool PresentAccelerated(OWLLayer layer, IOSurfaceRef source, int x, int y, int width,
                          int height, uint64_t paint_nanos);
  /// CPU fallback for frames CEF delivers through OnPaint. Returns false as above.
  bool PresentPixels(OWLLayer layer, const void* bgra, int width, int height,
                     uint64_t paint_nanos);
  void SetPopupVisible(bool visible);
  void SetPopupRect(double x, double y, double width, double height);
  /// iosurface mode: the client no longer displays surface `surface_id`.
  void AcknowledgeFrame(uint32_t surface_id);
  /// Whether a page frame has been presented.
  bool HasFrame() const;
  /// Frames put on screen or sent to the client so far, on both layers.
  uint64_t FramesDelivered() const;
  /// The page layer's buffers, for freeze diagnostics: how many exist, how many the window
  /// server still reads, and how many the client has not acknowledged.
  struct RingState {
    size_t slots = 0;
    size_t in_use = 0;
    size_t awaiting_ack = 0;
    uint64_t dropped = 0;
  };
  RingState PageRing() const;
  /// The most page buffers that were busy when a frame needed one, since the view began: at
  /// the ring's size, frames were dropped. Costs nothing to read.
  size_t PageRingBusyPeak() const;
  size_t PageRingSlots() const;
  /// PNG of the page with the open popup composited in, as the user sees it.
  bool Snapshot(std::vector<uint8_t>* png, std::string* error) const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

/// Monotonic nanoseconds on a clock shared by every process (CLOCK_UPTIME_RAW).
uint64_t NowNanos();

}  // namespace owl

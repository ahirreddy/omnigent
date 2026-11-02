#include "core/frame_sink.h"

#include <chrono>
#include <cstring>

namespace rb {

uint64_t MonotonicMicros() {
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
                                   std::chrono::steady_clock::now().time_since_epoch())
                                   .count());
}

void FrameSink::Resize(int width, int height) {
  std::lock_guard<std::mutex> lock(mutex_);
  width_ = std::max(width, 0);
  height_ = std::max(height, 0);
  const size_t bytes = static_cast<size_t>(width_) * height_ * 4;
  view_.assign(bytes, 0xFF);
  canvas_.assign(bytes, 0xFF);
  has_content_ = false;
  damage_.Clear();
  damage_.Add({0, 0, width_, height_});
}

void FrameSink::PaintView(const std::vector<PixelRect>& dirty, const void* buffer, int width,
                          int height) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (width != width_ || height != height_) {
    // A paint from before a resize: CEF repaints at the new size next.
    return;
  }
  const auto* source = static_cast<const uint8_t*>(buffer);
  const PixelRect bounds{0, 0, width_, height_};
  const size_t stride = static_cast<size_t>(width_) * 4;
  for (const PixelRect& unclipped : dirty) {
    const PixelRect rect = unclipped.Intersect(bounds);
    if (rect.empty()) {
      continue;
    }
    for (int row = rect.y; row < rect.bottom(); ++row) {
      const size_t offset = row * stride + static_cast<size_t>(rect.x) * 4;
      std::memcpy(view_.data() + offset, source + offset, static_cast<size_t>(rect.width) * 4);
    }
    ComposeLocked(rect);
    damage_.Add(rect);
  }
  has_content_ = true;
  last_paint_us_ = MonotonicMicros();
}

void FrameSink::PaintPopup(const void* buffer, int width, int height) {
  std::lock_guard<std::mutex> lock(mutex_);
  popup_width_ = width;
  popup_height_ = height;
  popup_.assign(static_cast<const uint8_t*>(buffer),
                static_cast<const uint8_t*>(buffer) + static_cast<size_t>(width) * height * 4);
  if (popup_visible_) {
    ComposeLocked(popup_rect_);
    damage_.Add(popup_rect_.Intersect({0, 0, width_, height_}));
    last_paint_us_ = MonotonicMicros();
  }
}

void FrameSink::SetPopupVisible(bool visible) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (popup_visible_ == visible) {
    return;
  }
  popup_visible_ = visible;
  if (!visible) {
    popup_.clear();
  }
  ComposeLocked(popup_rect_);
  damage_.Add(popup_rect_.Intersect({0, 0, width_, height_}));
  last_paint_us_ = MonotonicMicros();
}

void FrameSink::SetPopupRect(const PixelRect& rect) {
  std::lock_guard<std::mutex> lock(mutex_);
  const PixelRect old_rect = popup_rect_;
  popup_rect_ = rect;
  ComposeLocked(old_rect);
  ComposeLocked(rect);
  damage_.Add(old_rect.Intersect({0, 0, width_, height_}));
  damage_.Add(rect.Intersect({0, 0, width_, height_}));
}

void FrameSink::ComposeLocked(const PixelRect& unclipped) {
  const PixelRect rect = unclipped.Intersect({0, 0, width_, height_});
  if (rect.empty()) {
    return;
  }
  const size_t stride = static_cast<size_t>(width_) * 4;
  for (int row = rect.y; row < rect.bottom(); ++row) {
    const size_t offset = row * stride + static_cast<size_t>(rect.x) * 4;
    std::memcpy(canvas_.data() + offset, view_.data() + offset,
                static_cast<size_t>(rect.width) * 4);
  }
  if (!popup_visible_ || popup_.empty()) {
    return;
  }
  const PixelRect popup = popup_rect_.Intersect(rect);
  const int columns = std::min(popup.width, popup_width_ - (popup.x - popup_rect_.x));
  if (popup.empty() || columns <= 0) {
    return;
  }
  for (int row = popup.y; row < popup.bottom(); ++row) {
    const int popup_row = row - popup_rect_.y;
    if (popup_row >= popup_height_) {
      break;
    }
    const size_t source = (static_cast<size_t>(popup_row) * popup_width_ +
                           static_cast<size_t>(popup.x - popup_rect_.x)) *
                          4;
    std::memcpy(canvas_.data() + row * stride + static_cast<size_t>(popup.x) * 4,
                popup_.data() + source, static_cast<size_t>(columns) * 4);
  }
}

void FrameSink::DamageAll() {
  std::lock_guard<std::mutex> lock(mutex_);
  damage_.Clear();
  damage_.Add({0, 0, width_, height_});
}

bool FrameSink::HasDamage() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return !damage_.empty();
}

bool FrameSink::HasContent() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return has_content_;
}

int FrameSink::width() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return width_;
}

int FrameSink::height() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return height_;
}

uint64_t FrameSink::last_paint_us() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return last_paint_us_;
}

long long FrameSink::TakeFrame(I420Frame* frame, uint64_t* capture_us) {
  std::lock_guard<std::mutex> lock(mutex_);
  *capture_us = last_paint_us_ != 0 ? last_paint_us_ : MonotonicMicros();
  if (width_ == 0 || height_ == 0) {
    damage_.Clear();
    return 0;
  }
  const int even_width = (width_ + 1) & ~1;
  const int even_height = (height_ + 1) & ~1;
  if (frame->width() != even_width || frame->height() != even_height) {
    frame->Resize(width_, height_);
    damage_.Clear();
    damage_.Add({0, 0, width_, height_});
  }
  const long long area = damage_.area();
  const int stride = width_ * 4;
  for (const PixelRect& rect : damage_.rects()) {
    // Padding columns and rows replicate the edge, so damage there extends into the padding.
    PixelRect grown = rect;
    if (grown.right() == width_) {
      grown.width += even_width - width_;
    }
    if (grown.bottom() == height_) {
      grown.height += even_height - height_;
    }
    ConvertBgraToI420(canvas_.data(), stride, width_, height_, grown, frame);
  }
  damage_.Clear();
  return area;
}

void FrameSink::CopyCanvas(std::vector<uint8_t>* bgra, int* width, int* height) const {
  std::lock_guard<std::mutex> lock(mutex_);
  *bgra = canvas_;
  *width = width_;
  *height = height_;
}

}  // namespace rb

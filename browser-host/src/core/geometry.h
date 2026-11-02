// Integer pixel rectangles and a small damage accumulator.
#pragma once

#include <algorithm>
#include <vector>

namespace rb {

struct PixelRect {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;

  bool empty() const { return width <= 0 || height <= 0; }
  int right() const { return x + width; }
  int bottom() const { return y + height; }
  long long area() const { return empty() ? 0 : static_cast<long long>(width) * height; }
  bool operator==(const PixelRect&) const = default;

  PixelRect Intersect(const PixelRect& other) const {
    const int left = std::max(x, other.x);
    const int top = std::max(y, other.y);
    const int right_edge = std::min(right(), other.right());
    const int bottom_edge = std::min(bottom(), other.bottom());
    if (right_edge <= left || bottom_edge <= top) {
      return {};
    }
    return {left, top, right_edge - left, bottom_edge - top};
  }

  PixelRect Union(const PixelRect& other) const {
    if (empty()) {
      return other;
    }
    if (other.empty()) {
      return *this;
    }
    const int left = std::min(x, other.x);
    const int top = std::min(y, other.y);
    return {left, top, std::max(right(), other.right()) - left,
            std::max(bottom(), other.bottom()) - top};
  }

  /// Grows the rect outwards to even coordinates (4:2:0 chroma blocks), clipped to `bounds`.
  PixelRect AlignedToEven(const PixelRect& bounds) const {
    const int left = x & ~1;
    const int top = y & ~1;
    const int right_edge = (right() + 1) & ~1;
    const int bottom_edge = (bottom() + 1) & ~1;
    return PixelRect{left, top, right_edge - left, bottom_edge - top}.Intersect(bounds);
  }
};

/// Accumulates damaged rects. Past `kMaxRects` it collapses them into their bounding box.
class Damage {
 public:
  static constexpr size_t kMaxRects = 8;

  void Add(const PixelRect& rect) {
    if (rect.empty()) {
      return;
    }
    for (PixelRect& existing : rects_) {
      if (!existing.Intersect(rect).empty()) {
        existing = existing.Union(rect);
        return;
      }
    }
    rects_.push_back(rect);
    if (rects_.size() > kMaxRects) {
      PixelRect bounds;
      for (const PixelRect& existing : rects_) {
        bounds = bounds.Union(existing);
      }
      rects_.assign(1, bounds);
    }
  }

  bool empty() const { return rects_.empty(); }
  const std::vector<PixelRect>& rects() const { return rects_; }
  void Clear() { rects_.clear(); }
  long long area() const {
    long long total = 0;
    for (const PixelRect& rect : rects_) {
      total += rect.area();
    }
    return total;
  }

 private:
  std::vector<PixelRect> rects_;
};

}  // namespace rb

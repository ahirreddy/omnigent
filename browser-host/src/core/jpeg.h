// Baseline JPEG (JFIF, 4:2:0) stills and thumbnails from the BGRA canvas, via libjpeg-turbo.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace rb {

/// Encodes a BGRA image (stride width*4). `quality` is 1-100.
bool EncodeJpeg(const uint8_t* bgra, int width, int height, int quality, std::vector<uint8_t>* out,
                std::string* error);

/// Box-filters a BGRA image down so it is at most `max_width` wide (aspect kept).
void DownscaleBgra(const uint8_t* bgra, int width, int height, int max_width,
                   std::vector<uint8_t>* out, int* out_width, int* out_height);

}  // namespace rb

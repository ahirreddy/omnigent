#include "core/jpeg.h"

#include <algorithm>
#include <csetjmp>
#include <cstdio>
#include <cstdlib>

#include <jpeglib.h>

namespace rb {

namespace {

struct ErrorManager {
  jpeg_error_mgr base;
  std::jmp_buf jump;
  char message[JMSG_LENGTH_MAX];
};

void OnJpegError(j_common_ptr info) {
  auto* manager = reinterpret_cast<ErrorManager*>(info->err);
  (*info->err->format_message)(info, manager->message);
  std::longjmp(manager->jump, 1);
}

}  // namespace

bool EncodeJpeg(const uint8_t* bgra, int width, int height, int quality, std::vector<uint8_t>* out,
                std::string* error) {
  if (width <= 0 || height <= 0) {
    *error = "cannot encode an empty image";
    return false;
  }
  jpeg_compress_struct info{};
  ErrorManager manager{};
  info.err = jpeg_std_error(&manager.base);
  manager.base.error_exit = OnJpegError;
  unsigned char* buffer = nullptr;
  unsigned long size = 0;
  if (setjmp(manager.jump) != 0) {
    jpeg_destroy_compress(&info);
    std::free(buffer);
    *error = std::string("JPEG encoding failed: ") + manager.message;
    return false;
  }
  jpeg_create_compress(&info);
  jpeg_mem_dest(&info, &buffer, &size);
  info.image_width = static_cast<JDIMENSION>(width);
  info.image_height = static_cast<JDIMENSION>(height);
  info.input_components = 4;
  info.in_color_space = JCS_EXT_BGRA;
  jpeg_set_defaults(&info);
  jpeg_set_quality(&info, quality, TRUE);
  info.dct_method = JDCT_ISLOW;
  jpeg_start_compress(&info, TRUE);
  const size_t stride = static_cast<size_t>(width) * 4;
  while (info.next_scanline < info.image_height) {
    JSAMPROW row = const_cast<JSAMPROW>(bgra + info.next_scanline * stride);
    jpeg_write_scanlines(&info, &row, 1);
  }
  jpeg_finish_compress(&info);
  out->assign(buffer, buffer + size);
  jpeg_destroy_compress(&info);
  std::free(buffer);
  return true;
}

void DownscaleBgra(const uint8_t* bgra, int width, int height, int max_width,
                   std::vector<uint8_t>* out, int* out_width, int* out_height) {
  if (width <= max_width) {
    out->assign(bgra, bgra + static_cast<size_t>(width) * height * 4);
    *out_width = width;
    *out_height = height;
    return;
  }
  const int target_width = max_width;
  const int target_height =
      std::max(1, static_cast<int>(static_cast<long long>(height) * target_width / width));
  out->assign(static_cast<size_t>(target_width) * target_height * 4, 0);
  for (int y = 0; y < target_height; ++y) {
    const int y0 = static_cast<int>(static_cast<long long>(y) * height / target_height);
    const int y1 =
        std::max(y0 + 1, static_cast<int>(static_cast<long long>(y + 1) * height / target_height));
    for (int x = 0; x < target_width; ++x) {
      const int x0 = static_cast<int>(static_cast<long long>(x) * width / target_width);
      const int x1 =
          std::max(x0 + 1, static_cast<int>(static_cast<long long>(x + 1) * width / target_width));
      unsigned sums[4] = {0, 0, 0, 0};
      for (int source_y = y0; source_y < y1; ++source_y) {
        const uint8_t* row = bgra + (static_cast<size_t>(source_y) * width + x0) * 4;
        for (int source_x = x0; source_x < x1; ++source_x, row += 4) {
          for (int channel = 0; channel < 4; ++channel) {
            sums[channel] += row[channel];
          }
        }
      }
      const unsigned count = static_cast<unsigned>((y1 - y0) * (x1 - x0));
      uint8_t* pixel = out->data() + (static_cast<size_t>(y) * target_width + x) * 4;
      for (int channel = 0; channel < 4; ++channel) {
        pixel[channel] = static_cast<uint8_t>(sums[channel] / count);
      }
    }
  }
  *out_width = target_width;
  *out_height = target_height;
}

}  // namespace rb

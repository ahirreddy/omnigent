// Exercises the real system encoder (x264 or ffmpeg) when one is installed; skipped otherwise.
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <mutex>

#include "core/encoder.h"
#include "core/h264.h"
#include "test.h"

namespace {

struct Collector {
  std::mutex mutex;
  std::condition_variable changed;
  std::vector<rb::EncodedFrame> frames;
  std::vector<std::string> errors;

  bool WaitFor(size_t count) {
    std::unique_lock<std::mutex> lock(mutex);
    return changed.wait_for(lock, std::chrono::seconds(10), [&] { return frames.size() >= count; });
  }
};

void Pattern(rb::I420Frame* frame, int seed) {
  for (int y = 0; y < frame->height(); ++y) {
    for (int x = 0; x < frame->width(); ++x) {
      frame->y()[y * frame->width() + x] = static_cast<uint8_t>((x + y * 3 + seed * 17) & 0xFF);
    }
  }
}

void RunEncoder(const rb::EncoderInfo& info) {
  rb::SubprocessEncoder encoder(info, RB_SHIM_LIBRARY, "/tmp");
  Collector collector;
  rb::EncoderSettings settings;
  settings.width = 320;
  settings.height = 240;
  settings.fps = 30;
  settings.bitrate_kbps = 800;
  std::string error;
  CHECK_MSG(encoder.Start(
                settings,
                [&](rb::EncodedFrame frame) {
                  std::lock_guard<std::mutex> lock(collector.mutex);
                  collector.frames.push_back(std::move(frame));
                  collector.changed.notify_all();
                },
                [&](const std::string& message) {
                  std::lock_guard<std::mutex> lock(collector.mutex);
                  collector.errors.push_back(message);
                },
                &error),
            error);
  rb::I420Frame frame;
  frame.Resize(320, 240);
  for (int index = 0; index < 8; ++index) {
    Pattern(&frame, index);
    CHECK_MSG(encoder.Submit(frame, 1000 + index, index == 5, &error), error);
    // One frame out per frame in: the pipe has no buffering delay.
    CHECK_MSG(collector.WaitFor(static_cast<size_t>(index) + 1),
              std::string(info.path) + " did not produce frame " + std::to_string(index));
  }
  encoder.Stop();
  std::lock_guard<std::mutex> lock(collector.mutex);
  CHECK_EQ(collector.frames.size(), 8u);
  for (size_t index = 0; index < collector.frames.size(); ++index) {
    const rb::EncodedFrame& encoded = collector.frames[index];
    const bool expect_key = index == 0 || index == 5;
    CHECK_MSG(encoded.keyframe == expect_key, info.path + " frame " + std::to_string(index));
    CHECK_EQ(encoded.pts_us, 1000u + index);
    if (expect_key) {
      std::vector<uint8_t> types;
      for (const rb::NalUnit& nal : rb::SplitAnnexB(encoded.annexb.data(), encoded.annexb.size())) {
        types.push_back(nal.type());
      }
      CHECK_MSG(types.size() >= 3 && types[0] == rb::kNalSps && types[1] == rb::kNalPps,
                "keyframes must lead with SPS and PPS");
      // Constrained Baseline: profile_idc 66 with constraint_set1.
      const auto nals = rb::SplitAnnexB(encoded.annexb.data(), encoded.annexb.size());
      CHECK_EQ(nals[0].data[1], 66);
      CHECK((nals[0].data[2] & 0x40) != 0);
    }
  }
  CHECK_MSG(collector.errors.empty(), collector.errors.empty() ? "" : collector.errors[0]);
  CHECK(encoder.CpuSeconds() > 0);
}

}  // namespace

TEST(EncoderX264ProducesOneAccessUnitPerFrameWithForcedIdr) {
  rb::EncoderInfo info;
  std::string error;
  if (!rb::ResolveEncoder("x264", &info, &error)) {
    std::fprintf(stderr, "skip: %s\n", error.c_str());
    return;
  }
  RunEncoder(info);
}

TEST(EncoderFfmpegProducesOneAccessUnitPerFrameWithForcedIdr) {
  rb::EncoderInfo info;
  std::string error;
  if (!rb::ResolveEncoder("ffmpeg", &info, &error)) {
    std::fprintf(stderr, "skip: %s\n", error.c_str());
    return;
  }
  RunEncoder(info);
}

TEST(EncoderResolveRejectsMissingBinaries) {
  rb::EncoderInfo info;
  std::string error;
  CHECK(!rb::ResolveEncoder("/nonexistent/x264", &info, &error));
  CHECK(!error.empty());
}

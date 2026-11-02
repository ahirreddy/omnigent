// rb_encode_bench: replays a BGRA recording (TabStreamer::StartRecording format) through the
// same SubprocessEncoder the host uses, one frame at a time, and reports per-frame encode wall
// time, encoder CPU, conversion time and bitrate as JSON.
//
//   rb_encode_bench --input rec.bgra [--encoder x264|ffmpeg|PATH] [--fps 15] [--crf 24]
//                   [--bitrate-kbps N] [--threads 1] [--preset ultrafast]
//                   [--out stream.h264] [--yuv-out reference.yuv] [--max-frames N]
#include <signal.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

#include "core/encoder.h"
#include "core/frame_sink.h"
#include "core/json.h"
#include "core/stream.h"
#include "core/yuv.h"

namespace {

struct Options {
  std::string input;
  std::string encoder;
  std::string out;
  std::string yuv_out;
  std::string preset = "ultrafast";
  int fps = 15;
  int crf = 24;
  int bitrate_kbps = 0;
  int threads = 1;
  int max_frames = 0;
  double vbv_frames = 2;
  int refine = 0;
};

double Percentile(std::vector<double> values, double fraction) {
  if (values.empty()) {
    return 0;
  }
  std::sort(values.begin(), values.end());
  const size_t index = static_cast<size_t>(fraction * static_cast<double>(values.size() - 1) + 0.5);
  return values[std::min(index, values.size() - 1)];
}

double Mean(const std::vector<double>& values) {
  double total = 0;
  for (double value : values) {
    total += value;
  }
  return values.empty() ? 0 : total / static_cast<double>(values.size());
}

bool Parse(int argc, char** argv, Options* options, std::string* error) {
  for (int index = 1; index < argc; ++index) {
    const std::string flag = argv[index];
    if (index + 1 >= argc) {
      *error = flag + " needs a value";
      return false;
    }
    const std::string value = argv[++index];
    if (flag == "--input") {
      options->input = value;
    } else if (flag == "--encoder") {
      options->encoder = value;
    } else if (flag == "--out") {
      options->out = value;
    } else if (flag == "--yuv-out") {
      options->yuv_out = value;
    } else if (flag == "--preset") {
      options->preset = value;
    } else if (flag == "--fps") {
      options->fps = std::atoi(value.c_str());
    } else if (flag == "--crf") {
      options->crf = std::atoi(value.c_str());
    } else if (flag == "--bitrate-kbps") {
      options->bitrate_kbps = std::atoi(value.c_str());
    } else if (flag == "--threads") {
      options->threads = std::atoi(value.c_str());
    } else if (flag == "--vbv-frames") {
      options->vbv_frames = std::atof(value.c_str());
    } else if (flag == "--refine") {
      options->refine = std::atoi(value.c_str());
    } else if (flag == "--max-frames") {
      options->max_frames = std::atoi(value.c_str());
    } else {
      *error = "unknown flag " + flag;
      return false;
    }
  }
  if (options->input.empty() || options->fps <= 0) {
    *error = "--input is required and --fps must be positive";
    return false;
  }
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  signal(SIGPIPE, SIG_IGN);
  Options options;
  std::string error;
  if (!Parse(argc, argv, &options, &error)) {
    std::fprintf(stderr, "rb_encode_bench: %s\n", error.c_str());
    return 64;
  }
  std::ifstream input(options.input, std::ios::binary);
  if (!input) {
    std::fprintf(stderr, "rb_encode_bench: cannot open %s\n", options.input.c_str());
    return 66;
  }
  rb::EncoderInfo info;
  if (!rb::ResolveEncoder(options.encoder, &info, &error)) {
    std::fprintf(stderr, "rb_encode_bench: %s\n", error.c_str());
    return 69;
  }
  std::ofstream out;
  if (!options.out.empty()) {
    out.open(options.out, std::ios::binary | std::ios::trunc);
  }
  std::ofstream yuv_out;
  if (!options.yuv_out.empty()) {
    yuv_out.open(options.yuv_out, std::ios::binary | std::ios::trunc);
  }

  rb::SubprocessEncoder encoder(info, RB_SHIM_LIBRARY, "/tmp");
  std::mutex mutex;
  std::condition_variable changed;
  std::vector<rb::EncodedFrame> outputs;
  std::string encoder_error;

  std::vector<double> wall_ms;
  std::vector<double> cpu_ms;
  std::vector<double> convert_ms;
  std::vector<double> changed_fraction;
  size_t total_bytes = 0;
  size_t keyframe_bytes = 0;
  size_t last_frame_bytes = 0;
  int frames = 0;
  int source_frames = 0;
  uint64_t first_pts = 0;
  uint64_t last_pts = 0;
  uint64_t last_taken_pts = 0;
  const uint64_t interval_us = 1000000 / static_cast<uint64_t>(options.fps);
  bool started = false;
  int width = 0;
  int height = 0;
  std::vector<uint8_t> bgra;
  std::vector<uint8_t> previous;
  rb::I420Frame frame;

  int refine_left = options.refine;
  while (true) {
    uint64_t pts = 0;
    uint32_t dimensions[2] = {0, 0};
    if (!input.read(reinterpret_cast<char*>(&pts), sizeof(pts)) ||
        !input.read(reinterpret_cast<char*>(dimensions), sizeof(dimensions))) {
      // --refine: re-encode the final picture, as an idle page's refinement frames would.
      if (refine_left <= 0 || bgra.empty()) {
        break;
      }
      --refine_left;
      pts = last_pts + interval_us;
      dimensions[0] = static_cast<uint32_t>(width);
      dimensions[1] = static_cast<uint32_t>(height);
    } else {
      bgra.resize(static_cast<size_t>(dimensions[0]) * dimensions[1] * 4);
      if (!input.read(reinterpret_cast<char*>(bgra.data()),
                      static_cast<std::streamsize>(bgra.size()))) {
        std::fprintf(stderr, "rb_encode_bench: truncated recording\n");
        return 65;
      }
      ++source_frames;
    }
    if (first_pts == 0) {
      first_pts = pts;
    }
    last_pts = pts;
    // Subsample to the target rate the way the streamer's fps cap would.
    if (frames > 0 && pts < last_taken_pts + interval_us) {
      continue;
    }
    last_taken_pts = pts;
    if (!started) {
      width = static_cast<int>(dimensions[0]);
      height = static_cast<int>(dimensions[1]);
      rb::EncoderSettings settings;
      settings.width = (width + 1) & ~1;
      settings.height = (height + 1) & ~1;
      settings.fps = options.fps;
      settings.crf = options.crf;
      settings.threads = options.threads;
      settings.preset = options.preset;
      settings.vbv_frames = options.vbv_frames;
      settings.bitrate_kbps =
          options.bitrate_kbps > 0
              ? options.bitrate_kbps
              : rb::DefaultBitrateKbps(settings.width, settings.height, "medium");
      if (!encoder.Start(
              settings,
              [&](rb::EncodedFrame encoded) {
                std::lock_guard<std::mutex> lock(mutex);
                outputs.push_back(std::move(encoded));
                changed.notify_all();
              },
              [&](const std::string& message) {
                std::lock_guard<std::mutex> lock(mutex);
                encoder_error = message;
                changed.notify_all();
              },
              &error)) {
        std::fprintf(stderr, "rb_encode_bench: %s\n", error.c_str());
        return 70;
      }
      frame.Resize(width, height);
      started = true;
      std::fprintf(stderr, "rb_encode_bench: %s %dx%d at %d fps, %d kbps\n", info.path.c_str(),
                   settings.width, settings.height, settings.fps, settings.bitrate_kbps);
    }
    // Damage as the share of pixels that changed since the previous encoded frame.
    if (!previous.empty()) {
      size_t different = 0;
      for (size_t index = 0; index < bgra.size(); index += 4) {
        different += std::memcmp(&bgra[index], &previous[index], 4) != 0;
      }
      changed_fraction.push_back(static_cast<double>(different) /
                                 (static_cast<double>(bgra.size()) / 4));
    }
    previous = bgra;
    const auto convert_start = std::chrono::steady_clock::now();
    rb::ConvertBgraToI420(bgra.data(), width * 4, width, height,
                          {0, 0, frame.width(), frame.height()}, &frame);
    convert_ms.push_back(
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - convert_start)
            .count());
    if (yuv_out.is_open()) {
      yuv_out.write(reinterpret_cast<const char*>(frame.data()),
                    static_cast<std::streamsize>(frame.size()));
    }
    const double cpu_before = encoder.CpuSeconds();
    const auto submit = std::chrono::steady_clock::now();
    if (!encoder.Submit(frame, pts, false, &error)) {
      std::fprintf(stderr, "rb_encode_bench: %s\n", error.c_str());
      return 71;
    }
    ++frames;
    std::unique_lock<std::mutex> lock(mutex);
    if (!changed.wait_for(lock, std::chrono::seconds(20), [&] {
          return outputs.size() >= static_cast<size_t>(frames) || !encoder_error.empty();
        })) {
      std::fprintf(stderr, "rb_encode_bench: the encoder stalled\n");
      return 72;
    }
    if (!encoder_error.empty()) {
      std::fprintf(stderr, "rb_encode_bench: %s\n", encoder_error.c_str());
      return 73;
    }
    const rb::EncodedFrame& encoded = outputs.back();
    lock.unlock();
    wall_ms.push_back(
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - submit)
            .count());
    cpu_ms.push_back((encoder.CpuSeconds() - cpu_before) * 1000);
    total_bytes += encoded.annexb.size();
    last_frame_bytes = encoded.annexb.size();
    if (encoded.keyframe) {
      keyframe_bytes += encoded.annexb.size();
    }
    if (out.is_open()) {
      out.write(reinterpret_cast<const char*>(encoded.annexb.data()),
                static_cast<std::streamsize>(encoded.annexb.size()));
    }
    if (options.max_frames > 0 && frames >= options.max_frames) {
      break;
    }
  }
  const double total_cpu = encoder.CpuSeconds();
  encoder.Stop();
  if (frames == 0) {
    std::fprintf(stderr, "rb_encode_bench: the recording has no frames\n");
    return 65;
  }
  // Duration covers the recording span plus one frame interval.
  const double duration_s = static_cast<double>(last_pts - first_pts) / 1e6 + 1.0 / options.fps;
  rb::Json report = rb::Json::MakeObject();
  report.Set("encoder", info.path);
  report.Set("encoder_kind", rb::EncoderKindName(info.kind));
  report.Set("width", width);
  report.Set("height", height);
  report.Set("fps", options.fps);
  report.Set("crf", options.crf);
  report.Set("threads", options.threads);
  report.Set("preset", options.preset);
  report.Set("source_frames", source_frames);
  report.Set("frames", frames);
  report.Set("duration_s", duration_s);
  report.Set("first_frame_wall_ms", wall_ms.empty() ? 0.0 : wall_ms.front());
  report.Set("vbv_frames", options.vbv_frames);
  report.Set("refine", options.refine);
  report.Set("last_frame_bytes", static_cast<int64_t>(last_frame_bytes));
  // Steady state: the first frame includes encoder start-up.
  if (wall_ms.size() > 1) {
    wall_ms.erase(wall_ms.begin());
    cpu_ms.erase(cpu_ms.begin());
  }
  report.Set("encode_wall_ms_p50", Percentile(wall_ms, 0.5));
  report.Set("encode_wall_ms_p95", Percentile(wall_ms, 0.95));
  report.Set("encode_cpu_ms_p50", Percentile(cpu_ms, 0.5));
  report.Set("encode_cpu_ms_p95", Percentile(cpu_ms, 0.95));
  report.Set("encode_cpu_ms_mean", Mean(cpu_ms));
  report.Set("convert_ms_p50", Percentile(convert_ms, 0.5));
  report.Set("convert_ms_p95", Percentile(convert_ms, 0.95));
  report.Set("changed_fraction_mean", Mean(changed_fraction));
  // CPU share of one core if every frame at this rate changes, and over the scenario itself.
  report.Set("core_pct_sustained", (Mean(cpu_ms) + Mean(convert_ms)) * options.fps / 10.0);
  report.Set("core_pct_scenario", total_cpu / duration_s * 100.0);
  report.Set("encoder_cpu_s", total_cpu);
  report.Set("kbps", static_cast<double>(total_bytes) * 8 / 1000 / duration_s);
  report.Set("bytes", static_cast<int64_t>(total_bytes));
  report.Set("keyframe_bytes", static_cast<int64_t>(keyframe_bytes));
  std::printf("%s\n", report.Dump().c_str());
  return 0;
}

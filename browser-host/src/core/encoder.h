// H.264 encoder backends. The host never links or loads libx264 (GPL): the x264 backend runs
// the system `x264` or `ffmpeg -c:v libx264` command as a child process and talks to it over
// pipes only. Other backends (OpenH264 in process, VA-API, NVENC, VideoToolbox) implement the
// same interface.
#pragma once

#include <sys/types.h>

#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "core/h264.h"
#include "core/yuv.h"

namespace rb {

struct EncoderSettings {
  int width = 1280;  // Even.
  int height = 800;  // Even.
  int fps = 15;      // Nominal rate for rate control (frames may arrive less often).
  int bitrate_kbps = 1500;
  double vbv_frames = 2;  // VBV buffer in frames at `fps` (the streamer uses two seconds).
  int crf = 24;
  std::string preset = "ultrafast";
  int threads = 1;
};

struct EncodedFrame {
  std::vector<uint8_t> annexb;
  bool keyframe = false;
  uint64_t frame_number = 0;  // Within the current encoder process.
  uint64_t pts_us = 0;
  uint64_t submit_us = 0;
  uint64_t output_us = 0;
  /// Set when a keyframe was requested for this frame.
  bool keyframe_requested = false;
};

class EncoderBackend {
 public:
  using OutputCallback = std::function<void(EncodedFrame)>;
  using ErrorCallback = std::function<void(const std::string&)>;

  virtual ~EncoderBackend() = default;
  virtual const char* name() const = 0;
  /// Starts encoding with `settings`. Callbacks run on the backend's reader thread.
  virtual bool Start(const EncoderSettings& settings, OutputCallback on_frame,
                     ErrorCallback on_error, std::string* error) = 0;
  /// Encodes one frame; blocks until the encoder accepted the input. `keyframe` forces an IDR.
  virtual bool Submit(const I420Frame& frame, uint64_t pts_us, bool keyframe,
                      std::string* error) = 0;
  /// Stops and releases the encoder. Pending frames are discarded.
  virtual void Stop() = 0;
  virtual bool running() const = 0;
  /// Frames submitted but not yet output.
  virtual int pending() const = 0;
  /// CPU seconds used by the encoder so far (all processes it started).
  virtual double CpuSeconds() const = 0;
  /// How the backend forces IDRs, for logs and stats ("in_stream" or "restart").
  virtual std::string keyframe_mode() const = 0;
};

enum class EncoderKind { kX264, kFfmpeg };

struct EncoderInfo {
  std::string path;
  EncoderKind kind = EncoderKind::kX264;
  std::string version;
};

const char* EncoderKindName(EncoderKind kind);

/// Finds the encoder: `requested` when set, else `x264` then `ffmpeg` on PATH. Verifies it runs
/// (and, for ffmpeg, that it has libx264).
bool ResolveEncoder(const std::string& requested, EncoderInfo* info, std::string* error);

/// Runs x264 or ffmpeg as a child process, feeding raw I420 on stdin and reading FLV from
/// stdout. x264 takes IDR requests through a qpfile it re-reads per frame; ffmpeg (and x264
/// when that fails) restarts the process, whose first frame is an IDR.
class SubprocessEncoder : public EncoderBackend {
 public:
  /// `shim_library` is the unbuffered-stdout shim preloaded into x264 (which buffers stdout).
  /// `work_dir` holds the qpfile.
  SubprocessEncoder(EncoderInfo info, std::string shim_library, std::string work_dir);
  ~SubprocessEncoder() override;

  const char* name() const override;
  bool Start(const EncoderSettings& settings, OutputCallback on_frame, ErrorCallback on_error,
             std::string* error) override;
  bool Submit(const I420Frame& frame, uint64_t pts_us, bool keyframe, std::string* error) override;
  void Stop() override;
  bool running() const override;
  int pending() const override;
  double CpuSeconds() const override;
  std::string keyframe_mode() const override;

  /// The argv the backend runs for `settings` (tests and logs).
  std::vector<std::string> CommandLine(const EncoderSettings& settings) const;

 private:
  struct Pending {
    uint64_t frame_number;
    uint64_t pts_us;
    uint64_t submit_us;
    bool keyframe;
    /// False when x264 cannot see this frame's IDR request (see RequestInStreamIdr).
    bool request_visible;
  };

  bool SpawnLocked(std::string* error);
  void KillLocked();
  void ReaderLoop(pid_t pid, int stdout_fd, int stderr_fd, uint64_t generation);
  bool RequestInStreamIdr(uint64_t frame_number, std::string* error);
  std::string StderrTail() const;
  double ProcessCpuSeconds(pid_t pid) const;

  const EncoderInfo info_;
  const std::string shim_library_;
  const std::string work_dir_;
  EncoderSettings settings_;
  OutputCallback on_frame_;
  ErrorCallback on_error_;

  mutable std::mutex mutex_;
  pid_t pid_ = -1;
  int stdin_fd_ = -1;
  std::thread reader_;
  uint64_t generation_ = 0;
  uint64_t next_frame_number_ = 0;
  std::deque<Pending> pending_;
  std::string stderr_tail_;
  bool in_stream_idr_ = true;
  int qpfile_fd_ = -1;
  std::string qpfile_path_;
  off_t qpfile_sentinel_offset_ = 0;
  /// The frame number of the last in-stream IDR request, if any.
  std::optional<uint64_t> last_idr_request_;
  double finished_cpu_seconds_ = 0;
  bool stopping_ = false;
};

}  // namespace rb

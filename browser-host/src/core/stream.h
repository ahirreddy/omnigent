// TabStreamer turns a tab's FrameSink into per-viewer media streams (design doc sections 4.4,
// 5.2, 5.5): damage-driven capture, encoding only while a visible viewer is attached, an fps
// cap, the ack window, an IDR (and new stream_id) for every new or returning viewer, and stats.
#pragma once

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "core/encoder.h"
#include "core/frame_sink.h"
#include "core/media_header.h"
#include "core/protocol.h"

namespace rb {

/// Where the streamer sends media. Implemented by the host; called from streamer threads.
class MediaSender {
 public:
  virtual ~MediaSender() = default;
  /// One binary message (media header plus payload) for connection `connection`.
  virtual void SendMedia(uint64_t connection, std::vector<uint8_t> message) = 0;
  /// Closes a stalled viewer (1013).
  virtual void CloseStalled(uint64_t connection) = 0;
  virtual void Log(const std::string& message) = 0;
  /// A fatal encoder problem the viewers should hear about (sent as a non-fatal error).
  virtual void ReportError(const std::string& code, const std::string& message) = 0;
};

struct StreamConfig {
  int fps_agent = 15;
  int fps_user = 30;
  int encoder_threads = 1;
  std::string preset = "ultrafast";
  /// Stall timeout for the oldest unacked frame.
  int stall_ms = 10000;
  /// Stop the encoder after this long without visible viewers.
  int encoder_idle_ms = 5000;
  /// Re-encode the unchanged picture this long after the last change (ms, ascending), so an
  /// idle page sharpens after a scroll or an IDR instead of staying at the rate-limited
  /// quality of its last frame. Empty disables refinement.
  std::vector<int> refine_after_ms = {150, 400, 800};
};

/// Rate control for a canvas size and quality (section 4.4 defaults: 720p 1.5 Mbit/s).
int DefaultBitrateKbps(int width, int height, const std::string& quality);

class TabStreamer {
 public:
  using EncoderFactory = std::function<std::unique_ptr<EncoderBackend>()>;

  TabStreamer(FrameSink* sink, EncoderFactory make_encoder, MediaSender* sender,
              StreamConfig config);
  ~TabStreamer();

  void AddViewer(uint64_t connection, bool visible);
  void RemoveViewer(uint64_t connection);
  void SetVisible(uint64_t connection, bool visible);
  /// Cumulative ack.
  void Ack(uint64_t connection, uint32_t seq);
  /// A new IDR (new stream_id) for every viewer, within one frame interval.
  void RequestKeyframe();
  /// Applies `settings` (max_fps, quality, scale, codec); an encoder change forces an IDR.
  void ApplySettings(const protocol::Settings& settings);
  /// Whether the user (true) or agent owns the tab; selects the fps cap.
  void SetUserInControl(bool user);
  /// The canvas changed size (resize, DPR change): restarts the encoder at the new size.
  void OnCanvasResized();
  /// Called after every paint into the FrameSink.
  void NotifyDamage();
  /// Sends one JPEG still or thumbnail to `connection` (kind 2 or 3).
  bool SendStill(uint64_t connection, bool thumbnail, std::string* error);

  /// Stats over the last second for `connection` (host_cpu is filled by the caller).
  protocol::Stats Stats(uint64_t connection);

  /// Records each frame the streamer would encode as raw BGRA (u64 pts_us, u32 w, u32 h, then
  /// w*h*4 bytes) until `max_frames` are written. Recording runs with or without viewers.
  bool StartRecording(const std::string& path, int max_frames, std::string* error);
  /// Stops recording; returns the number of frames written.
  int StopRecording();
  int recorded_frames();

  /// Frames encoded since start (tests and the idle check).
  uint64_t frames_encoded();
  double encoder_cpu_seconds();
  std::string encoder_keyframe_mode();

  void Shutdown();

 private:
  struct Unacked {
    uint32_t seq;
    size_t bytes;
    uint64_t sent_us;
  };
  struct Viewer {
    bool visible = true;
    bool has_idr = false;
    uint32_t next_seq = 1;
    std::deque<Unacked> unacked;
    size_t unacked_bytes = 0;
    // Stats over a sliding second.
    std::deque<std::pair<uint64_t, size_t>> sent;  // (time, bytes)
  };

  void Loop();
  bool AnyVisibleLocked() const;
  bool WindowOpenLocked() const;
  bool ShouldStopEncoderLocked(uint64_t now_us) const;
  int EffectiveFpsLocked() const;
  void OnEncoded(uint64_t generation, EncodedFrame frame);
  void OnEncoderError(uint64_t generation, const std::string& message);
  void SendToViewerLocked(uint64_t connection, Viewer* viewer, MediaKind kind, uint16_t flags,
                          uint32_t stream_id, uint64_t pts_us, const std::vector<uint8_t>& payload);
  void CheckStallsLocked(uint64_t now_us);
  bool EncodeJpegFrameLocked(std::unique_lock<std::mutex>* lock);
  void RecordFrame(uint64_t pts_us);

  FrameSink* const sink_;
  EncoderFactory make_encoder_;
  MediaSender* const sender_;
  const StreamConfig config_;

  std::mutex mutex_;
  std::condition_variable wake_;
  std::thread thread_;
  bool shutdown_ = false;
  std::map<uint64_t, Viewer> viewers_;
  protocol::Settings settings_;
  bool user_in_control_ = false;
  bool keyframe_pending_ = true;
  bool encoder_restart_pending_ = false;
  uint32_t stream_id_ = 0;
  uint64_t last_submit_us_ = 0;
  uint64_t last_change_submit_us_ = 0;
  size_t refine_done_ = 0;
  uint64_t last_visible_us_ = 0;
  uint64_t frames_encoded_ = 0;
  uint64_t encoder_generation_ = 0;
  std::deque<double> encode_ms_;                          // Recent encode latencies.
  std::deque<std::pair<uint64_t, double>> encode_times_;  // (time, ms) over the last second.

  // Owned by the loop thread; other threads touch them under mutex_ only via pointers below.
  std::unique_ptr<EncoderBackend> encoder_;
  EncoderSettings encoder_settings_;
  double retired_encoder_cpu_ = 0;
  I420Frame frame_;

  std::ofstream recording_;
  int recording_max_frames_ = 0;
  int recorded_frames_ = 0;
};

}  // namespace rb

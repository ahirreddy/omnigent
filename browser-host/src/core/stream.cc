#include "core/stream.h"

#include <algorithm>
#include <chrono>
#include <cmath>

#include "core/jpeg.h"

namespace rb {

namespace {

constexpr uint64_t kSecondUs = 1000000;
constexpr int kStartRetryMs = 2000;

int EvenAtLeastTwo(double value) {
  int rounded = static_cast<int>(std::lround(value));
  rounded = std::max(2, rounded);
  return rounded + (rounded & 1);
}

int JpegQuality(const std::string& quality) {
  if (quality == "low") {
    return 50;
  }
  if (quality == "high") {
    return 85;
  }
  return 70;
}

double Percentile(std::vector<double> values, double fraction) {
  if (values.empty()) {
    return 0;
  }
  std::sort(values.begin(), values.end());
  const size_t index = static_cast<size_t>(fraction * static_cast<double>(values.size() - 1) + 0.5);
  return values[std::min(index, values.size() - 1)];
}

}  // namespace

int DefaultBitrateKbps(int width, int height, const std::string& quality) {
  const double pixels = static_cast<double>(width) * height;
  double kbps = 1500.0 * pixels / (1280.0 * 720.0);
  if (quality == "low") {
    kbps *= 0.5;
  } else if (quality == "high") {
    kbps *= 2;
  }
  return std::clamp(static_cast<int>(kbps), 200, 12000);
}

TabStreamer::TabStreamer(FrameSink* sink, EncoderFactory make_encoder, MediaSender* sender,
                         StreamConfig config)
    : sink_(sink), make_encoder_(std::move(make_encoder)), sender_(sender), config_(config) {
  settings_.max_fps = static_cast<uint32_t>(config_.fps_agent);
  thread_ = std::thread(&TabStreamer::Loop, this);
}

TabStreamer::~TabStreamer() { Shutdown(); }

void TabStreamer::Shutdown() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutdown_) {
      return;
    }
    shutdown_ = true;
  }
  wake_.notify_all();
  if (thread_.joinable()) {
    thread_.join();
  }
}

void TabStreamer::AddViewer(uint64_t connection, bool visible) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    Viewer viewer;
    viewer.visible = visible;
    viewers_[connection] = viewer;
    if (visible) {
      keyframe_pending_ = true;
      sink_->DamageAll();
    }
  }
  wake_.notify_all();
}

void TabStreamer::RemoveViewer(uint64_t connection) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    viewers_.erase(connection);
  }
  wake_.notify_all();
}

void TabStreamer::SetVisible(uint64_t connection, bool visible) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto found = viewers_.find(connection);
    if (found == viewers_.end() || found->second.visible == visible) {
      return;
    }
    found->second.visible = visible;
    found->second.has_idr = false;
    if (visible) {
      keyframe_pending_ = true;
      sink_->DamageAll();
    }
  }
  wake_.notify_all();
}

void TabStreamer::Ack(uint64_t connection, uint32_t seq) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto found = viewers_.find(connection);
    if (found == viewers_.end()) {
      return;
    }
    Viewer& viewer = found->second;
    while (!viewer.unacked.empty() && viewer.unacked.front().seq <= seq) {
      viewer.unacked_bytes -= viewer.unacked.front().bytes;
      viewer.unacked.pop_front();
    }
  }
  wake_.notify_all();
}

void TabStreamer::RequestKeyframe() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    keyframe_pending_ = true;
    sink_->DamageAll();
  }
  wake_.notify_all();
}

void TabStreamer::ApplySettings(const protocol::Settings& settings) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const bool encoder_change =
        settings.max_fps != settings_.max_fps || settings.quality != settings_.quality ||
        settings.scale != settings_.scale || settings.codec != settings_.codec;
    settings_ = settings;
    if (encoder_change) {
      encoder_restart_pending_ = true;
      keyframe_pending_ = true;
      sink_->DamageAll();
    }
  }
  wake_.notify_all();
}

void TabStreamer::SetUserInControl(bool user) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (user_in_control_ == user) {
      return;
    }
    // Only the pacing cap changes; the encoder's nominal rate covers both owners, so taking
    // control costs no restart and no IDR.
    user_in_control_ = user;
  }
  wake_.notify_all();
}

void TabStreamer::OnCanvasResized() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    encoder_restart_pending_ = true;
    keyframe_pending_ = true;
  }
  wake_.notify_all();
}

void TabStreamer::NotifyDamage() { wake_.notify_all(); }

int TabStreamer::EffectiveFpsLocked() const {
  const int requested = static_cast<int>(settings_.max_fps);
  return user_in_control_ ? std::max(requested, config_.fps_user) : requested;
}

bool TabStreamer::AnyVisibleLocked() const {
  for (const auto& [connection, viewer] : viewers_) {
    if (viewer.visible) {
      return true;
    }
  }
  return false;
}

bool TabStreamer::WindowOpenLocked() const {
  const int pending = encoder_ ? encoder_->pending() : 0;
  for (const auto& [connection, viewer] : viewers_) {
    if (!viewer.visible) {
      continue;
    }
    const size_t in_flight = viewer.unacked.size() + static_cast<size_t>(pending);
    if (in_flight == 0) {
      continue;  // One frame of any size may go out when nothing is in flight.
    }
    if (in_flight >= protocol::kWindowMaxFrames ||
        viewer.unacked_bytes >= protocol::kWindowMaxBytes) {
      return false;
    }
  }
  return true;
}

void TabStreamer::CheckStallsLocked(uint64_t now_us) {
  std::vector<uint64_t> stalled;
  for (const auto& [connection, viewer] : viewers_) {
    if (!viewer.unacked.empty() &&
        now_us - viewer.unacked.front().sent_us > static_cast<uint64_t>(config_.stall_ms) * 1000) {
      stalled.push_back(connection);
    }
  }
  for (uint64_t connection : stalled) {
    viewers_.erase(connection);
    sender_->Log("viewer " + std::to_string(connection) + " stalled; closing with 1013");
    sender_->CloseStalled(connection);
  }
}

void TabStreamer::SendToViewerLocked(uint64_t connection, Viewer* viewer, MediaKind kind,
                                     uint16_t flags, uint32_t stream_id, uint64_t pts_us,
                                     const std::vector<uint8_t>& payload) {
  MediaHeader header;
  header.kind = static_cast<uint8_t>(kind);
  header.flags = flags;
  header.seq = viewer->next_seq++;
  header.stream_id = stream_id;
  header.pts_us = pts_us;
  std::vector<uint8_t> message = BuildMediaMessage(header, payload.data(), payload.size());
  const uint64_t now = MonotonicMicros();
  viewer->unacked.push_back(Unacked{header.seq, message.size(), now});
  viewer->unacked_bytes += message.size();
  viewer->sent.emplace_back(now, message.size());
  while (!viewer->sent.empty() && now - viewer->sent.front().first > kSecondUs) {
    viewer->sent.pop_front();
  }
  sender_->SendMedia(connection, std::move(message));
}

void TabStreamer::OnEncoded(uint64_t generation, EncodedFrame frame) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation != encoder_generation_) {
      return;
    }
    ++frames_encoded_;
    const double latency_ms = static_cast<double>(frame.output_us - frame.submit_us) / 1000.0;
    encode_times_.emplace_back(frame.output_us, latency_ms);
    while (!encode_times_.empty() && frame.output_us - encode_times_.front().first > kSecondUs) {
      encode_times_.pop_front();
    }
    encode_ms_.push_back(latency_ms);
    if (encode_ms_.size() > 120) {
      encode_ms_.pop_front();
    }
    if (frame.keyframe_requested && !frame.keyframe) {
      keyframe_pending_ = true;  // The encoder missed the request; ask again.
      sink_->DamageAll();
    }
    if (frame.keyframe) {
      ++stream_id_;
    }
    const uint16_t flags =
        frame.keyframe ? static_cast<uint16_t>(kMediaFlagKeyframe | kMediaFlagNewStream) : 0;
    for (auto& [connection, viewer] : viewers_) {
      if (!viewer.visible) {
        continue;
      }
      if (frame.keyframe) {
        viewer.has_idr = true;
      }
      if (!viewer.has_idr) {
        continue;  // Never a delta before this viewer's first IDR.
      }
      SendToViewerLocked(connection, &viewer, MediaKind::kH264AccessUnit, flags, stream_id_,
                         frame.pts_us, frame.annexb);
    }
  }
  wake_.notify_all();
}

void TabStreamer::OnEncoderError(uint64_t generation, const std::string& message) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation != encoder_generation_) {
      return;
    }
    encoder_restart_pending_ = true;
    keyframe_pending_ = true;
  }
  sender_->Log("encoder: " + message);
  sender_->ReportError("internal", "encoder: " + message);
  wake_.notify_all();
}

bool TabStreamer::SendStill(uint64_t connection, bool thumbnail, std::string* error) {
  std::vector<uint8_t> canvas;
  int width = 0;
  int height = 0;
  sink_->CopyCanvas(&canvas, &width, &height);
  if (width == 0 || height == 0) {
    *error = "the tab has not painted yet";
    return false;
  }
  std::vector<uint8_t> jpeg;
  if (thumbnail) {
    std::vector<uint8_t> small;
    int small_width = 0;
    int small_height = 0;
    DownscaleBgra(canvas.data(), width, height, 320, &small, &small_width, &small_height);
    if (!EncodeJpeg(small.data(), small_width, small_height, 70, &jpeg, error)) {
      return false;
    }
  } else if (!EncodeJpeg(canvas.data(), width, height, 80, &jpeg, error)) {
    return false;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  auto found = viewers_.find(connection);
  if (found == viewers_.end()) {
    *error = "the connection has no stream yet (send hello first)";
    return false;
  }
  SendToViewerLocked(connection, &found->second,
                     thumbnail ? MediaKind::kJpegThumbnail : MediaKind::kJpegStill, 0, 0,
                     MonotonicMicros(), jpeg);
  return true;
}

protocol::Stats TabStreamer::Stats(uint64_t connection) {
  std::lock_guard<std::mutex> lock(mutex_);
  protocol::Stats stats;
  const uint64_t now = MonotonicMicros();
  auto found = viewers_.find(connection);
  if (found != viewers_.end()) {
    Viewer& viewer = found->second;
    while (!viewer.sent.empty() && now - viewer.sent.front().first > kSecondUs) {
      viewer.sent.pop_front();
    }
    size_t bytes = 0;
    for (const auto& [time, size] : viewer.sent) {
      bytes += size;
    }
    stats.fps = static_cast<double>(viewer.sent.size());
    stats.kbps = static_cast<double>(bytes) * 8 / 1000;
    stats.in_flight_frames = static_cast<uint32_t>(viewer.unacked.size());
    stats.in_flight_bytes = static_cast<uint32_t>(viewer.unacked_bytes);
  }
  std::vector<double> recent;
  for (const auto& [time, ms] : encode_times_) {
    if (now - time <= kSecondUs) {
      recent.push_back(ms);
    }
  }
  if (recent.empty()) {
    recent.assign(encode_ms_.begin(), encode_ms_.end());
  }
  stats.encode_ms_p50 = Percentile(recent, 0.5);
  stats.encode_ms_p95 = Percentile(recent, 0.95);
  return stats;
}

bool TabStreamer::StartRecording(const std::string& path, int max_frames, std::string* error) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (recording_.is_open()) {
      *error = "a recording is already running";
      return false;
    }
    recording_.open(path, std::ios::binary | std::ios::trunc);
    if (!recording_) {
      *error = "cannot open " + path + " for writing";
      return false;
    }
    recording_max_frames_ = std::max(1, max_frames);
    recorded_frames_ = 0;
    sink_->DamageAll();
  }
  wake_.notify_all();
  return true;
}

int TabStreamer::StopRecording() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (recording_.is_open()) {
    recording_.close();
  }
  return recorded_frames_;
}

int TabStreamer::recorded_frames() {
  std::lock_guard<std::mutex> lock(mutex_);
  return recorded_frames_;
}

uint64_t TabStreamer::frames_encoded() {
  std::lock_guard<std::mutex> lock(mutex_);
  return frames_encoded_;
}

double TabStreamer::encoder_cpu_seconds() {
  std::lock_guard<std::mutex> lock(mutex_);
  return retired_encoder_cpu_ + (encoder_ ? encoder_->CpuSeconds() : 0);
}

std::string TabStreamer::encoder_keyframe_mode() {
  std::lock_guard<std::mutex> lock(mutex_);
  return encoder_ ? encoder_->keyframe_mode() : "none";
}

void TabStreamer::RecordFrame(uint64_t pts_us) {
  std::vector<uint8_t> canvas;
  int width = 0;
  int height = 0;
  sink_->CopyCanvas(&canvas, &width, &height);
  std::lock_guard<std::mutex> lock(mutex_);
  if (!recording_.is_open() || width == 0) {
    return;
  }
  const uint32_t dimensions[2] = {static_cast<uint32_t>(width), static_cast<uint32_t>(height)};
  recording_.write(reinterpret_cast<const char*>(&pts_us), sizeof(pts_us));
  recording_.write(reinterpret_cast<const char*>(dimensions), sizeof(dimensions));
  recording_.write(reinterpret_cast<const char*>(canvas.data()),
                   static_cast<std::streamsize>(canvas.size()));
  if (!recording_) {
    sender_->Log("recording write failed; stopping the recording");
    recording_.close();
    return;
  }
  if (++recorded_frames_ >= recording_max_frames_) {
    recording_.close();
  }
}

bool TabStreamer::EncodeJpegFrameLocked(std::unique_lock<std::mutex>* lock) {
  const int quality = JpegQuality(settings_.quality);
  lock->unlock();
  std::vector<uint8_t> canvas;
  int width = 0;
  int height = 0;
  sink_->CopyCanvas(&canvas, &width, &height);
  I420Frame unused;
  uint64_t capture_us = 0;
  sink_->TakeFrame(&unused, &capture_us);  // Clears the damage.
  std::vector<uint8_t> jpeg;
  std::string error;
  const bool ok = width > 0 && EncodeJpeg(canvas.data(), width, height, quality, &jpeg, &error);
  lock->lock();
  if (!ok) {
    if (!error.empty()) {
      sender_->Log("JPEG frame failed: " + error);
    }
    return false;
  }
  ++frames_encoded_;
  for (auto& [connection, viewer] : viewers_) {
    if (viewer.visible) {
      SendToViewerLocked(connection, &viewer, MediaKind::kJpegStill, 0, 0, capture_us, jpeg);
    }
  }
  return true;
}

void TabStreamer::Loop() {
  std::unique_lock<std::mutex> lock(mutex_);
  uint64_t start_retry_at = 0;
  while (!shutdown_) {
    const uint64_t now = MonotonicMicros();
    CheckStallsLocked(now);
    const bool visible = AnyVisibleLocked();
    if (visible) {
      last_visible_us_ = now;
    }
    const bool recording = recording_.is_open();
    // Release the encoder after a while without visible viewers.
    if (!visible && encoder_ &&
        now - last_visible_us_ > static_cast<uint64_t>(config_.encoder_idle_ms) * 1000) {
      std::unique_ptr<EncoderBackend> retired = std::move(encoder_);
      ++encoder_generation_;
      lock.unlock();
      retired->Stop();
      const double cpu = retired->CpuSeconds();
      retired.reset();
      lock.lock();
      retired_encoder_cpu_ += cpu;
      continue;
    }
    const bool damage = sink_->HasDamage();
    // Refinement: re-encode the unchanged picture a few times after the last change.
    const bool refine_pending = visible && encoder_ && settings_.codec != "jpeg" && !damage &&
                                !keyframe_pending_ && refine_done_ < config_.refine_after_ms.size();
    const uint64_t refine_at =
        refine_pending ? last_change_submit_us_ +
                             static_cast<uint64_t>(config_.refine_after_ms[refine_done_]) * 1000
                       : 0;
    const bool refine_due = refine_pending && now >= refine_at;
    // Nothing goes out before the page's first paint: an IDR of the blank canvas would tell
    // clients the page is ready when Chromium has not drawn (or hit-tested) it yet.
    const bool has_content = sink_->HasContent();
    const bool wants_frame =
        has_content &&
        ((visible && (damage || keyframe_pending_ || refine_due)) || (recording && damage));
    if (!wants_frame || (visible && !WindowOpenLocked()) || now < start_retry_at) {
      const uint64_t wait_us =
          refine_pending && !refine_due ? std::min<uint64_t>(refine_at - now, 200000) : 200000;
      wake_.wait_for(lock, std::chrono::microseconds(wait_us));
      continue;
    }
    const int fps = std::max(1, EffectiveFpsLocked());
    const uint64_t interval = kSecondUs / static_cast<uint64_t>(fps);
    if (last_submit_us_ != 0 && now < last_submit_us_ + interval) {
      wake_.wait_for(lock, std::chrono::microseconds(last_submit_us_ + interval - now));
      continue;
    }
    last_submit_us_ = now;
    if (recording) {
      lock.unlock();
      RecordFrame(sink_->last_paint_us());
      lock.lock();
    }
    if (!visible) {
      I420Frame scratch;
      uint64_t capture_us = 0;
      lock.unlock();
      sink_->TakeFrame(&scratch, &capture_us);
      lock.lock();
      continue;
    }
    if (settings_.codec == "jpeg") {
      keyframe_pending_ = false;
      EncodeJpegFrameLocked(&lock);
      continue;
    }

    // Size the encoder from the canvas and the scale setting.
    const int canvas_width = sink_->width();
    const int canvas_height = sink_->height();
    if (canvas_width == 0 || canvas_height == 0) {
      wake_.wait_for(lock, std::chrono::milliseconds(50));
      continue;
    }
    const double scale = std::clamp(settings_.scale, 0.25, 1.0);
    EncoderSettings wanted;
    wanted.width = scale < 1 ? EvenAtLeastTwo(canvas_width * scale) : (canvas_width + 1) & ~1;
    wanted.height = scale < 1 ? EvenAtLeastTwo(canvas_height * scale) : (canvas_height + 1) & ~1;
    // Nominal rate for rate control: the highest cap either owner gets.
    wanted.fps = std::max<int>(static_cast<int>(settings_.max_fps), config_.fps_user);
    wanted.bitrate_kbps = DefaultBitrateKbps(wanted.width, wanted.height, settings_.quality);
    // A two-second VBV: an IDR of a static text page can be sharp (M0: text SSIM 0.75 with a
    // two-frame buffer, 0.99 with two seconds) while the average stays at the cap.
    wanted.vbv_frames = 2.0 * wanted.fps;
    wanted.threads = config_.encoder_threads;
    wanted.preset = config_.preset;
    const bool restart = !encoder_ || !encoder_->running() || encoder_restart_pending_ ||
                         wanted.width != encoder_settings_.width ||
                         wanted.height != encoder_settings_.height ||
                         wanted.fps != encoder_settings_.fps ||
                         wanted.bitrate_kbps != encoder_settings_.bitrate_kbps;
    bool keyframe = keyframe_pending_;
    if (restart) {
      std::unique_ptr<EncoderBackend> retired = std::move(encoder_);
      const uint64_t generation = ++encoder_generation_;
      encoder_restart_pending_ = false;
      lock.unlock();
      double retired_cpu = 0;
      if (retired) {
        retired->Stop();
        retired_cpu = retired->CpuSeconds();
        retired.reset();
      }
      std::unique_ptr<EncoderBackend> fresh = make_encoder_();
      std::string error;
      const bool started = fresh->Start(
          wanted,
          [this, generation](EncodedFrame frame) { OnEncoded(generation, std::move(frame)); },
          [this, generation](const std::string& message) { OnEncoderError(generation, message); },
          &error);
      lock.lock();
      retired_encoder_cpu_ += retired_cpu;
      if (!started) {
        sender_->Log("cannot start the encoder: " + error);
        sender_->ReportError("internal", "cannot start the encoder: " + error);
        encoder_restart_pending_ = true;
        start_retry_at = MonotonicMicros() + kStartRetryMs * 1000;
        continue;
      }
      sender_->Log(std::string("encoder ") + fresh->name() + " started at " +
                   std::to_string(wanted.width) + "x" + std::to_string(wanted.height) + "@" +
                   std::to_string(wanted.fps) + " " + std::to_string(wanted.bitrate_kbps) +
                   " kbps, keyframes " + fresh->keyframe_mode());
      encoder_ = std::move(fresh);
      encoder_settings_ = wanted;
      keyframe = true;  // A new encoder starts with an IDR.
      if (frame_.width() != wanted.width || frame_.height() != wanted.height) {
        frame_.Resize(wanted.width, wanted.height);
        sink_->DamageAll();
      }
    }
    keyframe_pending_ = false;
    const bool refinement = refine_due && !damage && !keyframe && !restart;
    if (refinement) {
      ++refine_done_;
    } else {
      refine_done_ = 0;
      last_change_submit_us_ = now;
    }
    EncoderBackend* encoder = encoder_.get();
    const uint64_t generation = encoder_generation_;
    lock.unlock();
    uint64_t capture_us = 0;
    if (refinement) {
      capture_us = MonotonicMicros();  // The picture in frame_ is unchanged.
    } else if (scale < 1) {
      std::vector<uint8_t> canvas;
      std::vector<uint8_t> scaled;
      int width = 0;
      int height = 0;
      int scaled_width = 0;
      int scaled_height = 0;
      sink_->CopyCanvas(&canvas, &width, &height);
      I420Frame scratch;
      sink_->TakeFrame(&scratch, &capture_us);
      DownscaleBgra(canvas.data(), width, height, wanted.width, &scaled, &scaled_width,
                    &scaled_height);
      ConvertBgraToI420(scaled.data(), scaled_width * 4, scaled_width, scaled_height,
                        {0, 0, frame_.width(), frame_.height()}, &frame_);
    } else {
      sink_->TakeFrame(&frame_, &capture_us);
    }
    std::string error;
    const bool submitted = encoder->Submit(frame_, capture_us, keyframe, &error);
    lock.lock();
    if (!submitted && generation == encoder_generation_) {
      sender_->Log("encoder submit failed: " + error);
      encoder_restart_pending_ = true;
      keyframe_pending_ = true;
      sink_->DamageAll();
    }
  }
  std::unique_ptr<EncoderBackend> retired = std::move(encoder_);
  ++encoder_generation_;
  lock.unlock();
  if (retired) {
    retired->Stop();
  }
}

}  // namespace rb

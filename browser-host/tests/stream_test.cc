#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

#include "core/stream.h"
#include "test.h"

namespace {

/// Emits one access unit per submitted frame, synchronously, with SPS/PPS on keyframes.
class FakeEncoder : public rb::EncoderBackend {
 public:
  explicit FakeEncoder(std::atomic<int>* starts) : starts_(starts) {}
  const char* name() const override { return "fake"; }
  bool Start(const rb::EncoderSettings&, OutputCallback on_frame, ErrorCallback,
             std::string*) override {
    on_frame_ = std::move(on_frame);
    running_ = true;
    first_ = true;
    ++*starts_;
    return true;
  }
  bool Submit(const rb::I420Frame&, uint64_t pts_us, bool keyframe, std::string*) override {
    rb::EncodedFrame frame;
    frame.keyframe = keyframe || first_;
    first_ = false;
    frame.keyframe_requested = keyframe;
    frame.pts_us = pts_us;
    frame.annexb = frame.keyframe ? std::vector<uint8_t>{0, 0,    0, 1, 0x67, 0, 0,    0,
                                                         1, 0x68, 0, 0, 0,    1, 0x65, 0x88}
                                  : std::vector<uint8_t>{0, 0, 0, 1, 0x41, 0x9a};
    on_frame_(std::move(frame));
    return true;
  }
  void Stop() override { running_ = false; }
  bool running() const override { return running_; }
  int pending() const override { return 0; }
  double CpuSeconds() const override { return 0; }
  std::string keyframe_mode() const override { return "in_stream"; }

 private:
  std::atomic<int>* starts_;
  OutputCallback on_frame_;
  bool running_ = false;
  bool first_ = true;
};

struct Sent {
  uint64_t connection;
  rb::MediaHeader header;
};

class RecordingSender : public rb::MediaSender {
 public:
  void SendMedia(uint64_t connection, std::vector<uint8_t> message) override {
    rb::MediaHeader header;
    if (rb::ReadMediaHeader(message.data(), message.size(), &header) !=
        rb::MediaHeaderError::kNone) {
      return;
    }
    std::lock_guard<std::mutex> lock(mutex);
    sent.push_back({connection, header});
    changed.notify_all();
  }
  void CloseStalled(uint64_t connection) override {
    std::lock_guard<std::mutex> lock(mutex);
    stalled.push_back(connection);
    changed.notify_all();
  }
  void Log(const std::string&) override {}
  void ReportError(const std::string&, const std::string&) override {}

  bool WaitForCount(size_t count, int timeout_ms = 2000) {
    std::unique_lock<std::mutex> lock(mutex);
    return changed.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                            [&] { return sent.size() >= count; });
  }
  std::vector<Sent> For(uint64_t connection) {
    std::lock_guard<std::mutex> lock(mutex);
    std::vector<Sent> out;
    for (const Sent& item : sent) {
      if (item.connection == connection) out.push_back(item);
    }
    return out;
  }
  size_t count() {
    std::lock_guard<std::mutex> lock(mutex);
    return sent.size();
  }

  std::mutex mutex;
  std::condition_variable changed;
  std::vector<Sent> sent;
  std::vector<uint64_t> stalled;
};

void Paint(rb::FrameSink* sink, rb::TabStreamer* streamer, uint8_t value) {
  std::vector<uint8_t> pixels(64 * 32 * 4, value);
  sink->PaintView({{0, 0, 64, 32}}, pixels.data(), 64, 32);
  streamer->NotifyDamage();
}

/// A sink that has received its first paint (the streamer sends nothing before one).
void Painted(rb::FrameSink* sink) {
  std::vector<uint8_t> pixels(64 * 32 * 4, 200);
  sink->Resize(64, 32);
  sink->PaintView({{0, 0, 64, 32}}, pixels.data(), 64, 32);
}

rb::StreamConfig FastConfig() {
  rb::StreamConfig config;
  config.fps_agent = 60;
  config.fps_user = 60;
  config.stall_ms = 300;
  config.refine_after_ms = {};
  return config;
}

}  // namespace

TEST(StreamEncodesNothingWithoutViewersOrDamage) {
  rb::FrameSink sink;
  Painted(&sink);
  std::atomic<int> starts{0};
  RecordingSender sender;
  rb::TabStreamer streamer(
      &sink, [&] { return std::make_unique<FakeEncoder>(&starts); }, &sender, FastConfig());
  Paint(&sink, &streamer, 10);
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  CHECK_EQ(sender.count(), 0u);
  CHECK_EQ(starts.load(), 0);
  streamer.AddViewer(1, true);
  CHECK(sender.WaitForCount(1));
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  CHECK_EQ(sender.count(), 1u);  // Idle page: one IDR, then nothing.
  CHECK_EQ(streamer.frames_encoded(), 1u);
}

TEST(StreamStartsEveryViewerOnAnIdrAndHonoursTheWindow) {
  rb::FrameSink sink;
  Painted(&sink);
  std::atomic<int> starts{0};
  RecordingSender sender;
  rb::TabStreamer streamer(
      &sink, [&] { return std::make_unique<FakeEncoder>(&starts); }, &sender, FastConfig());
  streamer.AddViewer(1, true);
  CHECK(sender.WaitForCount(1));
  std::vector<Sent> first = sender.For(1);
  CHECK_EQ(first[0].header.seq, 1u);
  CHECK_EQ(first[0].header.stream_id, 1u);
  CHECK_EQ(first[0].header.flags, rb::kMediaFlagKeyframe | rb::kMediaFlagNewStream);
  // A second frame fits the window (1 unacked < 2); a third must wait for an ack.
  Paint(&sink, &streamer, 20);
  CHECK(sender.WaitForCount(2));
  Paint(&sink, &streamer, 30);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  CHECK_EQ(sender.count(), 2u);
  streamer.Ack(1, 2);
  CHECK(sender.WaitForCount(3));
  std::vector<Sent> deltas = sender.For(1);
  CHECK_EQ(deltas[1].header.flags, 0);
  CHECK_EQ(deltas[2].header.seq, 3u);
  streamer.Ack(1, 3);

  // A new viewer forces an IDR with a new stream_id for both.
  streamer.AddViewer(2, true);
  CHECK(sender.WaitForCount(5));
  std::vector<Sent> second = sender.For(2);
  CHECK_EQ(second.size(), 1u);
  CHECK_EQ(second[0].header.seq, 1u);
  CHECK_EQ(second[0].header.stream_id, 2u);
  CHECK((second[0].header.flags & rb::kMediaFlagKeyframe) != 0);
  CHECK_EQ(sender.For(1).back().header.stream_id, 2u);
}

TEST(StreamHiddenViewersGetNothingAndAnIdrWhenVisible) {
  rb::FrameSink sink;
  Painted(&sink);
  std::atomic<int> starts{0};
  RecordingSender sender;
  rb::TabStreamer streamer(
      &sink, [&] { return std::make_unique<FakeEncoder>(&starts); }, &sender, FastConfig());
  streamer.AddViewer(1, false);
  Paint(&sink, &streamer, 40);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  CHECK_EQ(sender.count(), 0u);
  streamer.SetVisible(1, true);
  CHECK(sender.WaitForCount(1));
  CHECK((sender.For(1)[0].header.flags & rb::kMediaFlagKeyframe) != 0);
}

TEST(StreamClosesStalledViewers) {
  rb::FrameSink sink;
  Painted(&sink);
  std::atomic<int> starts{0};
  RecordingSender sender;
  rb::TabStreamer streamer(
      &sink, [&] { return std::make_unique<FakeEncoder>(&starts); }, &sender, FastConfig());
  streamer.AddViewer(7, true);
  CHECK(sender.WaitForCount(1));
  std::this_thread::sleep_for(std::chrono::milliseconds(700));
  std::lock_guard<std::mutex> lock(sender.mutex);
  CHECK_EQ(sender.stalled.size(), 1u);
  CHECK_EQ(sender.stalled[0], 7u);
}

TEST(StreamSettingsChangeRestartsTheEncoderWithAnIdr) {
  rb::FrameSink sink;
  Painted(&sink);
  std::atomic<int> starts{0};
  RecordingSender sender;
  rb::TabStreamer streamer(
      &sink, [&] { return std::make_unique<FakeEncoder>(&starts); }, &sender, FastConfig());
  streamer.AddViewer(1, true);
  CHECK(sender.WaitForCount(1));
  streamer.Ack(1, 1);
  rb::protocol::Settings settings;
  settings.max_fps = 30;
  settings.quality = "high";
  streamer.ApplySettings(settings);
  CHECK(sender.WaitForCount(2));
  CHECK_EQ(starts.load(), 2);
  CHECK_EQ(sender.For(1)[1].header.stream_id, 2u);
}

TEST(StreamTakingControlNeedsNoEncoderRestart) {
  rb::FrameSink sink;
  Painted(&sink);
  std::atomic<int> starts{0};
  RecordingSender sender;
  rb::TabStreamer streamer(
      &sink, [&] { return std::make_unique<FakeEncoder>(&starts); }, &sender, FastConfig());
  streamer.AddViewer(1, true);
  CHECK(sender.WaitForCount(1));
  streamer.Ack(1, 1);
  streamer.SetUserInControl(true);
  Paint(&sink, &streamer, 50);
  CHECK(sender.WaitForCount(2));
  CHECK_EQ(starts.load(), 1);
  CHECK_EQ(sender.For(1)[1].header.flags, 0);
}

TEST(StreamRefinesAnIdlePictureThenStops) {
  rb::FrameSink sink;
  Painted(&sink);
  std::atomic<int> starts{0};
  RecordingSender sender;
  rb::StreamConfig config = FastConfig();
  config.refine_after_ms = {50, 100};
  rb::TabStreamer streamer(
      &sink, [&] { return std::make_unique<FakeEncoder>(&starts); }, &sender, config);
  streamer.AddViewer(1, true);
  CHECK(sender.WaitForCount(1));
  streamer.Ack(1, 1);
  CHECK(sender.WaitForCount(2));
  streamer.Ack(1, 2);
  CHECK(sender.WaitForCount(3));
  streamer.Ack(1, 3);
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  CHECK_EQ(sender.count(), 3u);  // IDR plus two refinements, then nothing.
  CHECK_EQ(sender.For(1)[1].header.flags, 0);
}

TEST(StreamSendsNothingBeforeTheFirstPaint) {
  rb::FrameSink sink;
  sink.Resize(64, 32);
  std::atomic<int> starts{0};
  RecordingSender sender;
  rb::TabStreamer streamer(
      &sink, [&] { return std::make_unique<FakeEncoder>(&starts); }, &sender, FastConfig());
  streamer.AddViewer(1, true);
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  CHECK_EQ(sender.count(), 0u);
  Paint(&sink, &streamer, 30);
  CHECK(sender.WaitForCount(1));
  CHECK((sender.For(1)[0].header.flags & rb::kMediaFlagKeyframe) != 0);
}

TEST(StreamStillsUseTheSeqSpaceWithStreamIdZero) {
  rb::FrameSink sink;
  Painted(&sink);
  std::atomic<int> starts{0};
  RecordingSender sender;
  rb::TabStreamer streamer(
      &sink, [&] { return std::make_unique<FakeEncoder>(&starts); }, &sender, FastConfig());
  Paint(&sink, &streamer, 90);
  streamer.AddViewer(1, false);
  std::string error;
  CHECK_MSG(streamer.SendStill(1, true, &error), error);
  CHECK(sender.WaitForCount(1));
  const Sent still = sender.For(1)[0];
  CHECK_EQ(still.header.kind, 3);
  CHECK_EQ(still.header.stream_id, 0u);
  CHECK_EQ(still.header.seq, 1u);
}

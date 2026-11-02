// The host.sock server: a Unix stream socket (mode 0600, same-UID peers only) carrying the
// framing in framing.h. One I/O thread polls every connection; sends are thread-safe and
// queued, so a slow reader never blocks the encoder or the CEF UI thread.
#pragma once

#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "core/framing.h"

namespace rb {

class SocketServer {
 public:
  struct Callbacks {
    std::function<void(uint64_t connection)> on_open;
    /// A complete frame (not close frames, which arrive as on_closed).
    std::function<void(uint64_t connection, Frame frame)> on_frame;
    /// The connection ended: `code` is the peer's close code, 1011 for EOF without one, or the
    /// code the server closed with.
    std::function<void(uint64_t connection, uint16_t code, const std::string& reason)> on_closed;
    std::function<void(const std::string& message)> log;
  };

  ~SocketServer();

  /// Binds and listens on `path` (replacing a stale socket file). The caller holds the profile
  /// lock, so no live host owns the path.
  bool Listen(const std::string& path, std::string* error);
  void Start(Callbacks callbacks);
  /// Closes every connection and the listener, and joins the I/O thread.
  void Stop();

  /// Queues bytes (one or more encoded frames). False when the connection is gone.
  bool Send(uint64_t connection, std::vector<uint8_t> bytes);
  bool SendText(uint64_t connection, const std::string& text);
  /// Queues a close frame; the socket shuts down once it is flushed.
  void Close(uint64_t connection, uint16_t code, const std::string& reason);
  size_t connection_count();
  size_t QueuedBytes(uint64_t connection);

 private:
  struct Connection {
    int fd = -1;
    FrameReader reader;
    std::deque<std::vector<uint8_t>> outbound;
    size_t outbound_offset = 0;
    size_t queued_bytes = 0;
    bool closing = false;  // A close frame is queued; no more sends.
    /// Our close frame is out: discard input until the peer closes or the deadline passes.
    bool half_closed = false;
    int64_t drop_deadline_ms = 0;
    uint16_t close_code = 0;
    std::string close_reason;
  };

  void Loop();
  void Wake();
  void Accept();
  /// Returns false when the connection must be dropped.
  bool ReadFrom(uint64_t id, Connection* connection);
  bool WriteTo(Connection* connection);
  void Drop(uint64_t id, uint16_t code, const std::string& reason);

  Callbacks callbacks_;
  std::string path_;
  int listen_fd_ = -1;
  int wake_read_ = -1;
  int wake_write_ = -1;
  std::thread thread_;
  std::mutex mutex_;
  bool stopping_ = false;
  uint64_t next_id_ = 1;
  std::map<uint64_t, std::unique_ptr<Connection>> connections_;
};

}  // namespace rb

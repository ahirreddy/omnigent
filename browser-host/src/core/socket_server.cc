#include "core/socket_server.h"

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstring>

#include "core/protocol.h"

namespace rb {

namespace {

bool SetNonBlocking(int fd) {
  const int flags = fcntl(fd, F_GETFL, 0);
  return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 &&
         fcntl(fd, F_SETFD, FD_CLOEXEC) == 0;
}

constexpr int64_t kCloseLingerMs = 2000;

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

bool PeerIsSameUser(int fd) {
#if defined(__APPLE__)
  uid_t uid = 0;
  gid_t gid = 0;
  if (getpeereid(fd, &uid, &gid) != 0) {
    return false;
  }
  return uid == geteuid();
#else
  ucred credentials{};
  socklen_t length = sizeof(credentials);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0) {
    return false;
  }
  return credentials.uid == geteuid();
#endif
}

}  // namespace

SocketServer::~SocketServer() { Stop(); }

bool SocketServer::Listen(const std::string& path, std::string* error) {
  sockaddr_un address{};
  if (path.size() >= sizeof(address.sun_path)) {
    *error = "socket path is longer than " + std::to_string(sizeof(address.sun_path) - 1) +
             " bytes: " + path;
    return false;
  }
  address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    *error = std::string("socket failed: ") + std::strerror(errno);
    return false;
  }
  if (unlink(path.c_str()) != 0 && errno != ENOENT) {
    *error = "cannot remove the stale socket " + path + ": " + std::strerror(errno);
    close(fd);
    return false;
  }
  // Bind under a restrictive umask so the socket never exists with wider permissions.
  const mode_t previous = umask(0177);
  const int bound = bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address));
  umask(previous);
  if (bound != 0) {
    *error = "cannot bind " + path + ": " + std::strerror(errno);
    close(fd);
    return false;
  }
  if (chmod(path.c_str(), 0600) != 0 || listen(fd, 64) != 0 || !SetNonBlocking(fd)) {
    *error = "cannot listen on " + path + ": " + std::strerror(errno);
    close(fd);
    return false;
  }
  int pipe_fds[2];
  if (pipe(pipe_fds) != 0 || !SetNonBlocking(pipe_fds[0]) || !SetNonBlocking(pipe_fds[1])) {
    *error = std::string("cannot create the wake pipe: ") + std::strerror(errno);
    close(fd);
    return false;
  }
  listen_fd_ = fd;
  wake_read_ = pipe_fds[0];
  wake_write_ = pipe_fds[1];
  path_ = path;
  return true;
}

void SocketServer::Start(Callbacks callbacks) {
  callbacks_ = std::move(callbacks);
  thread_ = std::thread(&SocketServer::Loop, this);
}

void SocketServer::Stop() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_ && !thread_.joinable()) {
      return;
    }
    stopping_ = true;
  }
  Wake();
  if (thread_.joinable()) {
    thread_.join();
  }
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto& [id, connection] : connections_) {
    close(connection->fd);
  }
  connections_.clear();
  if (listen_fd_ >= 0) {
    close(listen_fd_);
    listen_fd_ = -1;
    unlink(path_.c_str());
  }
  if (wake_read_ >= 0) {
    close(wake_read_);
    close(wake_write_);
    wake_read_ = wake_write_ = -1;
  }
}

void SocketServer::Wake() {
  if (wake_write_ >= 0) {
    const char byte = 1;
    // A full pipe already guarantees a wake-up, so EAGAIN needs no handling.
    if (write(wake_write_, &byte, 1) < 0 && errno != EAGAIN && callbacks_.log) {
      callbacks_.log(std::string("wake pipe write failed: ") + std::strerror(errno));
    }
  }
}

bool SocketServer::Send(uint64_t id, std::vector<uint8_t> bytes) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto found = connections_.find(id);
    if (found == connections_.end() || found->second->closing) {
      return false;
    }
    found->second->queued_bytes += bytes.size();
    found->second->outbound.push_back(std::move(bytes));
  }
  Wake();
  return true;
}

bool SocketServer::SendText(uint64_t id, const std::string& text) {
  return Send(id, EncodeTextFrame(text));
}

void SocketServer::Close(uint64_t id, uint16_t code, const std::string& reason) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto found = connections_.find(id);
    if (found == connections_.end() || found->second->closing) {
      return;
    }
    Connection& connection = *found->second;
    const std::vector<uint8_t> frame = EncodeCloseFrame(code, reason.substr(0, 123));
    connection.queued_bytes += frame.size();
    connection.outbound.push_back(frame);
    connection.closing = true;
    connection.close_code = code;
    connection.close_reason = reason;
  }
  Wake();
}

size_t SocketServer::connection_count() {
  std::lock_guard<std::mutex> lock(mutex_);
  return connections_.size();
}

size_t SocketServer::QueuedBytes(uint64_t id) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto found = connections_.find(id);
  return found == connections_.end() ? 0 : found->second->queued_bytes;
}

void SocketServer::Accept() {
  while (true) {
    const int fd = accept(listen_fd_, nullptr, nullptr);
    if (fd < 0) {
      if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && callbacks_.log) {
        callbacks_.log(std::string("accept failed: ") + std::strerror(errno));
      }
      return;
    }
    if (!PeerIsSameUser(fd)) {
      if (callbacks_.log) {
        callbacks_.log("refused a host.sock connection from another user");
      }
      close(fd);
      continue;
    }
    if (!SetNonBlocking(fd)) {
      if (callbacks_.log) {
        callbacks_.log(std::string("cannot configure a connection: ") + std::strerror(errno));
      }
      close(fd);
      continue;
    }
#if defined(__APPLE__)
    const int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    uint64_t id = 0;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      id = next_id_++;
      auto connection = std::make_unique<Connection>();
      connection->fd = fd;
      connections_[id] = std::move(connection);
    }
    if (callbacks_.on_open) {
      callbacks_.on_open(id);
    }
  }
}

bool SocketServer::ReadFrom(uint64_t id, Connection* connection) {
  uint8_t buffer[65536];
  while (true) {
    const ssize_t count = read(connection->fd, buffer, sizeof(buffer));
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return true;
      }
      connection->close_code = protocol::kCloseInternal;
      connection->close_reason = std::string("read failed: ") + std::strerror(errno);
      return false;
    }
    if (count == 0) {
      if (connection->half_closed) {
        return false;  // The peer finished after our close frame.
      }
      if (connection->close_code == 0) {
        connection->close_code = protocol::kCloseInternal;
        connection->close_reason = "EOF without a close frame";
      }
      return false;
    }
    if (connection->half_closed) {
      continue;  // Input after our close frame (late acks) is discarded.
    }
    connection->reader.Append(buffer, static_cast<size_t>(count));
    while (std::optional<Frame> frame = connection->reader.Next()) {
      if (frame->kind == FrameKind::kClose) {
        uint16_t code = protocol::kCloseNormal;
        std::string reason;
        if (!DecodeClosePayload(frame->payload, &code, &reason)) {
          code = protocol::kCloseProtocolError;
          reason = "malformed close frame";
        }
        connection->close_code = code;
        connection->close_reason = reason;
        return false;
      }
      if (callbacks_.on_frame) {
        callbacks_.on_frame(id, std::move(*frame));
      }
    }
    if (!connection->reader.error().empty()) {
      const bool too_large = connection->reader.error().find("exceeds") != std::string::npos;
      Close(id, too_large ? protocol::kCloseTooLarge : protocol::kCloseProtocolError,
            connection->reader.error());
      return true;  // Flush the close frame first.
    }
  }
}

bool SocketServer::WriteTo(Connection* connection) {
  while (!connection->outbound.empty()) {
    std::vector<uint8_t>& front = connection->outbound.front();
    const size_t remaining = front.size() - connection->outbound_offset;
#if defined(__APPLE__)
    const ssize_t count =
        write(connection->fd, front.data() + connection->outbound_offset, remaining);
#else
    const ssize_t count =
        send(connection->fd, front.data() + connection->outbound_offset, remaining, MSG_NOSIGNAL);
#endif
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return true;
      }
      if (connection->close_code == 0) {
        connection->close_code = protocol::kCloseInternal;
        connection->close_reason = std::string("write failed: ") + std::strerror(errno);
      }
      return false;
    }
    connection->outbound_offset += static_cast<size_t>(count);
    connection->queued_bytes -= static_cast<size_t>(count);
    if (connection->outbound_offset == front.size()) {
      connection->outbound.pop_front();
      connection->outbound_offset = 0;
    }
  }
  if (connection->closing && !connection->half_closed) {
    // Our close frame is out. Keep reading until the peer closes so its in-flight frames
    // do not turn into a reset on its side.
    shutdown(connection->fd, SHUT_WR);
    connection->half_closed = true;
    connection->drop_deadline_ms = NowMs() + kCloseLingerMs;
  }
  return true;
}

void SocketServer::Drop(uint64_t id, uint16_t code, const std::string& reason) {
  int fd = -1;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto found = connections_.find(id);
    if (found == connections_.end()) {
      return;
    }
    fd = found->second->fd;
    connections_.erase(found);
  }
  close(fd);
  if (callbacks_.on_closed) {
    callbacks_.on_closed(id, code, reason);
  }
}

void SocketServer::Loop() {
  std::vector<pollfd> fds;
  std::vector<uint64_t> ids;
  while (true) {
    fds.clear();
    ids.clear();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) {
        break;
      }
      fds.push_back({wake_read_, POLLIN, 0});
      fds.push_back({listen_fd_, POLLIN, 0});
      for (auto& [id, connection] : connections_) {
        short events = POLLIN;
        if (!connection->outbound.empty()) {
          events |= POLLOUT;
        }
        fds.push_back({connection->fd, events, 0});
        ids.push_back(id);
      }
    }
    if (poll(fds.data(), fds.size(), 500) < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (callbacks_.log) {
        callbacks_.log(std::string("poll failed: ") + std::strerror(errno));
      }
      break;
    }
    if ((fds[0].revents & POLLIN) != 0) {
      char drain[256];
      while (read(wake_read_, drain, sizeof(drain)) > 0) {
      }
    }
    if ((fds[1].revents & POLLIN) != 0) {
      Accept();
    }
    const int64_t now = NowMs();
    for (size_t index = 0; index < ids.size(); ++index) {
      const short revents = fds[index + 2].revents;
      const uint64_t id = ids[index];
      if (revents == 0) {
        bool expired = false;
        uint16_t code = 0;
        std::string reason;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          auto found = connections_.find(id);
          if (found != connections_.end() && found->second->half_closed &&
              now > found->second->drop_deadline_ms) {
            expired = true;
            code = found->second->close_code;
            reason = found->second->close_reason;
          }
        }
        if (expired) {
          Drop(id, code, reason);
        }
        continue;
      }
      Connection* connection = nullptr;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = connections_.find(id);
        if (found == connections_.end()) {
          continue;
        }
        connection = found->second.get();
      }
      // Only this thread erases connections, so `connection` stays valid here. Its outbound
      // queue is shared with Send(), so writes take the lock.
      bool keep = true;
      if ((revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
        keep = ReadFrom(id, connection);
      }
      if (keep && (revents & POLLOUT) != 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        keep = WriteTo(connection);
      }
      if (!keep) {
        Drop(id,
             connection->close_code == 0 ? static_cast<uint16_t>(protocol::kCloseInternal)
                                         : connection->close_code,
             connection->close_reason);
      }
    }
  }
}

}  // namespace rb

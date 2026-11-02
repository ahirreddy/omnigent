#include "core/host_files.h"

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <ctime>

namespace rb {

Json HostStateJson(const HostState& state) {
  Json json = Json::MakeObject();
  json.Set("pid", state.pid);
  json.Set("socket", state.socket);
  json.Set("cdp_port", state.cdp_port);
  json.Set("version", state.version);
  json.Set("profile", state.profile);
  json.Set("started_at", state.started_at);
  Json encoder = Json::MakeObject();
  encoder.Set("path", state.encoder_path);
  encoder.Set("kind", state.encoder_kind);
  json.Set("encoder", encoder);
  return json;
}

std::string Rfc3339Utc(int64_t unix_seconds) {
  const time_t seconds = static_cast<time_t>(unix_seconds);
  tm parts{};
  gmtime_r(&seconds, &parts);
  char buffer[32];
  std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &parts);
  return buffer;
}

bool MakePrivateDirectories(const std::string& path, std::string* error) {
  if (path.empty()) {
    *error = "empty directory path";
    return false;
  }
  for (size_t slash = path.find('/', 1);; slash = path.find('/', slash + 1)) {
    const std::string prefix = slash == std::string::npos ? path : path.substr(0, slash);
    if (!prefix.empty() && mkdir(prefix.c_str(), 0700) != 0 && errno != EEXIST) {
      *error = "cannot create " + prefix + ": " + std::strerror(errno);
      return false;
    }
    if (slash == std::string::npos) {
      break;
    }
  }
  struct stat info{};
  if (stat(path.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)) {
    *error = path + " is not a directory";
    return false;
  }
  if ((info.st_mode & 0777) != 0700 && chmod(path.c_str(), 0700) != 0) {
    *error = "cannot set mode 0700 on " + path + ": " + std::strerror(errno);
    return false;
  }
  return true;
}

int AcquireProfileLock(const std::string& profile_dir, std::string* error) {
  if (!MakePrivateDirectories(profile_dir, error)) {
    return -1;
  }
  const std::string path = profile_dir + "/host.lock";
  const int fd = open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) {
    *error = "cannot open " + path + ": " + std::strerror(errno);
    return -1;
  }
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    const int lock_errno = errno;
    close(fd);
    *error = lock_errno == EWOULDBLOCK ? "another omnigent-browser-host holds " + path
                                       : "cannot lock " + path + ": " + std::strerror(lock_errno);
    return -1;
  }
  return fd;
}

bool WriteHostState(const std::string& profile_dir, const HostState& state, std::string* error) {
  const std::string path = profile_dir + "/host.json";
  const std::string temporary = path + ".tmp." + std::to_string(getpid());
  const std::string text = HostStateJson(state).Dump() + "\n";
  const int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd < 0) {
    *error = "cannot create " + temporary + ": " + std::strerror(errno);
    return false;
  }
  size_t written = 0;
  while (written < text.size()) {
    const ssize_t count = write(fd, text.data() + written, text.size() - written);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count < 0) {
      *error = "cannot write " + temporary + ": " + std::strerror(errno);
      close(fd);
      unlink(temporary.c_str());
      return false;
    }
    written += static_cast<size_t>(count);
  }
  if (fsync(fd) != 0 || close(fd) != 0) {
    *error = "cannot flush " + temporary + ": " + std::strerror(errno);
    unlink(temporary.c_str());
    return false;
  }
  if (rename(temporary.c_str(), path.c_str()) != 0) {
    *error = "cannot rename " + temporary + " to " + path + ": " + std::strerror(errno);
    unlink(temporary.c_str());
    return false;
  }
  return true;
}

bool RemoveHostState(const std::string& profile_dir, std::string* error) {
  const std::string path = profile_dir + "/host.json";
  if (unlink(path.c_str()) != 0 && errno != ENOENT) {
    *error = "cannot remove " + path + ": " + std::strerror(errno);
    return false;
  }
  return true;
}

}  // namespace rb

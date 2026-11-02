#include "host/log.h"

#include <unistd.h>

#include <cstdio>
#include <mutex>

namespace rb {

namespace {
// Namespace scope: host sources build with -fno-threadsafe-statics (CEF's flags).
std::mutex log_mutex;
}  // namespace

void Log(const std::string& message) {
  std::lock_guard<std::mutex> lock(log_mutex);
  std::fprintf(stderr, "omnigent-browser-host[%d]: %s\n", getpid(), message.c_str());
  std::fflush(stderr);
}

}  // namespace rb

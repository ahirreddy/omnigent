// The profile directory's host.lock (singleton flock) and host.json (state file), section 5.7.
#pragma once

#include <cstdint>
#include <string>

#include "core/json.h"

namespace rb {

struct HostState {
  int64_t pid = 0;
  std::string socket;
  int cdp_port = 0;
  std::string version;
  std::string profile;
  std::string started_at;  // RFC 3339 UTC
  std::string encoder_path;
  std::string encoder_kind;
};

Json HostStateJson(const HostState& state);
/// RFC 3339 UTC, second precision ("2026-11-01T22:00:00Z").
std::string Rfc3339Utc(int64_t unix_seconds);

/// Creates `path` and missing parents with mode 0700 (existing directories are tightened to
/// 0700 only for `path` itself).
bool MakePrivateDirectories(const std::string& path, std::string* error);

/// Takes the exclusive flock on `profile_dir`/host.lock. Returns the fd (held for the process
/// lifetime) or -1 with `error`.
int AcquireProfileLock(const std::string& profile_dir, std::string* error);

/// Writes `profile_dir`/host.json atomically (temp file plus rename), mode 0600.
bool WriteHostState(const std::string& profile_dir, const HostState& state, std::string* error);
bool RemoveHostState(const std::string& profile_dir, std::string* error);

}  // namespace rb

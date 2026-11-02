// Command-line options of omnigent-browser-host (design doc section 5.7, "CLI").
#pragma once

#include <string>
#include <vector>

namespace rb {

struct HostOptions {
  std::string profile = "default";
  std::string data_dir;
  std::string profile_dir;
  std::string socket_path;
  int cdp_port = 0;
  std::string encoder;
  std::string headless_mode = "ozone";  // ozone | xvfb (Linux)
  int idle_exit_seconds = 600;
  bool no_sandbox = false;
  int encoder_threads = 1;
  /// CEF windowless frame rate while nobody watches a tab (agent-only pages).
  int idle_frame_rate = 30;
  /// Directory for BGRA frame recordings (tabs.record); empty disables the op.
  std::string record_dir;
  bool help = false;
};

/// Parses argv[1..]. `environment_data_dir` is $OMNIGENT_DATA_DIR (may be empty) and `home` is
/// $HOME, used for the default data directory.
bool ParseHostOptions(const std::vector<std::string>& arguments,
                      const std::string& environment_data_dir, const std::string& home,
                      HostOptions* options, std::string* error);

const char* HostUsage();

}  // namespace rb

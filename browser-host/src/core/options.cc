#include "core/options.h"

#include <cstdlib>

#include "core/protocol.h"

namespace rb {

namespace {

bool ParseInt(const std::string& text, int minimum, int maximum, int* out) {
  if (text.empty()) {
    return false;
  }
  char* end = nullptr;
  const long value = std::strtol(text.c_str(), &end, 10);
  if (*end != '\0' || value < minimum || value > maximum) {
    return false;
  }
  *out = static_cast<int>(value);
  return true;
}

}  // namespace

const char* HostUsage() {
  return "usage: omnigent-browser-host [--profile NAME] [--data-dir D] [--profile-dir P]\n"
         "         [--socket S] [--cdp-port N] [--encoder PATH] [--headless-mode ozone|xvfb]\n"
         "         [--idle-exit-seconds N] [--no-sandbox] [--encoder-threads N]\n"
         "         [--record-dir DIR] [--idle-frame-rate N]\n";
}

bool ParseHostOptions(const std::vector<std::string>& arguments,
                      const std::string& environment_data_dir, const std::string& home,
                      HostOptions* options, std::string* error) {
  for (size_t index = 0; index < arguments.size(); ++index) {
    std::string flag = arguments[index];
    std::string value;
    bool has_value = false;
    const size_t equals = flag.find('=');
    if (flag.rfind("--", 0) == 0 && equals != std::string::npos) {
      value = flag.substr(equals + 1);
      flag = flag.substr(0, equals);
      has_value = true;
    }
    auto take_value = [&]() -> bool {
      if (has_value) {
        return true;
      }
      if (index + 1 >= arguments.size()) {
        *error = flag + " needs a value";
        return false;
      }
      value = arguments[++index];
      return true;
    };
    if (flag == "--help" || flag == "-h") {
      options->help = true;
    } else if (flag == "--no-sandbox") {
      options->no_sandbox = true;
    } else if (flag == "--profile") {
      if (!take_value()) return false;
      options->profile = value;
    } else if (flag == "--data-dir") {
      if (!take_value()) return false;
      options->data_dir = value;
    } else if (flag == "--profile-dir") {
      if (!take_value()) return false;
      options->profile_dir = value;
    } else if (flag == "--socket") {
      if (!take_value()) return false;
      options->socket_path = value;
    } else if (flag == "--encoder") {
      if (!take_value()) return false;
      options->encoder = value;
    } else if (flag == "--record-dir") {
      if (!take_value()) return false;
      options->record_dir = value;
    } else if (flag == "--headless-mode") {
      if (!take_value()) return false;
      if (value != "ozone" && value != "xvfb") {
        *error = "--headless-mode must be ozone or xvfb";
        return false;
      }
      options->headless_mode = value;
    } else if (flag == "--cdp-port") {
      if (!take_value()) return false;
      if (!ParseInt(value, 0, 65535, &options->cdp_port) ||
          (options->cdp_port != 0 && options->cdp_port < 1024)) {
        *error = "--cdp-port must be 0 or 1024-65535";
        return false;
      }
    } else if (flag == "--idle-exit-seconds") {
      if (!take_value()) return false;
      if (!ParseInt(value, 0, 86400 * 365, &options->idle_exit_seconds)) {
        *error = "--idle-exit-seconds must be a non-negative integer";
        return false;
      }
    } else if (flag == "--idle-frame-rate") {
      if (!take_value()) return false;
      if (!ParseInt(value, 1, 60, &options->idle_frame_rate)) {
        *error = "--idle-frame-rate must be 1-60";
        return false;
      }
    } else if (flag == "--encoder-threads") {
      if (!take_value()) return false;
      if (!ParseInt(value, 1, 64, &options->encoder_threads)) {
        *error = "--encoder-threads must be 1-64";
        return false;
      }
    } else {
      *error = "unknown argument '" + arguments[index] + "'";
      return false;
    }
  }
  if (options->help) {
    return true;
  }
  if (!protocol::IsValidProfileName(options->profile)) {
    *error = "invalid profile name '" + options->profile + "' (expected [a-z0-9][a-z0-9_-]{0,31})";
    return false;
  }
  if (options->profile_dir.empty()) {
    if (options->data_dir.empty()) {
      if (!environment_data_dir.empty()) {
        options->data_dir = environment_data_dir + "/browser";
      } else if (!home.empty()) {
        options->data_dir = home + "/.omnigent/browser";
      } else {
        *error = "cannot pick a data directory: pass --data-dir or --profile-dir";
        return false;
      }
    }
    options->profile_dir = options->data_dir + "/profiles/" + options->profile;
  }
  if (options->socket_path.empty()) {
    options->socket_path = options->profile_dir + "/host.sock";
  }
  return true;
}

}  // namespace rb

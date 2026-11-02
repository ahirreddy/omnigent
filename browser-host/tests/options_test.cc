#include "core/options.h"
#include "test.h"

TEST(OptionsDefaultPathsFollowTheSpec) {
  rb::HostOptions options;
  std::string error;
  CHECK_MSG(rb::ParseHostOptions({"--profile", "work"}, "", "/home/a", &options, &error), error);
  CHECK_EQ(options.profile_dir, std::string("/home/a/.omnigent/browser/profiles/work"));
  CHECK_EQ(options.socket_path, std::string("/home/a/.omnigent/browser/profiles/work/host.sock"));
  rb::HostOptions with_data;
  CHECK(
      rb::ParseHostOptions({"--data-dir=/d", "--cdp-port", "9333"}, "", "/h", &with_data, &error));
  CHECK_EQ(with_data.profile_dir, std::string("/d/profiles/default"));
  CHECK_EQ(with_data.cdp_port, 9333);
  rb::HostOptions from_env;
  CHECK(rb::ParseHostOptions({}, "/env", "/h", &from_env, &error));
  CHECK_EQ(from_env.profile_dir, std::string("/env/browser/profiles/default"));
}

TEST(OptionsRejectBadValues) {
  std::string error;
  rb::HostOptions options;
  CHECK(!rb::ParseHostOptions({"--profile", "Bad"}, "", "/h", &options, &error));
  rb::HostOptions port;
  CHECK(!rb::ParseHostOptions({"--cdp-port", "80"}, "", "/h", &port, &error));
  rb::HostOptions unknown;
  CHECK(!rb::ParseHostOptions({"--bogus"}, "", "/h", &unknown, &error));
  rb::HostOptions rate;
  CHECK(!rb::ParseHostOptions({"--idle-frame-rate", "0"}, "", "/h", &rate, &error));
  rb::HostOptions mode;
  CHECK(!rb::ParseHostOptions({"--headless-mode", "wayland"}, "", "/h", &mode, &error));
}

// Child process and CPU accounting helpers (POSIX; Linux and macOS).
#pragma once

#include <sys/types.h>

#include <string>
#include <vector>

namespace rb {

struct ChildProcess {
  pid_t pid = -1;
  int stdin_fd = -1;   // Write end of the child's stdin.
  int stdout_fd = -1;  // Read end of the child's stdout.
  int stderr_fd = -1;  // Read end of the child's stderr.
};

/// The first executable named `name` on PATH, or empty.
std::string FindExecutableOnPath(const std::string& name);

/// Starts `argv` with stdin, stdout and stderr connected to pipes. `env_extra` entries
/// (NAME=value) are added to the current environment. All fds are close-on-exec in the parent.
bool SpawnWithPipes(const std::vector<std::string>& argv, const std::vector<std::string>& env_extra,
                    ChildProcess* child, std::string* error);

/// Runs `argv` to completion and returns its stdout and stderr combined plus the exit status.
bool RunCapture(const std::vector<std::string>& argv, std::string* output, int* exit_status,
                std::string* error);

/// Waits for `pid` and returns its total CPU seconds (user + system).
bool ReapChild(pid_t pid, double* cpu_seconds, std::string* error);

/// CPU seconds (user + system) used so far by a running process.
bool ProcessCpuTime(pid_t pid, double* cpu_seconds, std::string* error);

/// CPU seconds used so far by `pid` and all of its live descendants.
bool ProcessTreeCpuTime(pid_t pid, double* cpu_seconds, std::string* error);

/// Live descendants of `root` (children, grandchildren, ...), excluding `root`.
std::vector<pid_t> DescendantProcesses(pid_t root);

/// Sends `signal_number` to every live descendant of `root`. Returns how many were signalled.
int SignalDescendants(pid_t root, int signal_number);

/// Resident memory of `pid` and its live descendants, in bytes.
bool ProcessTreeResidentBytes(pid_t pid, long long* bytes, std::string* error);

}  // namespace rb

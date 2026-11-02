#include "core/process.h"

#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>

#if defined(__APPLE__)
#include <libproc.h>
#include <mach/mach_time.h>
#else
#include <dirent.h>
#endif

extern char** environ;

namespace rb {

namespace {

bool MakePipe(int fds[2], std::string* error) {
  if (pipe(fds) != 0) {
    *error = std::string("pipe failed: ") + std::strerror(errno);
    return false;
  }
  for (int index = 0; index < 2; ++index) {
    if (fcntl(fds[index], F_SETFD, FD_CLOEXEC) != 0) {
      *error = std::string("fcntl failed: ") + std::strerror(errno);
      close(fds[0]);
      close(fds[1]);
      return false;
    }
  }
  return true;
}

#if defined(__APPLE__)
double MachToSeconds(uint64_t ticks) {
  static mach_timebase_info_data_t timebase = [] {
    mach_timebase_info_data_t info{};
    mach_timebase_info(&info);
    return info;
  }();
  return static_cast<double>(ticks) * timebase.numer / timebase.denom / 1e9;
}

std::vector<pid_t> ChildrenOf(pid_t pid) {
  std::vector<pid_t> children(256);
  const int count =
      proc_listchildpids(pid, children.data(), static_cast<int>(children.size() * sizeof(pid_t)));
  children.resize(count > 0 ? static_cast<size_t>(count) : 0);
  return children;
}
#else
/// pid -> parent pid for every process visible in /proc.
std::map<pid_t, pid_t> ParentMap() {
  std::map<pid_t, pid_t> parents;
  DIR* directory = opendir("/proc");
  if (directory == nullptr) {
    return parents;
  }
  while (dirent* entry = readdir(directory)) {
    char* end = nullptr;
    const long pid = std::strtol(entry->d_name, &end, 10);
    if (end == entry->d_name || *end != '\0') {
      continue;
    }
    std::ifstream stat("/proc/" + std::string(entry->d_name) + "/stat");
    std::string line;
    if (!std::getline(stat, line)) {
      continue;
    }
    const size_t close_paren = line.rfind(')');
    if (close_paren == std::string::npos) {
      continue;
    }
    std::istringstream fields(line.substr(close_paren + 2));
    std::string state;
    long parent = 0;
    fields >> state >> parent;
    parents[static_cast<pid_t>(pid)] = static_cast<pid_t>(parent);
  }
  closedir(directory);
  return parents;
}

std::vector<pid_t> ChildrenOf(pid_t pid, const std::map<pid_t, pid_t>& parents) {
  std::vector<pid_t> children;
  for (const auto& [child, parent] : parents) {
    if (parent == pid) {
      children.push_back(child);
    }
  }
  return children;
}
#endif

std::vector<pid_t> Descendants(pid_t root) {
  std::vector<pid_t> all = {root};
#if !defined(__APPLE__)
  const std::map<pid_t, pid_t> parents = ParentMap();
#endif
  for (size_t index = 0; index < all.size(); ++index) {
#if defined(__APPLE__)
    const std::vector<pid_t> children = ChildrenOf(all[index]);
#else
    const std::vector<pid_t> children = ChildrenOf(all[index], parents);
#endif
    all.insert(all.end(), children.begin(), children.end());
  }
  return all;
}

}  // namespace

std::string FindExecutableOnPath(const std::string& name) {
  const char* path = std::getenv("PATH");
  if (path == nullptr) {
    return "";
  }
  std::stringstream entries(path);
  std::string directory;
  while (std::getline(entries, directory, ':')) {
    if (directory.empty()) {
      continue;
    }
    const std::string candidate = directory + "/" + name;
    if (access(candidate.c_str(), X_OK) == 0) {
      return candidate;
    }
  }
  return "";
}

bool SpawnWithPipes(const std::vector<std::string>& argv, const std::vector<std::string>& env_extra,
                    ChildProcess* child, std::string* error) {
  if (argv.empty()) {
    *error = "empty command line";
    return false;
  }
  int in[2];
  int out[2];
  int err[2];
  if (!MakePipe(in, error)) {
    return false;
  }
  if (!MakePipe(out, error)) {
    close(in[0]);
    close(in[1]);
    return false;
  }
  if (!MakePipe(err, error)) {
    close(in[0]);
    close(in[1]);
    close(out[0]);
    close(out[1]);
    return false;
  }
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO);
  posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO);

  std::vector<std::string> environment;
  for (char** entry = environ; *entry != nullptr; ++entry) {
    environment.emplace_back(*entry);
  }
  environment.insert(environment.end(), env_extra.begin(), env_extra.end());
  std::vector<char*> env_pointers;
  for (std::string& entry : environment) {
    env_pointers.push_back(entry.data());
  }
  env_pointers.push_back(nullptr);
  std::vector<std::string> arguments = argv;
  std::vector<char*> arg_pointers;
  for (std::string& argument : arguments) {
    arg_pointers.push_back(argument.data());
  }
  arg_pointers.push_back(nullptr);

  pid_t pid = -1;
  const int status = posix_spawn(&pid, arguments[0].c_str(), &actions, nullptr, arg_pointers.data(),
                                 env_pointers.data());
  posix_spawn_file_actions_destroy(&actions);
  close(in[0]);
  close(out[1]);
  close(err[1]);
  if (status != 0) {
    close(in[1]);
    close(out[0]);
    close(err[0]);
    *error = "cannot start " + arguments[0] + ": " + std::strerror(status);
    return false;
  }
  child->pid = pid;
  child->stdin_fd = in[1];
  child->stdout_fd = out[0];
  child->stderr_fd = err[0];
  return true;
}

bool RunCapture(const std::vector<std::string>& argv, std::string* output, int* exit_status,
                std::string* error) {
  ChildProcess child;
  if (!SpawnWithPipes(argv, {}, &child, error)) {
    return false;
  }
  close(child.stdin_fd);
  // Merge both streams; read stdout then stderr (version and encoder lists are small).
  for (int fd : {child.stdout_fd, child.stderr_fd}) {
    char buffer[4096];
    while (true) {
      const ssize_t count = read(fd, buffer, sizeof(buffer));
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        break;
      }
      output->append(buffer, static_cast<size_t>(count));
    }
    close(fd);
  }
  int status = 0;
  while (waitpid(child.pid, &status, 0) < 0) {
    if (errno != EINTR) {
      *error = std::string("waitpid failed: ") + std::strerror(errno);
      return false;
    }
  }
  *exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
  return true;
}

bool ReapChild(pid_t pid, double* cpu_seconds, std::string* error) {
  int status = 0;
  rusage usage{};
  while (wait4(pid, &status, 0, &usage) < 0) {
    if (errno != EINTR) {
      *error = std::string("wait4 failed: ") + std::strerror(errno);
      return false;
    }
  }
  *cpu_seconds = static_cast<double>(usage.ru_utime.tv_sec) + usage.ru_utime.tv_usec / 1e6 +
                 static_cast<double>(usage.ru_stime.tv_sec) + usage.ru_stime.tv_usec / 1e6;
  return true;
}

#if !defined(__APPLE__)
namespace {

/// utime + stime from /proc/<pid>/stat: cumulative (exited threads included), 10 ms ticks.
bool ProcessCpuTicks(pid_t pid, double* cpu_seconds, std::string* error) {
  std::ifstream stat("/proc/" + std::to_string(pid) + "/stat");
  std::string line;
  if (!std::getline(stat, line)) {
    *error = "cannot read /proc/" + std::to_string(pid) + "/stat";
    return false;
  }
  const size_t close_paren = line.rfind(')');
  if (close_paren == std::string::npos) {
    *error = "malformed /proc/" + std::to_string(pid) + "/stat";
    return false;
  }
  std::istringstream fields(line.substr(close_paren + 2));
  std::string field;
  // Fields after the command: state is field 3; utime and stime are fields 14 and 15.
  unsigned long long utime = 0;
  unsigned long long stime = 0;
  for (int index = 3; index <= 15 && fields >> field; ++index) {
    if (index == 14) {
      utime = std::strtoull(field.c_str(), nullptr, 10);
    } else if (index == 15) {
      stime = std::strtoull(field.c_str(), nullptr, 10);
    }
  }
  *cpu_seconds = static_cast<double>(utime + stime) / static_cast<double>(sysconf(_SC_CLK_TCK));
  return true;
}

/// Sum of the live threads' run time from /proc/<pid>/task/*/schedstat (nanoseconds).
bool ProcessCpuSchedstat(pid_t pid, double* cpu_seconds) {
  const std::string tasks = "/proc/" + std::to_string(pid) + "/task";
  DIR* directory = opendir(tasks.c_str());
  if (directory == nullptr) {
    return false;
  }
  unsigned long long total = 0;
  bool any = false;
  while (dirent* entry = readdir(directory)) {
    if (entry->d_name[0] == '.') {
      continue;
    }
    std::ifstream schedstat(tasks + "/" + entry->d_name + "/schedstat");
    unsigned long long runtime = 0;
    if (schedstat >> runtime) {
      total += runtime;
      any = true;
    }
  }
  closedir(directory);
  *cpu_seconds = static_cast<double>(total) / 1e9;
  return any;
}

}  // namespace
#endif

bool ProcessCpuTime(pid_t pid, double* cpu_seconds, std::string* error) {
#if defined(__APPLE__)
  rusage_info_v2 info{};
  if (proc_pid_rusage(pid, RUSAGE_INFO_V2, reinterpret_cast<rusage_info_t*>(&info)) != 0) {
    *error = "proc_pid_rusage(" + std::to_string(pid) + ") failed: " + std::strerror(errno);
    return false;
  }
  *cpu_seconds = MachToSeconds(info.ri_user_time + info.ri_system_time);
  return true;
#else
  // Nanosecond run time of the live threads; the tick count also covers exited threads.
  double ticks = 0;
  if (!ProcessCpuTicks(pid, &ticks, error)) {
    return false;
  }
  double precise = 0;
  *cpu_seconds = ProcessCpuSchedstat(pid, &precise) ? std::max(precise, ticks) : ticks;
  return true;
#endif
}

bool ProcessTreeCpuTime(pid_t pid, double* cpu_seconds, std::string* error) {
  double total = 0;
  bool any = false;
  for (pid_t member : Descendants(pid)) {
    double seconds = 0;
    std::string ignored;
    if (ProcessCpuTime(member, &seconds, &ignored)) {
      total += seconds;
      any = true;
    }
  }
  if (!any) {
    *error = "process " + std::to_string(pid) + " is gone";
    return false;
  }
  *cpu_seconds = total;
  return true;
}

std::vector<pid_t> DescendantProcesses(pid_t root) {
  std::vector<pid_t> all = Descendants(root);
  all.erase(all.begin());
  return all;
}

int SignalDescendants(pid_t root, int signal_number) {
  int count = 0;
  for (pid_t pid : DescendantProcesses(root)) {
    if (kill(pid, signal_number) == 0) {
      ++count;
    }
  }
  return count;
}

bool ProcessTreeResidentBytes(pid_t pid, long long* bytes, std::string* error) {
  long long total = 0;
  bool any = false;
  for (pid_t member : Descendants(pid)) {
#if defined(__APPLE__)
    proc_taskinfo info{};
    if (proc_pidinfo(member, PROC_PIDTASKINFO, 0, &info, sizeof(info)) ==
        static_cast<int>(sizeof(info))) {
      total += static_cast<long long>(info.pti_resident_size);
      any = true;
    }
#else
    std::ifstream statm("/proc/" + std::to_string(member) + "/statm");
    long long size = 0;
    long long resident = 0;
    if (statm >> size >> resident) {
      total += resident * sysconf(_SC_PAGESIZE);
      any = true;
    }
#endif
  }
  if (!any) {
    *error = "process " + std::to_string(pid) + " is gone";
    return false;
  }
  *bytes = total;
  return true;
}

}  // namespace rb

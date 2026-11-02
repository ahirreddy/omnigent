#include "core/encoder.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <sstream>

#include "core/frame_sink.h"
#include "core/process.h"

extern char** environ;

namespace rb {

namespace {

constexpr size_t kStderrTailBytes = 4096;
// A frame number no stream reaches; x264 parks its qpfile read position on this line.
constexpr char kQpfileSentinelLine[] = "2000000000 P\n";
// Whitespace before every qpfile line, longer than any stdio buffer (st_blksize, 4 KiB on APFS
// and ext4): x264 then re-reads the file after each seek instead of its buffered copy.
constexpr size_t kQpfilePadBytes = 16 * 1024;

std::string QpfileRecord(const std::string& line) {
  return std::string(kQpfilePadBytes, ' ') + line;
}

bool WriteAll(int fd, const uint8_t* data, size_t size, std::string* error) {
  while (size > 0) {
    const ssize_t written = write(fd, data, size);
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      *error = std::string("write to the encoder failed: ") + std::strerror(errno);
      return false;
    }
    data += written;
    size -= static_cast<size_t>(written);
  }
  return true;
}

bool PwriteAll(int fd, const std::string& text, off_t offset, std::string* error) {
  size_t done = 0;
  while (done < text.size()) {
    const ssize_t written =
        pwrite(fd, text.data() + done, text.size() - done, offset + static_cast<off_t>(done));
    if (written < 0) {
      if (errno == EINTR) {
        continue;
      }
      *error = std::string("qpfile write failed: ") + std::strerror(errno);
      return false;
    }
    done += static_cast<size_t>(written);
  }
  return true;
}

}  // namespace

const char* EncoderKindName(EncoderKind kind) {
  return kind == EncoderKind::kX264 ? "x264" : "ffmpeg";
}

bool ResolveEncoder(const std::string& requested, EncoderInfo* info, std::string* error) {
  std::string path = requested;
  if (path.empty()) {
    path = FindExecutableOnPath("x264");
    if (path.empty()) {
      path = FindExecutableOnPath("ffmpeg");
    }
    if (path.empty()) {
      *error = "no H.264 encoder found: install x264 (or ffmpeg with libx264) or pass --encoder";
      return false;
    }
  } else if (path.find('/') == std::string::npos) {
    const std::string found = FindExecutableOnPath(path);
    if (found.empty()) {
      *error = "encoder '" + requested + "' is not on PATH";
      return false;
    }
    path = found;
  }
  const size_t slash = path.find_last_of('/');
  const std::string base = slash == std::string::npos ? path : path.substr(slash + 1);
  info->path = path;
  info->kind = base.find("ffmpeg") != std::string::npos ? EncoderKind::kFfmpeg : EncoderKind::kX264;
  std::string output;
  int status = 0;
  if (info->kind == EncoderKind::kX264) {
    if (!RunCapture({path, "--version"}, &output, &status, error)) {
      return false;
    }
    if (status != 0) {
      *error = path + " --version exited with status " + std::to_string(status);
      return false;
    }
  } else {
    if (!RunCapture({path, "-hide_banner", "-encoders"}, &output, &status, error)) {
      return false;
    }
    if (status != 0 || output.find(" libx264 ") == std::string::npos) {
      *error = path + " has no libx264 encoder";
      return false;
    }
    std::string version_output;
    if (RunCapture({path, "-hide_banner", "-version"}, &version_output, &status, error)) {
      output = version_output;
    }
  }
  info->version = output.substr(0, output.find('\n'));
  return true;
}

SubprocessEncoder::SubprocessEncoder(EncoderInfo info, std::string shim_library,
                                     std::string work_dir)
    : info_(std::move(info)),
      shim_library_(std::move(shim_library)),
      work_dir_(std::move(work_dir)),
      in_stream_idr_(info_.kind == EncoderKind::kX264) {}

SubprocessEncoder::~SubprocessEncoder() { Stop(); }

const char* SubprocessEncoder::name() const { return EncoderKindName(info_.kind); }

std::string SubprocessEncoder::keyframe_mode() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return in_stream_idr_ ? "in_stream" : "restart";
}

std::vector<std::string> SubprocessEncoder::CommandLine(const EncoderSettings& settings) const {
  const int fps = std::max(1, settings.fps);
  const int bitrate = std::max(50, settings.bitrate_kbps);
  const int vbv = std::max(1, static_cast<int>(bitrate * settings.vbv_frames / fps));
  const std::string size = std::to_string(settings.width) + "x" + std::to_string(settings.height);
  if (info_.kind == EncoderKind::kX264) {
    std::vector<std::string> argv = {info_.path,
                                     "--quiet",
                                     "--no-progress",
                                     "--demuxer",
                                     "raw",
                                     "--input-csp",
                                     "i420",
                                     "--input-res",
                                     size,
                                     "--fps",
                                     std::to_string(fps),
                                     "--preset",
                                     settings.preset,
                                     "--tune",
                                     "zerolatency",
                                     "--profile",
                                     "baseline",
                                     "--keyint",
                                     "infinite",
                                     "--no-scenecut",
                                     "--bframes",
                                     "0",
                                     "--ref",
                                     "1",
                                     "--threads",
                                     std::to_string(settings.threads),
                                     "--crf",
                                     std::to_string(settings.crf),
                                     "--vbv-maxrate",
                                     std::to_string(bitrate),
                                     "--vbv-bufsize",
                                     std::to_string(vbv),
                                     "--colorprim",
                                     "bt709",
                                     "--transfer",
                                     "bt709",
                                     "--colormatrix",
                                     "bt709",
                                     "--range",
                                     "tv"};
    if (!qpfile_path_.empty()) {
      argv.push_back("--qpfile");
      argv.push_back(qpfile_path_);
    }
    argv.insert(argv.end(), {"--muxer", "flv", "-o", "-", "-"});
    return argv;
  }
  const std::string x264_params = "keyint=infinite:min-keyint=infinite:scenecut=0:bframes=0:ref=1";
  return {info_.path,
          "-hide_banner",
          "-loglevel",
          "error",
          "-nostats",
          "-f",
          "rawvideo",
          "-pix_fmt",
          "yuv420p",
          "-video_size",
          size,
          "-framerate",
          std::to_string(fps),
          "-i",
          "pipe:0",
          "-an",
          "-c:v",
          "libx264",
          "-preset",
          settings.preset,
          "-tune",
          "zerolatency",
          "-profile:v",
          "baseline",
          "-threads",
          std::to_string(settings.threads),
          "-x264-params",
          x264_params,
          "-crf",
          std::to_string(settings.crf),
          "-maxrate",
          std::to_string(bitrate) + "k",
          "-bufsize",
          std::to_string(vbv) + "k",
          "-color_primaries",
          "bt709",
          "-color_trc",
          "bt709",
          "-colorspace",
          "bt709",
          "-color_range",
          "tv",
          "-flush_packets",
          "1",
          "-flvflags",
          "no_duration_filesize",
          "-f",
          "flv",
          "pipe:1"};
}

bool SubprocessEncoder::Start(const EncoderSettings& settings, OutputCallback on_frame,
                              ErrorCallback on_error, std::string* error) {
  Stop();
  std::lock_guard<std::mutex> lock(mutex_);
  if (settings.width <= 0 || settings.height <= 0 || settings.width % 2 != 0 ||
      settings.height % 2 != 0) {
    *error = "encoder dimensions must be positive and even";
    return false;
  }
  if (info_.kind == EncoderKind::kX264 && shim_library_.empty()) {
    *error = "x264 needs the unbuffered-stdout shim library, which was not found";
    return false;
  }
  settings_ = settings;
  on_frame_ = std::move(on_frame);
  on_error_ = std::move(on_error);
  stopping_ = false;
  return SpawnLocked(error);
}

bool SubprocessEncoder::SpawnLocked(std::string* error) {
  if (info_.kind == EncoderKind::kX264 && in_stream_idr_) {
    // A fresh qpfile per process: x264 re-reads it before every frame, and the sentinel line
    // keeps it from reaching EOF (where it would close the file for good).
    qpfile_path_ = work_dir_ + "/x264-qpfile-" + std::to_string(getpid()) + "-" +
                   std::to_string(reinterpret_cast<uintptr_t>(this)) + ".txt";
    if (qpfile_fd_ >= 0) {
      close(qpfile_fd_);
    }
    qpfile_fd_ = open(qpfile_path_.c_str(), O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (qpfile_fd_ < 0) {
      *error = "cannot create the x264 qpfile " + qpfile_path_ + ": " + std::strerror(errno);
      return false;
    }
    qpfile_sentinel_offset_ = 0;
    last_idr_request_.reset();
    if (!PwriteAll(qpfile_fd_, QpfileRecord(kQpfileSentinelLine), 0, error)) {
      return false;
    }
  } else {
    qpfile_path_.clear();
  }

  std::vector<std::string> env_extra;
  if (info_.kind == EncoderKind::kX264) {
#if defined(__APPLE__)
    env_extra.push_back("DYLD_INSERT_LIBRARIES=" + shim_library_);
#else
    env_extra.push_back("LD_PRELOAD=" + shim_library_);
#endif
  }
  ChildProcess child;
  if (!SpawnWithPipes(CommandLine(settings_), env_extra, &child, error)) {
    return false;
  }
  pid_ = child.pid;
  stdin_fd_ = child.stdin_fd;
  next_frame_number_ = 0;
  pending_.clear();
  stderr_tail_.clear();
  const uint64_t generation = ++generation_;
  reader_ = std::thread(&SubprocessEncoder::ReaderLoop, this, child.pid, child.stdout_fd,
                        child.stderr_fd, generation);
  return true;
}

void SubprocessEncoder::KillLocked() {
  // Callers release the lock before joining; see Stop() and Submit().
  if (stdin_fd_ >= 0) {
    close(stdin_fd_);
    stdin_fd_ = -1;
  }
  if (pid_ > 0) {
    kill(pid_, SIGKILL);
  }
  ++generation_;
  pending_.clear();
}

void SubprocessEncoder::Stop() {
  std::thread reader;
  pid_t pid = -1;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
    KillLocked();
    reader.swap(reader_);
    pid = pid_;
    pid_ = -1;
    if (qpfile_fd_ >= 0) {
      close(qpfile_fd_);
      qpfile_fd_ = -1;
      unlink(qpfile_path_.c_str());
    }
  }
  if (reader.joinable()) {
    reader.join();
  }
  if (pid > 0) {
    double cpu = 0;
    std::string ignored_error;
    if (ReapChild(pid, &cpu, &ignored_error)) {
      std::lock_guard<std::mutex> lock(mutex_);
      finished_cpu_seconds_ += cpu;
    }
  }
}

bool SubprocessEncoder::running() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return pid_ > 0 && stdin_fd_ >= 0;
}

int SubprocessEncoder::pending() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return static_cast<int>(pending_.size());
}

double SubprocessEncoder::CpuSeconds() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return finished_cpu_seconds_ + (pid_ > 0 ? ProcessCpuSeconds(pid_) : 0);
}

double SubprocessEncoder::ProcessCpuSeconds(pid_t pid) const {
  double seconds = 0;
  std::string ignored;
  if (!ProcessCpuTime(pid, &seconds, &ignored)) {
    return 0;  // The process just exited; its time is added when it is reaped.
  }
  return seconds;
}

// x264 reads the qpfile with fscanf(" %99[^\n]\n"): the trailing `\n` skips whitespace and
// peeks at the next line, so after a request line x264 has already buffered the sentinel that
// follows it. A request for the very next frame is therefore read from the stale buffer and
// missed; x264 then seeks back (discarding the buffer) and sees the following request. The
// streamer asks again when a requested IDR does not come, so that IDR lands one frame later.
bool SubprocessEncoder::RequestInStreamIdr(uint64_t frame_number, std::string* error) {
  const std::string line = QpfileRecord(std::to_string(frame_number) + " I\n");
  // Overwrite the sentinel with the request and put the sentinel back after it.
  if (!PwriteAll(qpfile_fd_, line + QpfileRecord(kQpfileSentinelLine), qpfile_sentinel_offset_,
                 error)) {
    return false;
  }
  qpfile_sentinel_offset_ += static_cast<off_t>(line.size());
  last_idr_request_ = frame_number;
  return true;
}

bool SubprocessEncoder::Submit(const I420Frame& frame, uint64_t pts_us, bool keyframe,
                               std::string* error) {
  int fd = -1;
  {
    std::unique_lock<std::mutex> lock(mutex_);
    if (pid_ <= 0 || stdin_fd_ < 0) {
      *error = "the encoder is not running";
      return false;
    }
    if (frame.width() != settings_.width || frame.height() != settings_.height) {
      *error = "frame size does not match the encoder";
      return false;
    }
    // Decided before this frame's own request updates `last_idr_request_`.
    bool request_visible =
        !in_stream_idr_ || !last_idr_request_ || *last_idr_request_ + 1 != next_frame_number_;
    if (keyframe && next_frame_number_ > 0) {
      if (in_stream_idr_) {
        if (!RequestInStreamIdr(next_frame_number_, error)) {
          return false;
        }
      } else {
        // Restart: the new process's first frame is an IDR.
        KillLocked();
        std::thread reader;
        reader.swap(reader_);
        const pid_t old_pid = pid_;
        pid_ = -1;
        lock.unlock();
        if (reader.joinable()) {
          reader.join();
        }
        double cpu = 0;
        std::string reap_error;
        const bool reaped = ReapChild(old_pid, &cpu, &reap_error);
        lock.lock();
        if (reaped) {
          finished_cpu_seconds_ += cpu;
        }
        if (stopping_) {
          *error = "the encoder was stopped";
          return false;
        }
        if (!SpawnLocked(error)) {
          return false;
        }
        request_visible = true;
      }
    }
    pending_.push_back(
        Pending{next_frame_number_++, pts_us, MonotonicMicros(), keyframe, request_visible});
    fd = stdin_fd_;
  }
  // The write blocks while the encoder works; the lock stays free for the reader.
  if (!WriteAll(fd, frame.data(), frame.size(), error)) {
    *error += " (" + StderrTail() + ")";
    return false;
  }
  return true;
}

std::string SubprocessEncoder::StderrTail() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return stderr_tail_.empty() ? "no encoder output" : stderr_tail_;
}

void SubprocessEncoder::ReaderLoop(pid_t pid, int stdout_fd, int stderr_fd, uint64_t generation) {
  FlvDemuxer demuxer;
  std::vector<uint8_t> chunk(1 << 16);
  bool stdout_open = true;
  bool stderr_open = true;
  std::string failure;
  while (stdout_open || stderr_open) {
    pollfd fds[2] = {{stdout_open ? stdout_fd : -1, POLLIN, 0},
                     {stderr_open ? stderr_fd : -1, POLLIN, 0}};
    const int ready = poll(fds, 2, -1);
    if (ready < 0) {
      if (errno == EINTR) {
        continue;
      }
      failure = std::string("poll on the encoder failed: ") + std::strerror(errno);
      break;
    }
    if (stderr_open && (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
      const ssize_t count = read(stderr_fd, chunk.data(), chunk.size());
      if (count <= 0) {
        stderr_open = false;
      } else {
        std::lock_guard<std::mutex> lock(mutex_);
        stderr_tail_.append(reinterpret_cast<const char*>(chunk.data()),
                            static_cast<size_t>(count));
        if (stderr_tail_.size() > kStderrTailBytes) {
          stderr_tail_.erase(0, stderr_tail_.size() - kStderrTailBytes);
        }
      }
    }
    if (stdout_open && (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
      const ssize_t count = read(stdout_fd, chunk.data(), chunk.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        stdout_open = false;
        continue;
      }
      demuxer.Append(chunk.data(), static_cast<size_t>(count));
      if (!demuxer.error().empty()) {
        failure = "encoder output: " + demuxer.error();
        break;
      }
      for (AccessUnit& unit : demuxer.TakeAccessUnits()) {
        EncodedFrame encoded;
        bool requested_but_missing = false;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          if (generation != generation_) {
            continue;  // Output of a process that was replaced.
          }
          if (pending_.empty()) {
            failure = "the encoder produced more frames than it was given";
            break;
          }
          const Pending submitted = pending_.front();
          pending_.pop_front();
          encoded.frame_number = submitted.frame_number;
          encoded.pts_us = submitted.pts_us;
          encoded.submit_us = submitted.submit_us;
          encoded.keyframe_requested = submitted.keyframe;
          // A request x264 could not see is retried by the streamer, not a failure.
          requested_but_missing = submitted.keyframe && !unit.keyframe && submitted.request_visible;
          if (requested_but_missing && in_stream_idr_) {
            in_stream_idr_ = false;  // The qpfile did not work; restart for later IDRs.
          }
        }
        if (requested_but_missing && on_error_) {
          on_error_("x264 ignored a qpfile IDR request; switching to encoder restarts");
        }
        encoded.annexb = std::move(unit.annexb);
        encoded.keyframe = unit.keyframe;
        encoded.output_us = MonotonicMicros();
        if (on_frame_) {
          on_frame_(std::move(encoded));
        }
      }
      if (!failure.empty()) {
        break;
      }
    }
  }
  close(stdout_fd);
  close(stderr_fd);
  bool report = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    report = generation == generation_ && !stopping_;
    if (report && failure.empty()) {
      failure = "the encoder (pid " + std::to_string(pid) +
                ") exited: " + (stderr_tail_.empty() ? "no output" : stderr_tail_);
    }
    if (report) {
      // Leave the dead process for Stop() to reap; mark it unusable.
      if (stdin_fd_ >= 0) {
        close(stdin_fd_);
        stdin_fd_ = -1;
      }
      pending_.clear();
    }
  }
  if (report && on_error_) {
    on_error_(failure);
  }
}

}  // namespace rb

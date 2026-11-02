#include <signal.h>

#include <cstring>
#include <fstream>
#include <sstream>

#include "test.h"

namespace rb::test {

namespace {
int failures = 0;
const char* current = "";
}  // namespace

std::vector<Case>& Registry() {
  static std::vector<Case> cases;
  return cases;
}

void Fail(const char* file, int line, const std::string& message) {
  std::fprintf(stderr, "FAIL %s (%s:%d): %s\n", current, file, line, message.c_str());
  ++failures;
}

std::string FixturePath(const std::string& relative) {
  return std::string(RB_FIXTURE_DIR) + "/" + relative;
}

bool ReadFile(const std::string& path, std::string* out) {
  std::ifstream file(path, std::ios::binary);
  if (!file) {
    return false;
  }
  std::stringstream buffer;
  buffer << file.rdbuf();
  *out = buffer.str();
  return true;
}

}  // namespace rb::test

int main(int argc, char** argv) {
  signal(SIGPIPE, SIG_IGN);
  const char* filter = argc > 1 ? argv[1] : nullptr;
  int run = 0;
  for (const rb::test::Case& test_case : rb::test::Registry()) {
    if (filter != nullptr && std::strstr(test_case.name, filter) == nullptr) {
      continue;
    }
    rb::test::current = test_case.name;
    const int before = rb::test::failures;
    test_case.body();
    std::fprintf(stderr, "%s %s\n", rb::test::failures == before ? "ok  " : "FAIL", test_case.name);
    ++run;
  }
  std::fprintf(stderr, "%d tests, %d failures\n", run, rb::test::failures);
  return rb::test::failures == 0 && run > 0 ? 0 : 1;
}

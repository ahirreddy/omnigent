// A minimal test registry: TEST(name) { CHECK(...); }. The host builds without exceptions and
// RTTI (as CEF does), which rules out the usual frameworks.
#pragma once

#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace rb::test {

struct Case {
  const char* name;
  std::function<void()> body;
};

std::vector<Case>& Registry();
void Fail(const char* file, int line, const std::string& message);
std::string FixturePath(const std::string& relative);
bool ReadFile(const std::string& path, std::string* out);

struct Registrar {
  Registrar(const char* name, std::function<void()> body) {
    Registry().push_back({name, std::move(body)});
  }
};

}  // namespace rb::test

#define RB_CONCAT_INNER(a, b) a##b
#define RB_CONCAT(a, b) RB_CONCAT_INNER(a, b)
#define TEST(name)                                                        \
  static void name();                                                     \
  static ::rb::test::Registrar RB_CONCAT(registrar_, name)(#name, &name); \
  static void name()

#define CHECK(condition)                                             \
  do {                                                               \
    if (!(condition)) {                                              \
      ::rb::test::Fail(__FILE__, __LINE__, "CHECK(" #condition ")"); \
      return;                                                        \
    }                                                                \
  } while (false)

#define CHECK_MSG(condition, message)                                                           \
  do {                                                                                          \
    if (!(condition)) {                                                                         \
      ::rb::test::Fail(__FILE__, __LINE__, std::string("CHECK(" #condition "): ") + (message)); \
      return;                                                                                   \
    }                                                                                           \
  } while (false)

#define CHECK_EQ(a, b) CHECK_MSG((a) == (b), "values differ")

// Posting std::function work to CEF threads.
#pragma once

#include <functional>
#include <utility>

#include "include/cef_task.h"

namespace rb {

class FunctionTask : public CefTask {
 public:
  explicit FunctionTask(std::function<void()> body) : body_(std::move(body)) {}
  void Execute() override { body_(); }

 private:
  std::function<void()> body_;
  IMPLEMENT_REFCOUNTING(FunctionTask);
};

inline bool PostUi(std::function<void()> body) {
  return CefPostTask(TID_UI, new FunctionTask(std::move(body)));
}

inline bool PostUiDelayed(std::function<void()> body, int64_t delay_ms) {
  return CefPostDelayedTask(TID_UI, new FunctionTask(std::move(body)), delay_ms);
}

}  // namespace rb

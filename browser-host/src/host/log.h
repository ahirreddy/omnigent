#pragma once

#include <string>

namespace rb {

/// Writes one line to stderr: "omnigent-browser-host[pid]: message".
void Log(const std::string& message);

}  // namespace rb

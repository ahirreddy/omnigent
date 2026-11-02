# omnigent-browser-host: the remote agent browser host (CEF Alloy, windowless) for Linux x86_64
# and macOS arm64. See README.md.
#
#   cmake -S browser-host -B build -DCEF_ROOT=<cef distribution>   # host + core + tests
#   cmake -S browser-host -B build                                  # core + tests only
cmake_minimum_required(VERSION 3.21)
if(APPLE AND NOT CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0 CACHE STRING "macOS deployment target")
endif()
project(omnigent_browser_host VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(RB_WARNINGS -Wall -Wextra -Werror)
# Matches the CEF wrapper's flags so core objects link cleanly into the host.
set(RB_CXX_FLAGS -fno-exceptions -fno-rtti)

if(APPLE AND EXISTS "/opt/homebrew/opt/jpeg-turbo")
  list(APPEND CMAKE_PREFIX_PATH "/opt/homebrew/opt/jpeg-turbo")
endif()
find_package(JPEG REQUIRED)
find_package(Threads REQUIRED)

# Portable core: protocol, framing, canvas, conversion, encoder process, streamer. No CEF.
add_library(rb_core STATIC
  src/core/encoder.cc
  src/core/frame_sink.cc
  src/core/framing.cc
  src/core/h264.cc
  src/core/jpeg.cc
  src/core/json.cc
  src/core/keycodes.cc
  src/core/media_header.cc
  src/core/options.cc
  src/core/process.cc
  src/core/protocol.cc
  src/core/socket_server.cc
  src/core/host_files.cc
  src/core/stream.cc
  src/core/yuv.cc)
target_include_directories(rb_core PUBLIC src)
target_compile_options(rb_core PRIVATE ${RB_WARNINGS} ${RB_CXX_FLAGS} -O3)
target_compile_definitions(rb_core PUBLIC RB_HOST_VERSION="${PROJECT_VERSION}")
target_link_libraries(rb_core PUBLIC JPEG::JPEG Threads::Threads)
set_target_properties(rb_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Preloaded into x264 so its stdout is unbuffered (see src/shim/unbuffered_stdout.c).
add_library(omnigent_unbuffered_stdout SHARED src/shim/unbuffered_stdout.c)
target_compile_options(omnigent_unbuffered_stdout PRIVATE ${RB_WARNINGS})

# Tests.
enable_testing()
set(RB_FIXTURE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../client-core/fixtures/remote_browser")
add_executable(rb_core_tests
  tests/test_main.cc
  tests/encoder_test.cc
  tests/fixtures_test.cc
  tests/frame_sink_test.cc
  tests/framing_test.cc
  tests/json_test.cc
  tests/keycodes_test.cc
  tests/options_test.cc
  tests/stream_test.cc
  tests/yuv_test.cc)
target_compile_options(rb_core_tests PRIVATE ${RB_WARNINGS} ${RB_CXX_FLAGS})
target_compile_definitions(rb_core_tests PRIVATE
  RB_FIXTURE_DIR="${RB_FIXTURE_DIR}"
  RB_SHIM_LIBRARY="$<TARGET_FILE:omnigent_unbuffered_stdout>")
target_link_libraries(rb_core_tests PRIVATE rb_core)
add_dependencies(rb_core_tests omnigent_unbuffered_stdout)
add_test(NAME rb_core_tests COMMAND rb_core_tests)

# Encoder bench: feeds a BGRA recording through the encoder backend and reports costs.
add_executable(rb_encode_bench tools/encode_bench.cc)
target_compile_options(rb_encode_bench PRIVATE ${RB_WARNINGS} ${RB_CXX_FLAGS})
target_compile_definitions(rb_encode_bench PRIVATE
  RB_SHIM_LIBRARY="$<TARGET_FILE:omnigent_unbuffered_stdout>")
target_link_libraries(rb_encode_bench PRIVATE rb_core)
add_dependencies(rb_encode_bench omnigent_unbuffered_stdout)

if(CEF_ROOT)
  include(cmake/host.cmake)
endif()

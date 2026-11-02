# The CEF host executable (included from CMakeLists.txt when CEF_ROOT is set). Uses the CEF
# distribution's own CMake helpers (cmake/FindCEF.cmake and friends) and builds
# libcef_dll_wrapper from its sources.
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

set(RB_HOST_TARGET omnigent-browser-host)
set(RB_HOST_SOURCES
  src/host/browser_host.cc
  src/host/host_app.cc
  src/host/log.cc
  src/host/tab.cc)
set(RB_HOST_OUT "${CMAKE_CURRENT_BINARY_DIR}/host")

if(OS_LINUX)
  # CEF's default rpath includes "." (the working directory); load only from beside the binary.
  list(REMOVE_ITEM CEF_LINKER_FLAGS "-Wl,-rpath,.")
  ADD_LOGICAL_TARGET("libcef_lib" "${CEF_LIB_DEBUG}" "${CEF_LIB_RELEASE}")
  add_executable(${RB_HOST_TARGET} src/host/main_linux.cc ${RB_HOST_SOURCES})
  SET_EXECUTABLE_TARGET_PROPERTIES(${RB_HOST_TARGET})
  target_compile_options(${RB_HOST_TARGET} PRIVATE -Wextra -Wno-missing-field-initializers)
  add_dependencies(${RB_HOST_TARGET} libcef_dll_wrapper omnigent_unbuffered_stdout)
  target_link_libraries(${RB_HOST_TARGET} PRIVATE libcef_lib libcef_dll_wrapper rb_core
                        ${CMAKE_DL_LIBS})
  # Load the libcef.so copied next to the binary (CEF finds icudtl.dat and paks beside it).
  set_target_properties(${RB_HOST_TARGET} PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${RB_HOST_OUT}"
    SKIP_BUILD_RPATH TRUE
    LINK_OPTIONS "-Wl,-rpath,$ORIGIN")
  COPY_FILES(${RB_HOST_TARGET} "${CEF_BINARY_FILES}" "${CEF_BINARY_DIR}" "${RB_HOST_OUT}")
  COPY_FILES(${RB_HOST_TARGET} "${CEF_RESOURCE_FILES}" "${CEF_RESOURCE_DIR}" "${RB_HOST_OUT}")
  add_custom_command(TARGET ${RB_HOST_TARGET} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:omnigent_unbuffered_stdout>" "${RB_HOST_OUT}/"
    VERBATIM)
endif()

if(OS_MAC)
  set(RB_HOST_APP "${RB_HOST_OUT}/${RB_HOST_TARGET}.app")
  set(EXECUTABLE_NAME "${RB_HOST_TARGET}")
  set(PRODUCT_NAME "${RB_HOST_TARGET}")
  configure_file(mac/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/host-Info.plist")
  add_executable(${RB_HOST_TARGET} MACOSX_BUNDLE src/host/main_mac.mm ${RB_HOST_SOURCES})
  SET_EXECUTABLE_TARGET_PROPERTIES(${RB_HOST_TARGET})
  target_compile_options(${RB_HOST_TARGET} PRIVATE -Wextra -Wno-missing-field-initializers)
  add_dependencies(${RB_HOST_TARGET} libcef_dll_wrapper omnigent_unbuffered_stdout)
  target_link_libraries(${RB_HOST_TARGET} PRIVATE libcef_dll_wrapper rb_core ${CEF_STANDARD_LIBS})
  set_target_properties(${RB_HOST_TARGET} PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/host-Info.plist"
    RUNTIME_OUTPUT_DIRECTORY "${RB_HOST_OUT}")
  COPY_MAC_FRAMEWORK(${RB_HOST_TARGET} "${CEF_BINARY_DIR}" "${RB_HOST_APP}")
  add_custom_command(TARGET ${RB_HOST_TARGET} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:omnigent_unbuffered_stdout>"
            "${RB_HOST_APP}/Contents/Frameworks/"
    VERBATIM)

  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/mac/helper-Info.plist.in" RB_HELPER_PLIST_TEMPLATE)
  foreach(suffix_list ${CEF_HELPER_APP_SUFFIXES})
    string(REPLACE ":" ";" suffix_list ${suffix_list})
    list(GET suffix_list 0 name_suffix)
    list(GET suffix_list 1 target_suffix)
    list(GET suffix_list 2 plist_suffix)
    set(helper_target "omnigent_browser_host_helper${target_suffix}")
    set(helper_name "${RB_HOST_TARGET} Helper${name_suffix}")
    set(helper_plist "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${target_suffix}.plist")
    string(REPLACE "\${EXECUTABLE_NAME}" "${helper_name}" plist "${RB_HELPER_PLIST_TEMPLATE}")
    string(REPLACE "\${PRODUCT_NAME}" "${helper_name}" plist "${plist}")
    string(REPLACE "\${BUNDLE_ID_SUFFIX}" "${plist_suffix}" plist "${plist}")
    file(WRITE "${helper_plist}" "${plist}")
    add_executable(${helper_target} MACOSX_BUNDLE src/host/helper_mac.cc)
    SET_EXECUTABLE_TARGET_PROPERTIES(${helper_target})
    add_dependencies(${helper_target} libcef_dll_wrapper)
    target_link_libraries(${helper_target} PRIVATE libcef_dll_wrapper ${CEF_STANDARD_LIBS})
    set_target_properties(${helper_target} PROPERTIES
      MACOSX_BUNDLE_INFO_PLIST "${helper_plist}"
      OUTPUT_NAME "${helper_name}"
      RUNTIME_OUTPUT_DIRECTORY "${RB_HOST_OUT}")
    add_dependencies(${RB_HOST_TARGET} ${helper_target})
    add_custom_command(TARGET ${RB_HOST_TARGET} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_directory "${RB_HOST_OUT}/${helper_name}.app"
              "${RB_HOST_APP}/Contents/Frameworks/${helper_name}.app"
      VERBATIM)
  endforeach()
  # A plain command next to the bundle, matching the Linux layout. It is a launcher, not a
  # symlink: CEF resolves its framework relative to argv[0].
  add_custom_command(TARGET ${RB_HOST_TARGET} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E rm -f "${RB_HOST_OUT}/${RB_HOST_TARGET}"
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/mac/launcher.sh"
            "${RB_HOST_OUT}/${RB_HOST_TARGET}"
    VERBATIM)
endif()

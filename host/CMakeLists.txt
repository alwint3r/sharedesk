find_package(PkgConfig REQUIRED)
pkg_check_modules(X11_DEPS REQUIRED IMPORTED_TARGET x11 xtst xfixes xext xdamage)
find_package(ZLIB REQUIRED)
find_package(JPEG REQUIRED)
find_package(PNG REQUIRED)

# Ubuntu 22.04's system 0.9.13 has no Extended Clipboard support. Keep the
# pinned server private and static: the copied host needs no new VNC dylib.
include(FetchContent)
if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()
# Keep the explicit EXCLUDE_FROM_ALL integration available on CMake 3.16+.
if(POLICY CMP0169)
    cmake_policy(SET CMP0169 OLD)
endif()
if(CMAKE_VERSION VERSION_GREATER_EQUAL 4.0)
    set(CMAKE_POLICY_VERSION_MINIMUM 3.5) # The pinned upstream declares 3.4.
endif()
FetchContent_Declare(sharedesk_vnc
    URL https://codeload.github.com/LibVNC/libvncserver/tar.gz/refs/tags/LibVNCServer-0.9.15
    URL_HASH SHA256=62352c7795e231dfce044beb96156065a05a05c974e5de9e023d688d8ff675d7
    TLS_VERIFY TRUE TIMEOUT 120)
FetchContent_GetProperties(sharedesk_vnc)
if(NOT sharedesk_vnc_POPULATED)
    FetchContent_Populate(sharedesk_vnc)
endif()
execute_process(COMMAND "${CMAKE_COMMAND}" "-DSOURCE_DIR=${sharedesk_vnc_SOURCE_DIR}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/patch-vnc-clipboard.cmake" RESULT_VARIABLE patch_result)
if(NOT patch_result EQUAL 0)
    message(FATAL_ERROR "Cannot apply the pinned clipboard decoder safety fix")
endif()
set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)
set(BUILD_SHARED_LIBS OFF)
set(LIBVNCSERVER_INSTALL OFF)
foreach(option WITH_EXAMPLES WITH_TESTS WITH_SDL WITH_GTK WITH_QT WITH_XCB
               WITH_LIBSSHTUNNEL WITH_FFMPEG WITH_SYSTEMD WITH_THREADS
               WITH_TIGHTVNC_FILETRANSFER WITH_WEBSOCKETS WITH_IPv6 WITH_SASL
               WITH_GNUTLS WITH_OPENSSL WITH_GCRYPT WITH_LZO)
    set(${option} OFF)
endforeach()
set(WITH_ZLIB ON)
set(WITH_JPEG ON)
set(WITH_PNG ON)
add_subdirectory("${sharedesk_vnc_SOURCE_DIR}" "${sharedesk_vnc_BINARY_DIR}" EXCLUDE_FROM_ALL)

add_executable(sharedesk-host host.c)
target_compile_features(sharedesk-host PRIVATE c_std_11)
target_compile_options(sharedesk-host PRIVATE -Wall -Wextra -Wpedantic)
target_include_directories(sharedesk-host PRIVATE
    "${sharedesk_vnc_SOURCE_DIR}/include" "${sharedesk_vnc_BINARY_DIR}/include")
target_link_libraries(sharedesk-host PRIVATE vncserver PkgConfig::X11_DEPS)
# Preserve the executable path used by the installer and root build commands.
set_target_properties(sharedesk-host PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

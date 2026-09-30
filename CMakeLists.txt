cmake_minimum_required(VERSION 3.16)
project(sharedesk_host LANGUAGES C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(VNC REQUIRED IMPORTED_TARGET libvncserver)
pkg_check_modules(X11_DEPS REQUIRED IMPORTED_TARGET x11 xtst xfixes)

add_executable(sharedesk-host src/host.c)
target_compile_features(sharedesk-host PRIVATE c_std_11)
target_compile_options(sharedesk-host PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(sharedesk-host PRIVATE PkgConfig::VNC PkgConfig::X11_DEPS)

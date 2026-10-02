find_package(PkgConfig REQUIRED)
pkg_check_modules(VNC REQUIRED IMPORTED_TARGET libvncserver)
pkg_check_modules(X11_DEPS REQUIRED IMPORTED_TARGET x11 xtst xfixes xext xdamage)

add_executable(sharedesk-host host.c)
target_compile_features(sharedesk-host PRIVATE c_std_11)
target_compile_options(sharedesk-host PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(sharedesk-host PRIVATE PkgConfig::VNC PkgConfig::X11_DEPS)
# Preserve the executable path used by the installer and root build commands.
set_target_properties(sharedesk-host PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

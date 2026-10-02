enable_language(OBJC)
find_package(PkgConfig REQUIRED)
pkg_check_modules(VNC_CLIENT REQUIRED IMPORTED_TARGET libvncclient>=0.9.15)
find_library(COCOA_FRAMEWORK Cocoa)
find_library(CARBON_FRAMEWORK Carbon)

add_executable(sharedesk-viewer MACOSX_BUNDLE viewer.m)
target_compile_options(sharedesk-viewer PRIVATE -fobjc-arc -Wall -Wextra -Wpedantic)
target_link_libraries(sharedesk-viewer PRIVATE PkgConfig::VNC_CLIENT ${COCOA_FRAMEWORK} ${CARBON_FRAMEWORK})
set_target_properties(sharedesk-viewer PROPERTIES
    # Preserve build-mac/sharedesk-viewer.app for the root build commands.
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    MACOSX_BUNDLE_BUNDLE_NAME Sharedesk
    MACOSX_BUNDLE_GUI_IDENTIFIER net.sharedesk.viewer
    MACOSX_BUNDLE_BUNDLE_VERSION 1
    MACOSX_BUNDLE_SHORT_VERSION_STRING 0.1
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/viewer-Info.plist.in")
